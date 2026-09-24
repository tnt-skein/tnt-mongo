--- Проверки связи: вход (hello, набор реплик, SCRAM), TLS через внешнюю зависимость,
--- обмен со сроком, обрыв и живость — на двойнике с настоящим сокетом.

local clock = require('clock')
local fiber = require('fiber')
local t = require('luatest')

local helper = dofile('test/helper.lua')

local link, within = helper.link, helper.within

local g = t.group('tnt.mongo.link')

--- Двойники этой проверки: гасятся после неё все разом.
---@type TntMongoFake[]
local running = {}

g.after_each(function()
    helper.restore()

    for _, fake in ipairs(running) do
        fake.stop()
    end

    running = {}
end)

--- Поднимает двойник на эту проверку.
---@param respond fun(command: table, number: integer): any
---@param opts table|nil
---@return TntMongoFake
local function serve(respond, opts)
    local fake = helper.serve(respond, opts)

    table.insert(running, fake)

    return fake
end

--- Настройки связи к двойнику.
---@param fake any Двойник; пусто — порт в `opts`
---@param opts table|nil Поверх
---@return TntMongoSettings
local function settings(fake, opts)
    local given = table.deepcopy(opts or {})

    given.db = 'shop'
    given.port = given.port or fake.port

    return helper.settings.check(given)
end

--- Отказ входа: род и текст, до отправки, а повтор — только у `unreachable`.
---@param err any
---@param kind string
---@param message string
local function assert_refused(err, kind, message)
    t.assert_equals({ err.kind, err.message, err.retriable, err.sent }, { kind, message, kind == 'unreachable', false })
end

