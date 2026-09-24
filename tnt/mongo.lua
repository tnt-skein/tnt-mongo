--- Клиент MongoDB: OP_MSG и BSON по сокету, пул, срок, повторы, отказ
--- парой и транзакции у набора реплик.
---
---     local mongo = require('tnt.mongo')
---
---     local db = mongo.new({ host = 'db', username = 'app', password = secret, db = 'shop' })
---
---     local reply, err = db:command({ 'insert', 'users', documents = { { _id = 7, name = 'Анна' } } })
---     local users, err = db:query({ 'find', 'users', filter = { name = 'Анна' } })
---
---     db:close()
---
--- Готового неблокирующего клиента MongoDB у Tarantool нет: ни модуля
--- ядра, ни официального рока, а обёртка над клиентской библиотекой на C
--- ждала бы сети в потоке событий и останавливала узел целиком. Поэтому
--- протокол свой — OP_MSG и BSON поверх встроенного сокета, — а всё прочее
--- взято готовым: пул `tnt-pool`, заведённый драйвером; отказ, срок
--- и кодирование значений — `tnt-storage`; повторы — `tnt-retry` по полю
--- `retriable` отказа; TLS — `tnt-tls`.
---
--- Решения, которые стоит знать заранее:
---
--- * **Команда — список**: `{ 'find', 'users', filter = …, limit = 10 }`.
---   Имя первым, его значение вторым, прочее — поля. Порядок полей там,
---   где он важен (`sort`, ключ индекса), — `mongo.ordered`.
--- * **Отказ — пара `nil, err`**, и отказ записи внутри ответа `ok: 1`
---   (`writeErrors`) — тоже: дубликат ключа — `rejected`, конфликт записи —
---   `conflict`, узел не ведущий — `busy`. Исключение — только ошибка
---   программиста.
--- * **Срок один на вызов**, умолчание 5 с: пул, вход, запрос, пачки
---   курсора и паузы повторов — остатки одного мига.
--- * **Повтор после отправки — только с `idempotent = true`.**
--- * **Выборка `query` читает курсор до конца**, предел — `max_rows`.
--- * **Транзакции — только у набора реплик** (`replica_set`): без него
---   метода `transaction` нет, `features.transaction = false`.
---
--- Подробно — `docs/mongo.md`.

local fiber = require('fiber')

local link = require('tnt.mongo.link')
local must = require('tnt.must')
local operation = require('tnt.mongo.operation')
local pool = require('tnt.pool')
local request = require('tnt.mongo.request')
local retry = require('tnt.retry')
local settings_of = require('tnt.mongo.settings')
local storage = require('tnt.storage')
local transaction = require('tnt.mongo.transaction')
local types = require('tnt.mongo.types')

local log = require('tnt.log').new('tnt.mongo')

local failure, within = storage.failure, storage.within

local Module = {}

--- Опознаватель документа: новый либо из 24 шестнадцатеричных знаков.
Module.object_id = types.object_id

--- Документ с порядком полей: имя, значение, имя, значение…
Module.ordered = types.ordered

--- Отметка оплога, образец, двоичное с видом, крайние ключи.
Module.timestamp = types.timestamp
Module.regex = types.regex
Module.binary = types.binary
Module.MIN_KEY = types.MIN_KEY
Module.MAX_KEY = types.MAX_KEY

--- Настройки команды: срок, согласие на повтор, база.
local COMMAND = { timeout = '?number', idempotent = '?boolean', db = '?not_empty' }

--- Настройки выборки: то же и предел документов.
local QUERY = { timeout = '?number', idempotent = '?boolean', db = '?not_empty', max_rows = '?integer' }

--- Вне транзакции сеанса нет.
local NONE = {}

---@alias TntMongoTransact fun(self: TntMongoClient, fn: fun(tx: TntMongoTx): any, opts: table|nil): any, any

---@class TntMongoClient
---@field name string Имя драйвера
---@field features { transaction: boolean } Что драйвер умеет
---@field where string Узел и порт
---@field db string База команд по умолчанию
---@field limits TntStorageLimits Сроки вызова
---@field max_bytes integer Предел байтов ответа
---@field max_rows integer Предел документов выборки
---@field wait_timeout number Сколько ждать соединения из пула
---@field pool TntPool Соединения
---@field retry TntRetry Повторы
---@field closed boolean Закрыт ли драйвер
---@field inside table<integer, boolean> Файберы, чья транзакция идёт сейчас
---@field transaction TntMongoTransact|nil Транзакция; есть только у набора реплик
local Client = {}
Client.__index = Client

