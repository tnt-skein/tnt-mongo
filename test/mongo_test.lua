--- Проверки фасада: команда и выборка, отказ парой с родом, возврат
--- и выброс соединения, повторы по приговору, один срок на вызов,
--- закрытие и отмена — на двойнике сервера с настоящим сокетом.

local clock = require('clock')
local fiber = require('fiber')
local json = require('json')
local t = require('luatest')

local helper = dofile('test/helper.lua')

local mongo = helper.mongo

local g = t.group('tnt.mongo')

--- Что убрать после проверки: закрыть драйвер, погасить двойник,
--- снять ловушку журнала. Убирается с конца.
---@type function[]
local cleanup = {}

g.after_each(function()
    helper.restore()

    for index = #cleanup, 1, -1 do
        cleanup[index]()
    end

    cleanup = {}
end)

--- Ловушка журнала на эту проверку.
---@return table
local function journal()
    local trap = helper.capture_log()

    table.insert(cleanup, trap.release)

    return trap
end

--- Поднимает двойник сервера и драйвер к нему на эту проверку.
---@param respond fun(command: table, number: integer): any
---@param opts table|nil Настройки драйвера
---@param serve_opts table|nil Настройки двойника
---@return any client
---@return TntMongoFake fake
local function connect(respond, opts, serve_opts)
    local fake = helper.serve(respond, serve_opts)
    local client = helper.client(fake, opts)

    table.insert(cleanup, fake.stop)
    table.insert(cleanup, function()
        client:close()
    end)

    return client, fake
end

--- Род, приговор и отправка отказа — списком.
---@param err any
---@return table
local function verdict(err)
    return { err.kind, err.retriable, err.sent }
end

--- Ждёт, пока соседний файбер не займёт единственное соединение.
---@param client any
local function occupied(client)
    t.helpers.retrying({ timeout = 2 }, function()
        t.assert_equals(client:stats().busy, 1)
    end)
end

g.test_the_facade_names_its_values = function()
    t.assert_equals(mongo.MIN_KEY, helper.types.MIN_KEY)
    t.assert_equals(mongo.MAX_KEY, helper.types.MAX_KEY)
    t.assert_equals(mongo.object_id, helper.types.object_id)
    t.assert_equals(mongo.ordered, helper.types.ordered)
    t.assert_equals(mongo.timestamp, helper.types.timestamp)
    t.assert_equals(mongo.regex, helper.types.regex)
    t.assert_equals(mongo.binary, helper.types.binary)
end

