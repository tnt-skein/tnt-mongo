--- Транзакция MongoDB на одном соединении: сеанс, номер транзакции,
--- фиксация либо отмена.
---
--- Договор тот же, что у драйвера SQL над роком из `tnt-storage`,
--- а устройство — MongoDB: `BEGIN` нет, транзакцию открывает первая
--- команда с `startTransaction`, и каждая команда внутри несёт сеанс
--- (`lsid`), номер транзакции (`txnNumber`) и `autocommit: false`.
---
--- * тело ничего не вернуло — фиксация и `true`; первое значение `nil`
---   или `false` — отмена и пара `nil, err`, где `err` тела отдаётся как
---   есть; иное — фиксация и это значение. Тело, не сделавшее ни одной
---   команды, фиксировать нечего: сервер о такой транзакции не знает;
--- * **первый отказ команды помечает транзакцию**: следующие команды `tx`
---   сразу отдают тот же отказ, фиксации не будет;
--- * исключение в теле — отмена, соединение выбрасывается, исключение
---   идёт дальше. Закрытие сокета MongoDB транзакцию **не отменяет**:
---   она живёт в сеансе, а не в соединении, поэтому отмена шлётся явно;
--- * соединение, помеченное к выбросу командой тела (срок, обрыв),
---   выбрасывается без отмены: в сокете недочитанный ответ. Транзакцию
---   тогда снимает сервер по `transactionLifetimeLimitSeconds` (60 с);
--- * взятие соединения повторяется — тело ещё не выполнялось; команды
---   тела — никогда, и срока своего у них нет: срок один на транзакцию;
--- * `retry = true` повторяет всю транзакцию с телом, если она кончилась
---   конфликтом (`conflict`: метка `TransientTransactionError`, конфликт
---   записи), — сервер снял её целиком. Тело обязано быть безопасным для
---   повтора: всё, что оно делает мимо `tx`, случится дважды;
--- * `tx` годен только внутри тела; вложенная транзакция и транзакция
---   внутри транзакции box — исключение.

local ffi = require('ffi')
local fiber = require('fiber')

local fail = require('tnt.must.fail')
local failure = require('tnt.storage.failure')
local must = require('tnt.must')
local operation = require('tnt.mongo.operation')
local request = require('tnt.mongo.request')
local external = require('tnt.external')
local within = require('tnt.storage.within')

local Module = {}

--- Внешнее средство: идёт ли транзакция box.
local source = external.install(Module, {
    -- До `box.cfg` транзакции не бывает, а `box.is_in_txn` там бросает.
    box_txn = function()
        return type(box.cfg) ~= 'function' and box.is_in_txn()
    end,
})

--- Настройки транзакции.
local OPTIONS = { retry = '?boolean', timeout = '?number' }

--- Настройки команды внутри транзакции: база и предел документов.
local STEP = { max_rows = '?integer', db = '?not_empty' }

--- Броски ошибок программиста.
local THROWN = {
    -- `tx`, унесённый за пределы тела.
    finished = 'tx годен только внутри тела транзакции, а она уже закончена',
    -- Срок и повтор у команды транзакции.
    own = 'у команды транзакции нет своего срока и повтора: их задаёт transaction',
    -- Транзакция внутри транзакции box.
    box = 'transaction внутри транзакции box: ожидание сети оборвёт её',
    -- Вложенная транзакция.
    nested = 'transaction внутри transaction: вторая взяла бы второе соединение и ждала бы первого',
}

---@class TntMongoTx Команды одной транзакции
---@field client TntMongoClient
---@field conn TntMongoLink Соединение транзакции
---@field deadline number Миг срока транзакции
---@field number any Номер транзакции в сеансе, `int64`
---@field started boolean Первая команда ушла: сервер знает о транзакции
---@field failed TntStorageFailure|nil Первый отказ команды: фиксации не будет
---@field doomed boolean Соединение не вернуть: в сокете недочитанный ответ
---@field finished boolean Тело вышло: `tx` больше не годен
local Transaction = {}
Transaction.__index = Transaction

--- Итог тела: удалось ли, сколько значений и какие.
---@param ok boolean
---@param ... any
---@return { ok: boolean, count: integer, [integer]: any }
local function outcome(ok, ...)
    return { ok = ok, count = select('#', ...), ... }
