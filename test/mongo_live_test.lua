--- Драйвер против настоящего MongoDB.
---
--- Двойник показывает, что мы правильно разговариваем сами с собой.
--- Настоящий сервер показывает, что нас понимает кто-то ещё: его SCRAM
--- с подписью сервера, отказ записи внутри ответа `ok: 1`, метки
--- транзакций, курсор пачками, TLS с его сертификатом. Сервер поднимается
--- отдельно — `make mongo-up` (`test/stand/mongo.sh`), — и если его нет,
--- проверки честно пропускаются: гейты не должны зависеть от докера.

local clock = require('clock')
local datetime = require('datetime')
local decimal = require('decimal')
local t = require('luatest')
local uuid = require('uuid')
local varbinary = require('varbinary')

local helper = dofile('test/helper.lua')

local mongo, storage = helper.mongo, helper.storage

local g = t.group('tnt.mongo.live')

--- Окружение стенда — через `tnt-env`: мимо него окружение не читают
--- и проверки.
local env = helper.stand_env()

--- Где стоит сервер: те же адреса и переменные, что у скрипта стенда.
local PORT = env.int('STAND_MONGO_PORT', 37017)
local TLS_DIR = env.string('MONGO_TLS_DIR', 'test/stand/run/mongo-tls')

--- Опознаватель прогона: коллекции прошлого прогона, упавшего на середине,
--- не мешают этому.
local RUN = uuid.str():sub(1, 8)

--- Отвечает ли кто-нибудь на порту стенда.
---@return boolean
local function reachable()
    local probe = require('socket').tcp_connect('127.0.0.1', PORT, 0.3)

    if probe ~= nil then
        probe:close()
    end

    return probe ~= nil
end

g.before_all(function()
    t.skip_if(not reachable(), 'MongoDB не отвечает: поднимите его — make mongo-up')
end)

--- Драйверы проверки: закрываются после неё.
---@type any[]
local opened = {}

g.after_each(function()
    for _, client in ipairs(opened) do
        client:close()
    end

    opened = {}
end)

--- Драйвер к стенду под учёткой `app`.
---@param opts table|nil Настройки поверх
---@return any
local function connect(opts)
    local given = opts or {}

    given.port = given.port or PORT
    given.db = given.db or 'tnt_live'

    if given.username == nil then
        given.username, given.password = 'app', 'app-secret'
    end

    given.pool = given.pool or {}
    given.pool.sweep_interval = 0

    local client = mongo.new(given)

    table.insert(opened, client)

    return client
end

--- Коллекция этой проверки.
---@param name string
---@return string
local function collection(name)
    return ('%s_%s'):format(name, RUN)
end