--- Тот же отказ, но без повтора.
---
--- Срок, вышедший до очередной попытки, отдаёт отказ прошлой: пауза
--- `tnt-retry` меряет свой срок от своего начала и могла в него уложиться,
--- не уложившись в миг вызова.
---@param err TntStorageFailure
---@return TntStorageFailure
local function settled(err)
    local copy = setmetatable(table.copy(err), getmetatable(err))

    copy.retriable = false

    return copy
end

--- Отказ, когда срок вышел до очередной попытки либо до первой.
---@param last TntStorageFailure|nil
---@return TntStorageFailure
local function expired(last)
    if last ~= nil then
        return settled(last)
    end

    return failure.new(
        failure.TIMEOUT,
        'срок вызова вышел до отправки команды',
        { sent = false }
    )
end

--- Чем объяснить, что соединения не дали.
---
--- Окончательный отказ входа (`denied`) пул отдаёт тем, что вернула
--- `open`. Строкой он отдаёт срок: место в пуле есть, а соединение
--- не открылось — это `unreachable` с текстом отказа открытия;
--- места нет — все заняты, `busy`.
---@param why any Что отдал пул
---@return TntStorageFailure
function Client:_refusal(why)
    if failure.is(why) then
        return why
    end

    local stats = self.pool:stats()
    local unopened = stats.total < stats.size and stats.last_open_error ~= nil
    local text = ('mongo %s: %s'):format(self.where, tostring(why))

    return failure.new(unopened and failure.UNREACHABLE or failure.BUSY, text)
end

--- Берёт соединение в остаток срока.
---@param deadline number
---@param last TntStorageFailure|nil Отказ прошлой попытки
---@return TntMongoLink|nil conn
---@return TntStorageFailure|nil err
function Client:_take(deadline, last)
    if self.closed then
        return nil, failure.new(failure.CLOSED, ('%s: драйвер закрыт'):format(self.name))
    end

    -- Остаток — перед ожиданием пула и после него. Срок, вышедший
    -- в ожидании, соединение не портит: команда не ушла, сокет чист,
    -- и оно возвращается, а не выбрасывается.
    if within.left(deadline) > 0 then
        local conn, why = self.pool:take(math.min(within.left(deadline), self.wait_timeout))

        if conn == nil then
            return nil, self:_refusal(why)
        end

        if within.left(deadline) > 0 then
            return conn
        end

        self.pool:give(conn)
    end

    return nil, expired(last)
end

--- Возвращает соединение либо выбрасывает его и говорит об этом в журнал:
--- выброс — новый вход на следующем вызове, и частые выбросы видны только
--- так.
---@param conn TntMongoLink
---@param action string give либо drop
---@param err TntStorageFailure|nil Почему выброшено
function Client:_release(conn, action, err)
    if action == operation.GIVE then
        self.pool:give(conn)

        return
    end

    ---@cast err TntStorageFailure
    self.pool:drop(conn)
    log.warn('соединение выброшено', { driver = self.name, kind = err.kind, reason = err.reason })
end

--- Настройки вызова, команда байтами и срок — с виной на строке того,
--- кто звал `command` либо `query`.
---@param command table
---@param opts table|nil
---@param spec table Какие настройки вызова знакомы
---@return string name Имя команды
---@return string body Тело команды в BSON
---@return TntMongoCall call
---@return number timeout
function Client:_prepare(command, opts, spec)
    local caller = must.at(3)

    caller.optional.options(opts, 'настройки вызова', spec)

    local given = opts or {}
    local timeout = within.timeout(given.timeout, self.limits, 3)

    caller.optional.positive(given.max_rows, 'max_rows')

    local db = given.db or self.db
    local name, body = request.command(command, db, NONE, 3)

    ---@type TntMongoCall
    local call = {
        where = self.where,
        db = db,
        idempotent = given.idempotent,
        max_rows = given.max_rows or self.max_rows,
        max_bytes = self.max_bytes,
        session = NONE,
    }

    return name, body, call, timeout
end