end

--- Поля сеанса и транзакции у каждой команды внутри неё.
---@param tx TntMongoTx
---@return table[]
local function session_of(tx)
    return {
        { 'lsid', { id = tx.conn.session } },
        { 'txnNumber', tx.number },
        { 'autocommit', false },
    }
end

--- Вызов с полями транзакции и базой.
---@param tx TntMongoTx
---@param db string
---@param max_rows integer
---@return TntMongoCall
local function call_of(tx, db, max_rows)
    local client = tx.client

    ---@type TntMongoCall
    return {
        where = client.where,
        db = db,
        max_rows = max_rows,
        max_bytes = client.max_bytes,
        session = session_of(tx),
    }
end

--- Команда внутри транзакции.
---@param command table
---@param opts table|nil
---@param run TntMongoRun
---@param cursor boolean Только команды курсора
---@return any value
---@return TntStorageFailure|nil err
function Transaction:_run(command, opts, run, cursor)
    if self.finished then
        error(THROWN.finished, 3)
    end

    if type(opts) == 'table' and (opts.timeout ~= nil or opts.idempotent ~= nil) then
        error(THROWN.own, 3)
    end

    local caller = must.at(3)

    caller.optional.options(opts, 'настройки команды транзакции', STEP)

    local given = opts or {}

    caller.optional.positive(given.max_rows, 'max_rows')

    local call = call_of(self, given.db or self.client.db, given.max_rows or self.client.max_rows)
    local extra = table.copy(call.session)

    if not self.started then
        table.insert(extra, { 'startTransaction', true })
    end

    local name, body = request.command(command, call.db, extra, 3)

    if cursor and not request.CURSORS[name] then
        error(('query ходит с командами курсора, а не %s'):format(name), 3)
    end

    if self.failed ~= nil then
        return nil, self.failed
    end

    self.started = true

    local done, err, action = run(self.conn, body, self.deadline, call)

    self.doomed = self.doomed or action == operation.DROP

    if err ~= nil then
        -- Оператор транзакции не повторяется никогда: помеченную
        -- транзакцию повтор не лечит.
        local final = setmetatable(table.copy(err), getmetatable(err))

        final.retriable = false
        self.failed = final

        return nil, final
    end

    return done
end

--- Команда внутри транзакции: ответ сервера документом.
---@param command table
---@param opts { db: string|nil }|nil
---@return table|nil reply
---@return TntStorageFailure|nil err
function Transaction:command(command, opts)
    local reply, err = self:_run(command, opts, operation.command, false)

    return reply, err
end

--- Выборка внутри транзакции: документы курсора до конца.
---@param command table
---@param opts { db: string|nil, max_rows: integer|nil }|nil
---@return table[]|nil documents
---@return TntStorageFailure|nil err
function Transaction:query(command, opts)
    local documents, err = self:_run(command, opts, operation.query, true)

    return documents, err
end

--- Фиксация либо отмена на сервере: команда базы `admin` с полями сеанса.
---@param tx TntMongoTx
---@param name string commitTransaction либо abortTransaction
---@return TntStorageFailure|nil err
---@return string action give либо drop
local function finish(tx, name)
    local call = call_of(tx, 'admin', tx.client.max_rows)
    local _, err, action = operation.command(tx.conn, request.system('admin', call.session, name, 1), tx.deadline, call)

    return err, action
end

--- Возвращает соединение транзакции: выброшенное — с записью в журнал.
---@param tx TntMongoTx
---@param action string give либо drop
---@param err TntStorageFailure|nil
local function release(tx, action, err)
    if tx.doomed then
        action, err = operation.DROP, err or tx.failed
    end

    tx.client:_release(tx.conn, action, err)
end

--- Конец транзакции: фиксация, если тело согласно и отказов не было,
--- иначе отмена.
---@param tx TntMongoTx
---@param verdict any Первое значение тела
---@param reason any Второе значение тела
---@return any value
---@return any err
local function conclude(tx, verdict, reason)
    if tx.failed == nil and verdict ~= nil and verdict ~= false then
        if not tx.started then
            release(tx, operation.GIVE)

            return verdict
        end

        local refused, action = finish(tx, 'commitTransaction')

        release(tx, action, refused)

        if refused ~= nil then
            return nil, refused
        end

        return verdict
    end

    local undone, action = nil, operation.GIVE

    -- Отмена — в остаток того же срока; не прошла — соединение не вернуть,
    -- а транзакцию снимет сервер по сроку жизни.
    if tx.started and not tx.doomed then
        undone, action = finish(tx, 'abortTransaction')
    end

    release(tx, action, undone)

    return nil, tx.failed or reason or failure.new(failure.REJECTED, 'тело отменило транзакцию')