g.test_a_command_answers_and_the_connection_serves_the_next = function()
    local client, fake = connect(function(command)
        if command.insert ~= nil then
            return { ok = 1, n = #command.documents }
        end

        if command.ping ~= nil then
            return { ok = 1 }
        end
    end, { name = 'orders', username = 'app', password = 'hunter2' }, { users = { app = 'hunter2' } })

    local reply = client:command({ 'insert', 'users', documents = { { _id = 7, name = 'Анна' } } })

    t.assert_equals({ reply.ok, reply.n }, { 1, 1 })
    t.assert_equals(client:command({ 'ping', 1 }, { db = 'admin' }).ok, 1)
    t.assert_equals(fake.connections, 1)

    local sent = helper.sent(fake)

    t.assert_equals(sent[1].insert, 'users')
    t.assert_equals(sent[1]['$db'], 'shop')
    t.assert_equals(sent[1].documents[1], { _id = 7, name = 'Анна' })
    t.assert_equals(sent[2]['$db'], 'admin')

    local stats = client:stats()

    t.assert_equals({ stats.name, stats.busy, stats.idle, stats.takes, stats.gives }, { 'orders', 0, 1, 2, 2 })
    t.assert_not_str_contains(json.encode(stats), 'hunter2')
end

g.test_a_query_reads_the_whole_cursor = function()
    local client, fake = connect(function(command)
        if command.find ~= nil then
            return { ok = 1, cursor = { id = 3, ns = 'shop.users', firstBatch = { { n = 1 } } } }
        end

        if command.getMore ~= nil then
            return { ok = 1, cursor = { id = 0, ns = 'shop.users', nextBatch = { { n = 2 } } } }
        end
    end)
    local rows = client:query({ 'find', 'users', filter = {}, sort = mongo.ordered('n', 1) })

    t.assert_equals(rows, { { n = 1 }, { n = 2 } })
    t.assert_equals(helper.sent(fake)[1].sort, { n = 1 })

    local _, err = client:query({ 'find', 'users' }, { max_rows = 1 })

    t.assert_equals(err.kind, 'overflow')
end

g.test_query_goes_only_with_cursor_commands = function()
    local client = connect(function() end)

    helper.assert_blamed({
        {
            function()
                client:query({ 'count', 'users' })
            end,
            'query ходит с командами курсора (find, aggregate, listCollections, listIndexes), а не count',
        },
    })
end

g.test_wrong_call_settings_are_an_error_of_the_caller = function()
    local client = connect(function() end)
    local cases = {
        {
            function()
                client:command({ 'ping', 1 }, { timout = 1 })
            end,
            'настройки вызова: ключа «timout» нет, есть db, idempotent, timeout',
        },
        {
            function()
                client:command({ 'ping', 1 }, { max_rows = 1 })
            end,
            'настройки вызова: ключа «max_rows» нет, есть db, idempotent, timeout',
        },
        {
            function()
                client:query({ 'find', 'users' }, { max_rows = 0 })
            end,
            'max_rows — число больше 0, а не 0',
        },
        {
            function()
                client:command({ 'ping', 1 }, { timeout = 61 })
            end,
            'timeout 61 с длиннее потолка max_timeout 60 с',
        },
        {
            function()
                client:command({ 'ping' })
            end,
            'у команды ping нет значения: { "ping", коллекция либо 1, … }',
        },
    }

    helper.assert_blamed(cases)
end

g.test_a_refusal_of_the_server_is_a_pair_and_the_connection_stays = function()
    local client, fake = connect(function(command)
        if command.insert ~= nil then
            return {
                ok = 1,
                n = 0,
                writeErrors = { { index = 0, code = 11000, errmsg = 'E11000 duplicate key dup key: { _id: 7 }' } },
            }
        end
    end)
    local reply, err = client:command({ 'insert', 'users', documents = { { _id = 7 } } }, { idempotent = true })

    t.assert_equals(reply, nil)
    t.assert(helper.failure.is(err))
    t.assert_equals(verdict(err), { 'rejected', false, true })
    t.assert_equals(err.server_code, 11000)
    t.assert_equals(tostring(err), 'запись 0 отвергнута: E11000 duplicate key dup key: { _id: 7 }')
    t.assert_equals(client:stats().drops, 0)
    t.assert_equals(#helper.sent(fake), 1)
end

g.test_a_former_primary_drops_the_connection_and_is_repeated = function()
    local trap = journal()

    local client, fake = connect(function(command, number)
        if command.insert ~= nil and number == 1 then
            return { ok = 0, code = 10107, codeName = 'NotWritablePrimary', errmsg = 'not primary' }
        end

        if command.insert ~= nil then
            return { ok = 1, n = 1 }
        end
    end)

    t.assert_equals(client:command({ 'insert', 'users', documents = { {} } }).n, 1)
    t.assert_equals(fake.connections, 2)
    t.assert_equals(client:stats().drops, 1)

    local record = trap.find('WARN [tnt.mongo] соединение выброшено')

    t.assert_equals(record.record.fields, {
        driver = 'mongo',
        kind = 'busy',
        reason = 'сервер отказал: NotWritablePrimary, код 10107',
    })
end

g.test_an_unanswered_command_is_a_timeout_and_the_connection_is_dropped = function()
    local trap = journal()

    local client, fake = connect(function(command)
        if command.find ~= nil then
            return { delay = 5 }
        end
    end)
    local started = clock.monotonic()
    local rows, err = client:query({ 'find', 'secret' }, { timeout = 0.1 })
    local spent = clock.monotonic() - started

    t.assert_equals(rows, nil)
    t.assert_equals(verdict(err), { 'timeout', false, true })
    t.assert_equals(
        err.message,
        ('mongo 127.0.0.1:%d: ответа нет за срок вызова'):format(fake.port)
    )
    t.assert(spent >= 0.09 and spent < 0.4, spent)
    t.assert_equals(client:stats().drops, 1)
    t.assert_not(trap.logged('secret'))
end

g.test_a_broken_connection_is_repeated_only_when_idempotent = function()
    local cut = true
    local client, fake = connect(function(command)
        if command.update ~= nil and cut then
            cut = false

            return { close = true }
        end

        if command.update ~= nil then
            return { ok = 1, n = 1 }
        end
    end)
    local _, err = client:command({ 'update', 'users', updates = {} })

    t.assert_equals(verdict(err), { 'broken', false, true })

    cut = true

    t.assert_equals(client:command({ 'update', 'users', updates = {} }, { idempotent = true }).n, 1)
    t.assert_equals(fake.connections, 3)
end

g.test_a_closed_port_is_unreachable_within_the_deadline = function()
    local port = helper.closed_port()

    local client = mongo.new({
        db = 'shop',
        port = port,
        timeout = 0.3,
        pool = { wait_timeout = 0.1, sweep_interval = 0, open_cooldown = 0.02 },
        retry = { base = 0 },
    })

    table.insert(cleanup, function()
        client:close()
    end)

    local started = clock.monotonic()

    local _, err = client:command({ 'ping', 1 })
    local spent = clock.monotonic() - started

    -- Последняя попытка входа могла не уложиться в остаток срока: текст
    -- отказа сети тогда «Operation timed out», а не «Connection refused».
    t.assert_equals(verdict(err), { 'unreachable', true, false })
    t.assert_str_contains(
        err.message,
        ('mongo 127.0.0.1:%d: соединение не получено за'):format(port)
    )
    t.assert(spent >= 0.25 and spent < 0.6, spent)
end

g.test_a_login_denied_comes_at_once = function()
    -- «Сразу» — без повторов: неверный пароль не лечится ни новым
    -- соединением, ни новой попыткой входа. Проверяется счётом, а не
    -- временем: вход считает PBKDF2 в Lua, и под покрытием одна попытка
    -- идёт почти секунду — предел по часам падал без всякой ошибки.
    local client, fake = connect(
        function() end,
        { username = 'app', password = 'wrong' },
        { users = { app = 'secret' } }
    )
    local _, err = client:command({ 'ping', 1 })
    local logins = 0

    for _, command in ipairs(fake.commands) do
        logins = logins + (command.saslStart ~= nil and 1 or 0)
    end

    t.assert_equals(verdict(err), { 'denied', false, false })
    t.assert_equals({ fake.connections, logins, #helper.sent(fake) }, { 1, 1, 0 })
end

g.test_a_busy_pool_is_busy = function()
    local client, fake = connect(function(command)
        if command.find ~= nil then
            return { delay = 0.5, reply = { ok = 1, cursor = { id = 0, ns = 'shop.users', firstBatch = {} } } }
        end

        if command.ping ~= nil then
            return { ok = 1 }
        end
    end, { pool = { size = 1, wait_timeout = 0.1 }, retry = { attempts = 1 } })
    local worker = fiber.new(function()
        client:query({ 'find', 'users' })
    end)

    worker:set_joinable(true)
    occupied(client)

    local _, err = client:command({ 'ping', 1 }, { timeout = 0.2 })

    t.assert_equals(verdict(err), { 'busy', true, false })
    t.assert_str_contains(
        err.message,
        ('mongo 127.0.0.1:%d: соединение не получено за 0.1 с'):format(fake.port)
    )
    worker:join()
end

g.test_a_pool_timeout_is_unreachable_only_with_room_and_an_open_failure = function()
    local client, fake = connect(function() end)
    local pool = client.pool
    local failed = 'открыть соединение не удалось: отказ'
    local cases = {
        -- Место есть, а открытие отказало: служба недоступна.
        { { total = 0, size = 1, last_open_error = failed }, 'unreachable' },
        -- Мест нет: отказ открытия — след прошлого, пул его не забывает.
        { { total = 1, size = 1, last_open_error = failed }, 'busy' },
        -- Место есть, а отказов не было: соединение ещё открывается.
        { { total = 0, size = 1 }, 'busy' },
    }

    for index, case in ipairs(cases) do
        client.pool = {
            stats = function()
                return case[1]
            end,
        }

        local err = client:_refusal('соединение не получено за 0.1 с')

        t.assert_equals({ err.kind, err.message }, {
            case[2],
            ('mongo 127.0.0.1:%d: соединение не получено за 0.1 с'):format(fake.port),
        }, index)
    end

    client.pool = pool
end

--- Часы: миг срока стоит на тысячной секунде, а время планировщика
--- ставит проверка.
---@return { now: number }
local function frozen()
    local clocks = { now = 1000 }

    helper.within._set_source({
        monotonic = function()
            return 1000
        end,
        scheduler_now = function()
            return clocks.now
        end,
    })

    return clocks
end

g.test_a_deadline_gone_before_the_first_attempt_sends_nothing = function()
    local client, fake = connect(function() end)
    local clocks = frozen()

    -- Остаток ровно ноль — тоже «срок вышел», как и меньше нуля.
    for _, shift in ipairs({ 5, 100 }) do
        clocks.now = 1000 + shift

        local _, err = client:command({ 'ping', 1 })

        t.assert_equals(verdict(err), { 'timeout', false, false }, shift)
        t.assert_equals(err.message, 'срок вызова вышел до отправки команды', shift)
    end

    t.assert_equals(fake.connections, 0)
end

g.test_a_deadline_gone_while_waiting_for_the_pool_returns_the_connection = function()
    for _, shift in ipairs({ 5, 100 }) do
        local clocks = frozen()
        local client, fake = connect(function(command)
            if command.hello ~= nil then
                clocks.now = 1000 + shift
            end
        end)
        local _, err = client:command({ 'ping', 1 })

        t.assert_equals(verdict(err), { 'timeout', false, false }, shift)
        t.assert_equals(helper.sent(fake), {}, shift)

        local stats = client:stats()

        t.assert_equals({ stats.idle, stats.drops }, { 1, 0 }, shift)
        client:close()
        fake.stop()
    end
end

g.test_a_deadline_gone_before_a_repeat_gives_the_last_refusal = function()
    local clocks = frozen()
    local client, fake = connect(function(command)
        if command.ping ~= nil then
            clocks.now = 1005

            return { ok = 0, code = 10107, codeName = 'NotWritablePrimary', errmsg = 'not primary' }
        end
    end)
    local _, err = client:command({ 'ping', 1 })

    t.assert_equals(verdict(err), { 'busy', false, false })
    t.assert_equals(err.message, 'not primary')
    t.assert_equals(err.server_code, 10107)
    t.assert_equals(err.reason, 'сервер отказал: NotWritablePrimary, код 10107')
    t.assert_equals(#helper.sent(fake), 1)
end

g.test_a_closed_driver_refuses_by_a_pair = function()
    local client = connect(function() end)

    t.assert_equals({ client:close() }, { true })

    local again, err = client:close()

    t.assert_equals(again, false)
    t.assert_equals({ err.kind, err.message }, { 'closed', 'mongo: драйвер уже закрыт' })

    local reply, refused = client:command({ 'ping', 1 })

    t.assert_equals(reply, nil)
    t.assert_equals(verdict(refused), { 'closed', false, false })
    t.assert_equals(refused.message, 'mongo: драйвер закрыт')
end

g.test_a_cancelled_caller_gets_the_cancel_and_the_connection_is_dropped = function()
    local client = connect(function(command)
        if command.find ~= nil then
            return { delay = 5 }
        end
    end)
    ---@type any
    local raised
    local worker = fiber.new(function()
        local ok, err = pcall(client.query, client, { 'find', 'users' })

        raised = { ok, tostring(err) }
    end)

    worker:set_joinable(true)
    occupied(client)
    worker:cancel()
    worker:join()

    t.assert_equals(raised[1], false)
    t.assert_str_contains(raised[2], 'fiber is cancelled')
    t.helpers.retrying({ timeout = 1 }, function()
        t.assert_equals(client:stats().busy, 0)
    end)
end

g.test_a_bad_retry_setting_leaves_no_pool = function()
    helper.assert_blamed({
        {
            function()
                mongo.new({ db = 'shop', retry = { jitter = 'wide' } })
            end,
            "настройки mongo.retry: настройка jitter — доля от 0 до 1 либо 'decorrelated', а пришло: wide",
        },
    })
end