--- Вызов целиком: один миг срока, попытки по приговору отказа.
---@param run TntMongoRun
---@param body string
---@param call TntMongoCall
---@param timeout number
---@return any value
---@return TntStorageFailure|nil err
function Client:_call(run, body, call, timeout)
    local deadline = within.deadline(timeout)
    local last = nil

    local result, err = self.retry:run(function()
        local conn, refused = self:_take(deadline, last)

        if conn == nil then
            last = refused

            return nil, refused
        end

        local done, failed, action = run(conn, body, deadline, call)

        self:_release(conn, action, failed)
        last = failed

        return done, failed
    end, { deadline = timeout })

    -- Отменённого вызывающего пара не останавливает: отмена уходит
    -- дальше тем же исключением, соединение к этому мигу уже выброшено.
    fiber.testcancel()

    return result, err
end

--- Команда: ответ сервера документом.
---
--- Отказ сервера — пара, и отказ записи внутри ответа `ok: 1` тоже.
---@param command table `{ имя, значение, поле = значение, … }`
---@param opts { timeout: number|nil, idempotent: boolean|nil, db: string|nil }|nil
---@return table|nil reply
---@return TntStorageFailure|nil err
function Client:command(command, opts)
    local _, body, call, timeout = self:_prepare(command, opts, COMMAND)
    local reply, err = self:_call(operation.command, body, call, timeout)

    return reply, err
end

--- Выборка: документы курсора до конца.
---
--- Команда — из тех, что отдают курсор: `find`, `aggregate`,
--- `listCollections`, `listIndexes`.
---@param command table
---@param opts { timeout: number|nil, idempotent: boolean|nil, db: string|nil, max_rows: integer|nil }|nil
---@return table[]|nil documents
---@return TntStorageFailure|nil err
function Client:query(command, opts)
    local name, body, call, timeout = self:_prepare(command, opts, QUERY)

    if not request.CURSORS[name] then
        error(
            ('query ходит с командами курсора (find, aggregate, listCollections, listIndexes), а не %s'):format(
                name
            ),
            2
        )
    end

    local documents, err = self:_call(operation.query, body, call, timeout)

    return documents, err
end

--- Закрывает драйвер: свободные соединения — сразу, занятые — когда
--- их вернут.
---
--- Повторное закрытие — пара `closed`, а не исключение: закрытие при
--- остановке узла гонится с запросами, и «так бывает».
---@return boolean ok
---@return TntStorageFailure|nil err
function Client:close()
    local again = self.closed

    self.closed = true

    if again then
        return false, failure.new(failure.CLOSED, ('%s: драйвер уже закрыт'):format(self.name))
    end

    self.pool:close()

    return true
end

--- Показатели пула, без учётных данных: пароль живёт только в замыкании
--- входа.
---@return table
function Client:stats()
    return (self.pool:stats())
end

--- Транзакция у набора реплик (`tnt.mongo.transaction`).
---@param client TntMongoClient
---@param fn fun(tx: TntMongoTx): any, any
---@param opts { timeout: number|nil, retry: boolean|nil }|nil
---@return any value
---@return any err
local function transact(client, fn, opts)
    local done, err = transaction.run(client, fn, opts)

    -- Отменённого вызывающего пара не останавливает, как и у `command`.
    fiber.testcancel()

    return done, err
end

--- Драйвер набора реплик: тот же, и ещё `transaction`. У одиночного узла
--- метода нет вовсе: транзакция, которая ничего не откатывает,
--- хуже её отсутствия.
local Transactional = setmetatable({ transaction = transact }, { __index = Client })
Transactional.__index = Transactional

--- Заводит драйвер. Соединений не открывает: первое откроет первый вызов.
---@param opts TntMongoOptions
---@return TntMongoClient
function Module.new(opts)
    local settings = settings_of.check(opts)

    -- Повторы заводятся раньше пула: негодная настройка бросает,
    -- не оставив пула без хозяина.
    local retrier, wrong = retry.new(settings.retry)

    if retrier == nil then
        error(('настройки mongo.retry: %s'):format(wrong), 2)
    end

    -- Пулу — крюки: вход в срок, закрытие, живость без сети.
    local hooks = settings.pool

    hooks.open = function(left)
        return link.open(settings, left)
    end
    hooks.close, hooks.alive = link.close, link.alive

    local connections = pool.new(hooks)
    local transactional = settings.replica_set ~= nil

    return setmetatable({
        name = settings.name,
        features = { transaction = transactional },
        where = settings.where,
        db = settings.db,
        limits = settings.limits,
        max_bytes = settings.max_bytes,
        max_rows = settings.max_rows,
        wait_timeout = connections.settings.wait_timeout,
        pool = connections,
        retry = retrier,
        closed = false,
        inside = {},
    }, transactional and Transactional or Client)
end

return Module