end

--- Берёт соединение: повторяется по приговору отказа — тело ещё не
--- выполнялось.
---@param client TntMongoClient
---@param deadline number
---@param timeout number
---@return TntMongoLink|nil conn
---@return TntStorageFailure|nil err
local function take(client, deadline, timeout)
    local last = nil

    return client.retry:run(function()
        local conn, refused = client:_take(deadline, last)

        last = refused

        return conn, refused
    end, { deadline = timeout })
end

--- Одна транзакция целиком.
---@param client TntMongoClient
---@param fn fun(tx: TntMongoTx): any, any
---@param deadline number
---@param timeout number
---@return any value
---@return any err
local function once(client, fn, deadline, timeout)
    local conn, err = take(client, deadline, timeout)

    if conn == nil then
        return nil, err
    end

    conn.transactions = conn.transactions + 1

    ---@type TntMongoTx
    local tx = setmetatable({
        client = client,
        conn = conn,
        deadline = deadline,
        number = ffi.cast('int64_t', conn.transactions),
        started = false,
        doomed = false,
        finished = false,
    }, Transaction)
    local owner = fiber.id()

    client.inside[owner] = true

    local body = outcome(pcall(fn, tx))

    client.inside[owner] = nil
    tx.finished = true

    if body.ok then
        -- Тело, не вернувшее ничего, согласно, как у `box.atomic`.
        return conclude(tx, body.count == 0 or body[1], body[2])
    end

    -- Сервер транзакцию по закрытию сокета не отменит: отмена — явно,
    -- если соединение цело, и соединение выбрасывается при любом исходе.
    if tx.started and not tx.doomed then
        finish(tx, 'abortTransaction')
    end

    release(tx, operation.DROP, failure.new(failure.REJECTED, 'исключение в теле транзакции'))
    fail.raise(body[1])
end

--- Повторять ли всю транзакцию: только конфликт — его сервер снял целиком.
---@param err any
---@return boolean
local function conflicted(err)
    return failure.is(err) and err.kind == failure.CONFLICT
end

--- Транзакция с повтором после конфликта.
---
--- Исключение тела идёт мимо повторов: `tnt-retry` счёл бы его отказом.
--- Пойманное отдаётся повторам как удача — повтора за ним нет — самой
--- ловушкой, и по ней же узнаётся: значения тела ловушкой не бывают.
---@param client TntMongoClient
---@param fn fun(tx: TntMongoTx): any, any
---@param deadline number
---@param timeout number
---@return any value
---@return any err
local function repeated(client, fn, deadline, timeout)
    ---@type { value: any }
    local thrown = {}
    local value, err = client.retry:run(function()
        local attempt = outcome(pcall(once, client, fn, deadline, timeout))

        if attempt.ok then
            return attempt[1], attempt[2]
        end

        thrown.value = attempt[1]

        return thrown
    end, { deadline = timeout, retriable = conflicted })

    if value == thrown then
        fail.raise(thrown.value)
    end

    return value, err
end

--- Транзакция: проверка аргументов, один срок, повтор по `retry`.
---@param client TntMongoClient
---@param fn fun(tx: TntMongoTx): any, any
---@param opts { timeout: number|nil, retry: boolean|nil }|nil
---@return any value
---@return any err
function Module.run(client, fn, opts)
    local caller = must.at(3)
    local given = caller.optional.options(opts, 'настройки транзакции', OPTIONS) or {}

    caller.callable(fn, 'тело транзакции')

    local timeout = within.timeout(given.timeout, client.limits, 3)

    if source().box_txn() then
        error(THROWN.box, 3)
    end

    if client.inside[fiber.id()] then
        error(THROWN.nested, 3)
    end

    local deadline = within.deadline(timeout)
    local run = given.retry and repeated or once

    return run(client, fn, deadline, timeout)
end

return Module