g.test_values_go_there_and_back_exactly = function()
    local db = connect()
    local name = collection('values')
    local id = mongo.object_id()
    local moment = datetime.new({ year = 2026, month = 9, day = 19, hour = 12, min = 34, sec = 56, nsec = 789000000 })
    local document = {
        _id = id,
        name = 'Анна',
        small = 7,
        wide = 9007199254740993LL,
        half = 1.5,
        price = decimal.new('1.10'),
        key = uuid.fromstr('6f5d9c77-6a4e-4a8b-9d7e-3a2f1c0b9e8d'),
        at = moment,
        bytes = storage.binary('\0\255'),
        json = storage.json({ a = 1 }),
        empty = box.NULL,
        list = { 1, 'two', box.NULL },
        nested = { deep = { yes = true } },
        order = mongo.ordered('b', 1, 'a', 2),
        stamp = mongo.timestamp(5, 7),
    }

    t.assert_equals(db:command({ 'insert', name, documents = { document } }).n, 1)

    local rows = db:query({ 'find', name, filter = { _id = id } }, { idempotent = true })
    local back = rows[1]

    t.assert(back._id == id)
    t.assert_equals(back.name, 'Анна')
    t.assert_equals(back.small, 7)
    t.assert_equals(back.wide, 9007199254740993LL)
    t.assert_equals(back.half, 1.5)
    t.assert_equals(tostring(back.price), '1.10')
    t.assert_equals(back.key, document.key)
    t.assert_equals(tostring(back.at), '2026-09-19T12:34:56.789Z')
    t.assert(varbinary.is(back.bytes))
    t.assert_equals(tostring(back.bytes), '\0\255')
    t.assert_equals(back.json, '{"a":1}')
    t.assert(rawequal(back.empty, box.NULL))
    t.assert_equals(#back.list, 3)
    t.assert(rawequal(back.list[3], box.NULL))
    t.assert_equals(back.nested.deep.yes, true)
    t.assert_equals(back.order, { a = 2, b = 1 })
    t.assert_equals(tostring(back.stamp), 'Timestamp(5, 7)')

    -- `null` и отсутствие — разное: `$exists` различает.
    t.assert_equals(#db:query({ 'find', name, filter = { empty = { ['$exists'] = true } } }), 1)
    t.assert_equals(#db:query({ 'find', name, filter = { missing = { ['$exists'] = true } } }), 0)
    db:command({ 'drop', name })
end

g.test_a_duplicate_key_is_rejected_without_values_in_the_reason = function()
    local db = connect()
    local name = collection('dup')

    db:command({ 'insert', name, documents = { { _id = 'секрет' } } })

    local reply, err = db:command({ 'insert', name, documents = { { _id = 'секрет' } } })

    t.assert_equals(reply, nil)
    t.assert_equals({ err.kind, err.server_code, err.retriable, err.sent }, { 'rejected', 11000, false, true })
    t.assert_str_contains(err.message, 'E11000 duplicate key error')
    t.assert_equals(err.reason, 'сервер отказал: без имени, код 11000')
    db:command({ 'drop', name })
end

g.test_a_cursor_is_read_in_batches_and_bounded = function()
    local db = connect()
    local name = collection('cursor')
    local documents = {}

    for index = 1, 25 do
        documents[index] = { _id = index }
    end

    db:command({ 'insert', name, documents = documents })

    local rows = db:query({ 'find', name, filter = {}, sort = mongo.ordered('_id', 1), batchSize = 4 })

    t.assert_equals(#rows, 25)
    t.assert_equals({ rows[1]._id, rows[25]._id }, { 1, 25 })

    local _, err = db:query({ 'find', name, filter = {}, batchSize = 4 }, { max_rows = 10 })

    t.assert_equals(err.kind, 'overflow')

    local aggregated = db:query({ 'aggregate', name, pipeline = { { ['$count'] = 'n' } }, cursor = {} })

    t.assert_equals(aggregated, { { n = 25 } })
    db:command({ 'drop', name })
end

g.test_logins_are_checked_by_the_server = function()
    local _, wrong = connect({ username = 'app', password = 'wrong' }):command({ 'ping', 1 })

    t.assert_equals({ wrong.kind, wrong.server_code, wrong.retriable }, { 'denied', 18, false })
    t.assert_not_str_contains(tostring(wrong), 'wrong')

    t.assert_equals(connect({ username = 'we,ird=name', password = 'weird-secret' }):command({ 'ping', 1 }).ok, 1)

    local _, forbidden = connect({ username = 'reader', password = 'reader-secret' }):command({
        'insert',
        collection('forbidden'),
        documents = { {} },
    })

    t.assert_equals({ forbidden.kind, forbidden.server_code }, { 'denied', 13 })
    t.assert_equals(forbidden.reason, 'сервер отказал: Unauthorized, код 13')

    local _, foreign = connect({ replica_set = 'other' }):command({ 'ping', 1 })

    t.assert_equals(foreign.kind, 'denied')
    t.assert_str_contains(foreign.message, 'узел не из набора реплик other, а из rs0')
end

g.test_tls_talks_with_the_root_of_the_stand = function()
    local secured = connect({ tls = { ca_file = TLS_DIR .. '/ca.pem' } })

    t.assert_equals(secured:command({ 'ping', 1 }).ok, 1)

    local _, strange = connect({ tls = true, timeout = 1 }):command({ 'ping', 1 })

    t.assert_equals(strange.kind, 'unreachable')
    t.assert_str_contains(strange.message, 'рукопожатие TLS не прошло')
end

g.test_a_server_time_limit_is_a_timeout = function()
    local db = connect()
    local name = collection('slow')

    db:command({ 'insert', name, documents = { {} } })

    --- Фильтр, который зовёт функцию JavaScript с таким телом.
    ---@param body string
    ---@return table
    local function scripted(body)
        return {
            ['$expr'] = {
                -- Пустой массив — явно: пустая таблица ушла бы документом.
                ['$function'] = { body = body, args = setmetatable({}, { __serialize = 'seq' }), lang = 'js' },
            },
        }
    end

    local slow = scripted('function() { sleep(300); return true; }')

    -- Движок JavaScript свежий сервер заводит первым `$function`, и срок,
    -- вышедший посреди заводки, он называет не MaxTimeMSExpired (50),
    -- а Interrupted (11601). Заводка — заранее и без срока.
    t.assert_equals(#db:query({ 'find', name, filter = scripted('function() { return true; }') }), 1)

    local _, err = db:query({ 'find', name, filter = slow, maxTimeMS = 50 })

    t.assert_equals({ err.kind, err.server_code, err.sent }, { 'timeout', 50, true })

    local started = clock.monotonic()
    local _, expired = db:query({ 'find', name, filter = slow }, { timeout = 0.1 })

    t.assert_equals({ expired.kind, expired.sent }, { 'timeout', true })
    t.assert(clock.monotonic() - started < 0.3)
    t.assert_equals(db:stats().drops, 1)
    db:command({ 'drop', name })
end

g.test_a_transaction_commits_or_aborts_on_the_replica_set = function()
    local db = connect({ replica_set = 'rs0' })
    local name = collection('tx')

    db:command({ 'create', name })

    t.assert_equals(db.features, { transaction = true })

    local done = db:transaction(function(tx)
        tx:command({ 'insert', name, documents = { { _id = 1 } } })

        t.assert_equals(#tx:query({ 'find', name, filter = {} }), 1)
    end)

    t.assert_equals(done, true)

    local _, err = db:transaction(function(tx)
        tx:command({ 'insert', name, documents = { { _id = 2 } } })

        return nil, 'передумали'
    end)

    t.assert_equals(err, 'передумали')

    local ok = pcall(db.transaction, db, function(tx)
        tx:command({ 'insert', name, documents = { { _id = 3 } } })
        error('сломалось')
    end)

    t.assert_equals(ok, false)
    t.assert_equals(db:query({ 'find', name, filter = {} }), { { _id = 1 } })
    db:command({ 'drop', name })
end

g.test_a_write_conflict_is_repeated_as_a_whole = function()
    local db = connect({ replica_set = 'rs0', pool = { size = 2 } })
    local name = collection('conflict')
    local bump = function(by)
        return { 'update', name, updates = { { q = { _id = 1 }, u = { ['$inc'] = { n = by } } } } }
    end

    db:command({ 'insert', name, documents = { { _id = 1, n = 0 } } })

    local runs = 0
    local done, err = db:transaction(function(tx)
        runs = runs + 1

        -- Чтение открывает снимок; сосед правит документ после него,
        -- и запись транзакции в тот же документ — конфликт.
        tx:query({ 'find', name, filter = { _id = 1 } })

        if runs == 1 then
            t.assert_equals(db:command(bump(10)).nModified, 1)
        end

        tx:command(bump(1))
    end, { retry = true, timeout = 10 })

    t.assert_equals({ done, err }, { true, nil })
    t.assert_equals(runs, 2)
    t.assert_equals(db:query({ 'find', name, filter = {} })[1].n, 11)
    db:command({ 'drop', name })
end
