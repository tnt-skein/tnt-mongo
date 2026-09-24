--- Одна операция на взятом соединении: команда либо выборка курсором,
--- ответ сервера — значением или отказом, и решение о соединении.
---
--- Здесь нет ни пула, ни повторов: этим живёт фасад, а транзакция зовёт
--- те же операции на своём соединении. Решение о соединении — словом:
--- `give` — вернуть, `drop` — выбросить (в сокете недочитанный ответ либо
--- узел перестал быть ведущим, и новое соединение может прийти к новому).
---
--- Отказ сервера бывает трёх видов, и все три — отказ вызова:
---
--- * `ok: 0` — команда не выполнена: код, имя кода, текст, метки;
--- * `writeErrors` при `ok: 1` — часть записей отвергнута (дубликат
---   ключа), а прочие, может быть, записаны: отказ называет первую;
--- * `writeConcernError` — записано на ведущем, но подтверждения реплик
---   не дождались.
---
--- Выборка читает курсор до конца, пачками `getMore` на том же соединении
--- и в тот же срок. Больше `max_rows` документов — отказ `overflow`,
--- и курсор закрывается на сервере сразу, а не по сроку простоя.

local ffi = require('ffi')

local codes = require('tnt.storage.codes')
local failure = require('tnt.storage.failure')
local link = require('tnt.mongo.link')
local request = require('tnt.mongo.request')

local Module = {}

--- Вернуть соединение в пул.
Module.GIVE = 'give'

--- Выбросить соединение.
Module.DROP = 'drop'

--- Выборка — массив и при пустом ответе.
local SEQ = { __serialize = 'seq' }

--- Операция на взятом соединении: значение, отказ и решение о соединении.
---@alias TntMongoRun fun(conn: TntMongoLink, body: string, deadline: number, call: TntMongoCall): any, any, string

---@class TntMongoCall Что знает операция о вызове
---@field where string Узел и порт для текста отказа
---@field db string База
---@field idempotent boolean|nil Согласен ли вызывающий на повтор после отправки
---@field max_rows integer Предел документов выборки
---@field max_bytes integer Предел байтов ответа
---@field session table[] Поля сеанса и транзакции парами; пусто — вне транзакции

--- Отказ сервера по коду, имени кода и меткам.
---
--- В журнальную причину идут имя и код, а не текст: у дубликата ключа
--- текст несёт само значение ключа (`dup key: { email: "…" }`), а значения
--- в журнал не пишутся.
---@param code integer|nil
---@param name string|nil
---@param text any
---@param labels string[]|nil
---@param idempotent boolean|nil
---@return TntStorageFailure
local function refused(code, name, text, labels, idempotent)
    return failure.new(codes.mongo(code, labels), tostring(text), {
        server_code = code,
        idempotent = idempotent,
        reason = ('сервер отказал: %s, код %s'):format(name or 'без имени', tostring(code)),
    })
end

--- Отказ ли ответ сервера.
---@param reply table
---@param idempotent boolean|nil
---@return TntStorageFailure|nil
function Module.verdict(reply, idempotent)
    if reply.ok ~= 1 then
        return refused(reply.code, reply.codeName, reply.errmsg, reply.errorLabels, idempotent)
    end

    local written = reply.writeErrors

    if type(written) == 'table' and written[1] ~= nil then
        local first = written[1]
        local text = ('запись %s отвергнута: %s'):format(tostring(first.index), tostring(first.errmsg))

        return refused(first.code, first.codeName, text, reply.errorLabels, idempotent)
    end

    local concern = reply.writeConcernError

    if concern ~= nil then
        return refused(concern.code, concern.codeName, concern.errmsg, reply.errorLabels, idempotent)
    end

    return nil
end

--- Команда: ответ, отказ и решение о соединении.
---@param conn TntMongoLink
---@param body string Тело команды в BSON
---@param deadline number
---@param call TntMongoCall
---@return table|nil reply
---@return TntStorageFailure|nil err
---@return string action give либо drop
function Module.command(conn, body, deadline, call)
    local reply, trouble = link.exchange(conn, body, deadline, call.max_bytes)

    if reply == nil then
        ---@cast trouble TntMongoTrouble
        local err = failure.new(trouble.kind, ('mongo %s: %s'):format(call.where, trouble.message), {
            sent = trouble.sent,
            retriable = trouble.retriable,
            idempotent = call.idempotent,
        })

        return nil, err, trouble.clean and Module.GIVE or Module.DROP
    end

    local err = Module.verdict(reply, call.idempotent)

    if err == nil then
        return reply, nil, Module.GIVE
    end

    return nil, err, err.kind == failure.BUSY and Module.DROP or Module.GIVE
end

--- Курсор ответа с его пачкой, дописанной к выборке.
---
--- Ответ без курсора, без номера или без пачки — отказ: по нему нельзя
--- ни продолжить выборку, ни закрыть курсор.
---@param reply table
---@param batch string firstBatch либо nextBatch
---@param rows table Выборка
---@return table|nil cursor
local function cursor_of(reply, batch, rows)
    local cursor = reply.cursor

    if type(cursor) ~= 'table' or type(cursor[batch]) ~= 'table' then
        return nil
    end

    -- Номер — `int64` BSON: числом, пока он не дальше 2⁵³, иначе `int64`.
    if not (type(cursor.id) == 'number' or ffi.istype('int64_t', cursor.id)) then
        return nil
    end

    for _, document in ipairs(cursor[batch]) do
        rows[#rows + 1] = document
    end

    return cursor
end

--- Выборка курсором до конца.
---@param conn TntMongoLink
---@param body string Тело команды, отдающей курсор
---@param deadline number
---@param call TntMongoCall
---@return table[]|nil documents
---@return TntStorageFailure|nil err
---@return string action give либо drop
function Module.query(conn, body, deadline, call)
    local reply, err, action = Module.command(conn, body, deadline, call)

    if reply == nil then
        return nil, err, action
    end

    local rows = setmetatable({}, SEQ)
    local cursor = cursor_of(reply, 'firstBatch', rows)

    if cursor == nil then
        return nil,
            failure.new(
                failure.REJECTED,
                'ответ без курсора: команда не отдаёт документов'
            ),
            Module.GIVE
    end

    -- Номер курсора и в getMore, и в killCursors — только `int64`: номер,
    -- прочитанный числом, ушёл бы `int32`, и сервер его не примет.
    local id = ffi.cast('int64_t', cursor.id)
    -- Пространство курсора — «база.коллекция», и база — та, что у команды.
    local collection = tostring(cursor.ns):sub(#call.db + 2)

    while id ~= 0 and #rows <= call.max_rows do
        reply, err, action = Module.command(
            conn,
            request.system(call.db, call.session, 'getMore', id, 'collection', collection),
            deadline,
            call
        )

        if reply == nil then
            return nil, err, action
        end

        cursor = cursor_of(reply, 'nextBatch', rows)

        if cursor == nil then
            return nil,
                failure.new(failure.REJECTED, 'ответ getMore без пачки документов'),
                Module.GIVE
        end

        id = ffi.cast('int64_t', cursor.id)
    end

    if #rows <= call.max_rows then
        return rows, nil, Module.GIVE
    end

    local overflow =
        failure.new(failure.OVERFLOW, ('документов больше max_rows %d'):format(call.max_rows))

    if id == 0 then
        return nil, overflow, Module.GIVE
    end

    local _, _, closed = Module.command(
        conn,
        request.system(call.db, call.session, 'killCursors', collection, 'cursors', { id }),
        deadline,
        call
    )

    return nil, overflow, closed
end

return Module