g.test_open_says_hello_with_the_client_description = function()
    local fake = serve(function() end)
    local opened = link.open(settings(fake, { name = 'orders' }), 1)

    t.assert_equals(opened.secured, false)
    t.assert_equals(opened.next_id, 2)
    t.assert_equals(opened.transactions, 0)
    t.assert_equals(#tostring(opened.session), 36)

    local hello = fake.commands[1]

    t.assert_equals(hello.hello, 1)
    t.assert_equals(hello['$db'], 'admin')
    t.assert_equals(hello.client.application.name, 'orders')
    t.assert_equals(hello.client.driver, { name = 'tnt-mongo', version = 'scm-1' })
    t.assert_equals(hello.client.os.type, jit.os)
    t.assert_equals(hello.client.platform, 'Tarantool ' .. _TARANTOOL)
    t.assert_equals(link.alive(opened), true)

    link.close(opened)
    link.close(opened)
end

g.test_a_hello_refused_is_unreachable = function()
    local fake = serve(function(command)
        if command.hello ~= nil then
            return { ok = 0, code = 59, codeName = 'CommandNotFound', errmsg = "no such command: 'hello'" }
        end
    end)
    local opened, err = link.open(settings(fake), 1)

    t.assert_equals(opened, nil)
    assert_refused(
        err,
        'unreachable',
        ("mongo 127.0.0.1:%d: вход не удался: no such command: 'hello'"):format(fake.port)
    )
    t.assert_equals(err.server_code, 59)
end

g.test_the_replica_set_is_checked = function()
    local fake = serve(function() end, { set_name = 'rs0' })

    t.assert_not_equals(link.open(settings(fake, { replica_set = 'rs0' }), 1), nil)

    local opened, err = link.open(settings(fake, { replica_set = 'rs1' }), 1)

    t.assert_equals(opened, nil)
    assert_refused(
        err,
        'denied',
        ('mongo 127.0.0.1:%d: узел не из набора реплик rs1, а из rs0'):format(fake.port)
    )

    fake.stop()

    local lone = serve(function() end)
    local _, alone = link.open(settings(lone, { replica_set = 'rs1' }), 1)

    t.assert_equals(
        alone.message,
        ('mongo 127.0.0.1:%d: узел не из набора реплик rs1, а из никакого'):format(
            lone.port
        )
    )
end

g.test_scram_logs_in_and_escapes_the_name = function()
    local fake = serve(function() end, { users = { ['we,ird=name'] = 'secret' } })
    local opened = link.open(settings(fake, { username = 'we,ird=name', password = 'secret', auth_source = 'shop' }), 2)

    t.assert_not_equals(opened, nil)

    local start, finish = fake.commands[2], fake.commands[3]

    t.assert_equals(#fake.commands, 3)
    t.assert_equals(start.saslStart, 1)
    t.assert_equals(start.mechanism, 'SCRAM-SHA-256')
    t.assert_equals(start.options, { skipEmptyExchange = true })
    t.assert_equals(start['$db'], 'shop')
    t.assert_str_matches(tostring(start.payload), '^n,,n=we=2Cird=3Dname,r=.*')
    t.assert_equals(finish.saslContinue, 1)
    t.assert_equals(finish.conversationId, 1)
    t.assert_equals(finish['$db'], 'shop')
end

g.test_an_old_server_asks_one_more_empty_step = function()
    local fake = serve(function() end, { users = { app = 'secret' }, old = true })
    local opened = link.open(settings(fake, { username = 'app', password = 'secret' }), 2)

    t.assert_not_equals(opened, nil)
    t.assert_equals(#fake.commands, 4)
    t.assert_equals(tostring(fake.commands[4].payload), '')
end

g.test_a_wrong_password_is_denied = function()
    local fake = serve(function() end, { users = { app = 'secret' } })
    local opened, err = link.open(settings(fake, { username = 'app', password = 'wrong' }), 2)

    t.assert_equals(opened, nil)
    assert_refused(
        err,
        'denied',
        ('mongo 127.0.0.1:%d: вход не удался: Authentication failed.'):format(fake.port)
    )
    t.assert_equals(err.server_code, 18)
    t.helpers.retrying({ timeout = 1 }, function()
        t.assert_equals(fake.finished, 1)
    end)
end

g.test_a_server_that_lies_in_scram_is_denied = function()
    local fake = serve(function(command)
        if command.saslStart ~= nil then
            return {
                ok = 1,
                conversationId = 1,
                done = false,
                payload = require('varbinary').new('r=other,s=c2FsdA==,i=4096'),
            }
        end
    end)
    local _, err = link.open(settings(fake, { username = 'app', password = 'secret' }), 2)

    t.assert_equals(err.kind, 'denied')
    t.assert_str_matches(
        err.message,
        ('^mongo 127.0.0.1:%d: вход не удался: '):format(fake.port)
            .. 'ответ сервера на вход не по SCRAM либо не на наше случайное: r=other.*'
    )

    fake.stop()

    local forger = serve(function(command)
        if command.saslContinue ~= nil then
            return { ok = 1, conversationId = 1, done = true, payload = require('varbinary').new('v=AAAA') }
        end
    end, { users = { app = 'secret' } })
    local _, forged = link.open(settings(forger, { username = 'app', password = 'secret' }), 2)

    assert_refused(
        forged,
        'denied',
        ('mongo 127.0.0.1:%d: вход не удался: подпись сервера не сошлась: он не знает пароля'):format(
            forger.port
        )
    )

    forger.stop()

    -- Законный первый шаг, но сразу `done`: ни доказательства клиента,
    -- ни подписи сервера — такой вход не вход.
    local hasty = serve(function(command)
        if command.saslStart ~= nil then
            local nonce = tostring(command.payload):match(',r=(.*)$')

            return {
                ok = 1,
                conversationId = 1,
                done = true,
                payload = require('varbinary').new(('r=%sfake,s=c2FsdA==,i=4096'):format(nonce)),
            }
        end
    end)
    local skipped, unsigned = link.open(settings(hasty, { username = 'app', password = 'secret' }), 2)

    t.assert_equals(skipped, nil)
    assert_refused(
        unsigned,
        'denied',
        ('mongo 127.0.0.1:%d: вход не удался: сервер кончил вход, не подписавшись: он не знает пароля'):format(
            hasty.port
        )
    )
    t.assert_equals(#hasty.commands, 2)
    t.helpers.retrying({ timeout = 1 }, function()
        t.assert_equals(hasty.finished, 1)
    end)
end

g.test_a_mechanism_the_server_lacks_is_denied = function()
    local fake = serve(function(command)
        if command.saslStart ~= nil then
            return {
                ok = 0,
                code = 334,
                codeName = 'MechanismUnavailable',
                errmsg = 'Received authentication for mechanism SCRAM-SHA-256 which is not enabled',
            }
        end
    end)
    local _, err = link.open(settings(fake, { username = 'app', password = 'secret' }), 2)

    assert_refused(
        err,
        'denied',
        ('mongo 127.0.0.1:%d: вход не удался: %s'):format(
            fake.port,
            'Received authentication for mechanism SCRAM-SHA-256 which is not enabled'
        )
    )
    t.assert_equals(err.server_code, 334)
end

g.test_a_second_sasl_step_refused_is_denied = function()
    local fake = serve(function(command)
        if command.saslContinue ~= nil then
            return { ok = 0, code = 18, codeName = 'AuthenticationFailed', errmsg = 'Authentication failed.' }
        end
    end, { users = { app = 'secret' } })
    local _, err = link.open(settings(fake, { username = 'app', password = 'secret' }), 2)

    t.assert_equals({ err.kind, err.server_code }, { 'denied', 18 })
end

g.test_a_closed_port_is_unreachable = function()
    local port = helper.closed_port()
    local opened, err = link.open(settings(nil, { port = port }), 1)

    t.assert_equals(opened, nil)
    assert_refused(
        err,
        'unreachable',
        ('mongo 127.0.0.1:%d: соединение не открылось: Connection refused'):format(port)
    )
end

g.test_a_connect_that_raises_is_unreachable = function()
    local calls = {}

    link._set_source({
        connect = function(...)
            calls[#calls + 1] = { ... }

            error('имя узла не разрешилось', 0)
        end,
    })

    local _, err = link.open(settings(nil, { host = 'db', port = 27018 }), 0.5)

    assert_refused(
        err,
        'unreachable',
        'mongo db:27018: соединение не открылось: имя узла не разрешилось'
    )
    t.assert_equals(calls, { { 'db', 27018, 0.5 } })
end

g.test_a_greeting_cut_short_is_unreachable = function()
    local fake = serve(function()
        return { close = true }
    end)
    local where = ('mongo 127.0.0.1:%d'):format(fake.port)

    assert_refused(
        select(2, link.open(settings(fake), 1)),
        'unreachable',
        where
            .. ': вход не завершился: соединение оборвалось: сервер закрыл его'
    )
end

g.test_an_unanswered_greeting_is_unreachable_in_time = function()
    local fake = serve(function()
        return { delay = 10 }
    end)
    local began = clock.monotonic()
    local _, err = link.open(settings(fake), 0.1)
    local took = clock.monotonic() - began

    assert_refused(
        err,
        'unreachable',
        ('mongo 127.0.0.1:%d: вход не завершился: ответа нет за срок вызова'):format(
            fake.port
        )
    )
    t.assert(took >= 0.09 and took < 0.5, took)
end

--- Соединение TLS двойником: разговор идёт тем же сокетом.
---@param socket any
---@return table
local function plain_tls(socket)
    local methods = {}

    function methods.read(_, opts, timeout)
        local piece = socket:read(opts, timeout)

        return piece, piece == nil and 'чтение TLS не удалось' or nil
    end

    function methods.write(_, data, timeout)
        return socket:write(data, timeout) ~= nil, 'запись TLS не удалась'
    end

    function methods.close()
        socket:close()
    end

    return methods
end

--- Шифрование двойником: настройки, ушедшие в `tnt-tls`, запоминаются.
---@param asked table[] Куда складывать настройки
---@param refusal string|nil Чем отказать вместо рукопожатия
local function fake_tls(asked, refusal)
    local tls = {
        wrap = function(socket, opts)
            asked[#asked + 1] = opts

            if refusal == nil then
                return plain_tls(socket)
            end

            return nil, refusal
        end,
    }

    link._set_source({
        tls = function()
            return tls
        end,
    })
end

g.test_tls_goes_through_tnt_tls_with_the_rest_of_the_deadline = function()
    local fake = serve(function() end)
    local asked = {}

    fake_tls(asked)

    local opened =
        link.open(settings(fake, { tls = { verify = false, ca_file = '/ca.pem', ca_path = '/ca', sni = 'db' } }), 0.5)

    t.assert_equals(opened.secured, true)
    t.assert_equals(#asked, 1)
    t.assert(asked[1].timeout > 0.4 and asked[1].timeout <= 0.5, asked[1].timeout)
    asked[1].timeout = nil
    t.assert_equals(asked[1], { host = '127.0.0.1', verify = false, ca_file = '/ca.pem', ca_path = '/ca', sni = 'db' })
    t.assert_equals(link.alive(opened), true)

    link.close(opened)
end

g.test_a_failed_handshake_is_unreachable_and_closes_the_socket = function()
    local fake = serve(function() end)

    fake_tls({}, 'сертификат не прошёл проверку')

    local opened, err = link.open(settings(fake, { tls = true }), 1)
    local where = ('mongo 127.0.0.1:%d'):format(fake.port)

    t.assert_equals(opened, nil)
    assert_refused(
        err,
        'unreachable',
        where
            .. ': рукопожатие TLS не прошло: сертификат не прошёл проверку'
    )

    -- Сокет, под которым рукопожатие сорвалось, закрыт: двойник видит конец.
    t.helpers.retrying({ timeout = 1 }, function()
        t.assert_equals(fake.finished, fake.connections)
        t.assert_equals(fake.finished, 1)
    end)
end

g.test_a_server_without_tls_fails_the_real_handshake = function()
    -- Настоящий `tnt-tls` против двойника, который TLS не говорит.
    local fake = serve(function() end)
    local _, err = link.open(settings(fake, { tls = { verify = false } }), 2)

    t.assert_equals(err.kind, 'unreachable')
    t.assert_equals(err.retriable, true)
    t.assert_str_matches(
        err.message,
        ('^mongo 127.0.0.1:%d: рукопожатие TLS не прошло: .+'):format(fake.port)
    )
    t.assert_equals(#fake.commands, 0)
end

g.test_no_time_left_for_the_handshake_is_refused_by_tnt_tls = function()
    local fake = serve(function() end)

    within._set_source({
        monotonic = function()
            return 100
        end,
        scheduler_now = function()
            return 101
        end,
    })

    local _, err = link.open(settings(fake, { tls = { verify = false } }), 1)

    t.assert_equals(
        err.message,
        ('mongo 127.0.0.1:%d: рукопожатие TLS не прошло: %s'):format(
            fake.port,
            'срок ожидания должен быть положительным числом, а не 0'
        )
    )
end

--- Открытое соединение к двойнику.
---@param respond fun(command: table, number: integer): any
---@return TntMongoLink
---@return TntMongoFake
local function opened(respond)
    local fake = serve(respond)

    return link.open(settings(fake), 1), --[[@as TntMongoLink]]
        fake
end

g.test_exchange_numbers_requests_and_reads_the_reply = function()
    local conn = opened(function(command)
        if command.ping ~= nil then
            return { ok = 1, echo = command.ping }
        end
    end)
    local reply = link.exchange(conn, helper.document('ping', 5, '$db', 'shop'), within.deadline(1), 1000)

    t.assert_equals(reply.echo, 5)
    t.assert_equals(conn.next_id, 3)

    conn.next_id = 2 ^ 31 - 1
    link.exchange(conn, helper.document('ping', 6, '$db', 'shop'), within.deadline(1), 1000)
    t.assert_equals(conn.next_id, 1)
    link.close(conn)
end

g.test_a_long_reply_is_read_in_pieces = function()
    local big = ('я'):rep(100000)
    local conn = opened(function(command)
        if command.ping ~= nil then
            return { ok = 1, big = big }
        end
    end)

    t.assert_equals(link.PIECE, 65536)

    local reply = link.exchange(conn, helper.document('ping', 1, '$db', 'shop'), within.deadline(2), 10 ^ 6)

    t.assert_equals(reply.big, big)
    link.close(conn)
end

g.test_a_silent_or_closing_server_is_timeout_or_broken = function()
    local conn, fake = opened(function(command)
        if command.ping == 1 then
            return { delay = 10 }
        end
    end)
    local _, trouble = link.exchange(conn, helper.document('ping', 1, '$db', 'shop'), within.deadline(0.1), 1000)

    t.assert_equals(trouble, { kind = 'timeout', message = 'ответа нет за срок вызова' })
    link.close(conn)
    fake.stop()

    conn = opened(function(command)
        if command.ping ~= nil then
            return { close = true }
        end
    end)

    _, trouble = link.exchange(conn, helper.document('ping', 2, '$db', 'shop'), within.deadline(1), 1000)
    t.assert_equals(
        trouble,
        { kind = 'broken', message = 'соединение оборвалось: сервер закрыл его' }
    )
    link.close(conn)
end

g.test_a_reply_cut_in_the_middle_is_broken = function()
    local conn = opened(function(command)
        if command.ping ~= nil then
            return { raw = helper.frame(2, helper.document('ok', 1)):sub(1, 20), close = true }
        end
    end)
    local _, trouble = link.exchange(conn, helper.document('ping', 1, '$db', 'shop'), within.deadline(1), 1000)

    t.assert_equals(
        trouble,
        { kind = 'broken', message = 'соединение оборвалось: сервер закрыл его' }
    )
end

g.test_a_reply_bson_cannot_read_is_rejected_or_broken = function()
    local conn = opened(function(command)
        if command.ping == 1 then
            -- Код JavaScript: запись цела, а выразить её нечем.
            return { raw = helper.frame(2, '\14\0\0\0\13c\0\2\0\0\0x\0\0') }
        end

        if command.ping == 2 then
            return { raw = helper.frame(3, '\5\0\0\0\0\1') }
        end
    end)
    local _, trouble = link.exchange(conn, helper.document('ping', 1, '$db', 'shop'), within.deadline(1), 1000)

    t.assert_equals(trouble, {
        kind = 'rejected',
        message = 'тип BSON 0x0D у поля "c" не поддерживается',
        clean = true,
    })

    _, trouble = link.exchange(conn, helper.document('ping', 2, '$db', 'shop'), within.deadline(1), 1000)
    t.assert_equals(
        trouble,
        { kind = 'broken', message = 'после документа ещё 1 байт', clean = false }
    )
    link.close(conn)
end

g.test_a_socket_closed_under_the_link_breaks_the_read_and_the_write = function()
    local conn = opened(function() end)

    conn.socket:close()

    local _, trouble = link.exchange(conn, helper.document('ping', 1, '$db', 'shop'), within.deadline(1), 1000)

    t.assert_equals(trouble.kind, 'broken')
    t.assert_equals(trouble.sent, false)
    t.assert_equals(trouble.retriable, true)
    t.assert_str_matches(trouble.message, '^команда не ушла: .+')
    t.assert_equals(link.alive(conn), false)
end

g.test_a_write_out_of_time_is_not_sent_and_not_retried = function()
    local conn = opened(function() end)

    within._set_source({
        monotonic = function()
            return 100
        end,
        scheduler_now = function()
            return 101
        end,
    })
    ---@diagnostic disable-next-line: missing-fields
    conn.io = {
        write = function()
            return nil
        end,
        error = function()
            return 'Connection timed out'
        end,
    }

    -- Миг — ровно «сейчас»: остаток ноль — это уже срок, а не обрыв.
    local _, trouble = link.exchange(conn, 'x', 101, 1000)

    t.assert_equals(trouble, {
        kind = 'timeout',
        message = 'команда не ушла: Connection timed out',
        sent = false,
    })
    link.close({ io = { close = error } })
end

g.test_a_failure_of_tls_keeps_its_words = function()
    local conn = opened(function() end)
    local socket = conn.socket

    ---@diagnostic disable-next-line: missing-fields
    conn.io = {
        write = function()
            return false, 'запись TLS не удалась'
        end,
    }

    local _, trouble = link.exchange(conn, helper.document('ping', 1, '$db', 'shop'), within.deadline(1), 1000)

    t.assert_equals(trouble, {
        kind = 'broken',
        message = 'команда не ушла: запись TLS не удалась',
        sent = false,
        retriable = true,
    })

    ---@diagnostic disable-next-line: missing-fields
    conn.io = {
        write = function(_, data, timeout)
            return socket:write(data, timeout)
        end,
        read = function()
            return nil, 'чтение TLS не удалось'
        end,
    }

    _, trouble = link.exchange(conn, helper.document('ping', 1, '$db', 'shop'), within.deadline(1), 1000)
    t.assert_equals(
        trouble,
        { kind = 'broken', message = 'соединение оборвалось: чтение TLS не удалось' }
    )
    socket:close()
end

g.test_a_read_that_raises_is_broken_with_its_words = function()
    local conn = opened(function() end)
    local socket = conn.socket

    ---@diagnostic disable-next-line: missing-fields
    conn.io = {
        write = function(_, data, timeout)
            return socket:write(data, timeout)
        end,
        read = function()
            error('сокет закрыт соседом', 0)
        end,
    }

    local _, trouble = link.exchange(conn, helper.document('ping', 1, '$db', 'shop'), within.deadline(1), 1000)

    t.assert_equals(trouble, {
        kind = 'broken',
        message = 'соединение оборвалось: сокет закрыт соседом',
    })
    socket:close()
end

g.test_a_plain_read_failure_asks_the_socket = function()
    local conn = opened(function() end)
    local socket = conn.socket

    ---@diagnostic disable-next-line: missing-fields
    conn.io = {
        write = function(_, data, timeout)
            return socket:write(data, timeout)
        end,
        read = function()
            return nil
        end,
        error = function()
            return 'Connection reset by peer'
        end,
    }

    local _, trouble = link.exchange(conn, helper.document('ping', 1, '$db', 'shop'), within.deadline(1), 1000)

    t.assert_equals(
        trouble,
        { kind = 'broken', message = 'соединение оборвалось: Connection reset by peer' }
    )
    socket:close()
end

g.test_alive_sees_a_server_that_closed_or_spoke = function()
    local conn, fake = opened(function() end)

    t.assert_equals(link.alive(conn), true)

    fake.peers[1]:write('x')
    t.helpers.retrying({ timeout = 1 }, function()
        t.assert_equals(link.alive(conn), false)
    end)
    link.close(conn)
    fake.stop()

    conn, fake = opened(function() end)
    fake.peers[1]:close()
    t.helpers.retrying({ timeout = 1 }, function()
        t.assert_equals(link.alive(conn), false)
    end)
    link.close(conn)
end

g.test_a_cancelled_open_is_broken_and_closed = function()
    local fake = serve(function()
        return { delay = 10 }
    end)
    local result = {}
    local worker = fiber.new(function()
        result = { link.open(settings(fake), 5) }
    end)

    worker:set_joinable(true)
    t.helpers.retrying({ timeout = 1 }, function()
        t.assert_equals(fake.connections, 1)
    end)
    worker:cancel()
    worker:join()
    t.assert_equals(result[1], nil)
    t.assert_equals(result[2].kind, 'unreachable')
end
