--- Проверки одной операции: отказ сервера трёх видов, решение
--- о соединении, выборка курсором до конца и предел документов.

local ffi = require('ffi')
local t = require('luatest')

local helper = dofile('test/helper.lua')

local operation, link, within = helper.operation, helper.link, helper.within

local g = t.group('tnt.mongo.operation')

g.after_each(function()
    if g.conn ~= nil then
        link.close(g.conn)
        g.conn = nil
    end

    if g.fake ~= nil then
        g.fake.stop()
        g.fake = nil
    end
end)

--- Соединение к двойнику.
---@param respond fun(command: table, number: integer): any
---@return TntMongoLink
---@return TntMongoFake
local function connect(respond)
    g.fake = helper.serve(respond)
    g.conn = link.open(helper.settings.check({ db = 'shop', port = g.fake.port }), 1)

    return g.conn, g.fake
end

--- Вызов операции.
---@param opts table|nil Поверх
---@return TntMongoCall
local function call(opts)
    local given = {
        where = 'db:27017',
        db = 'shop',
        max_rows = 10,
        max_bytes = 10 ^ 6,
        session = {},
    }

    for key, value in pairs(opts or {}) do
        given[key] = value
    end

    return given
end

--- Тело команды.
---@param name string
---@param value any
---@return string
local function body(name, value)
    return helper.document(name, value, '$db', 'shop')
end

--- Род, приговор, код и причина отказа.
---@param err any
---@return table
local function shape(err)
    return {
        kind = err.kind,
        retriable = err.retriable,
        sent = err.sent,
        server_code = err.server_code,
        message = err.message,
        reason = err.reason,
    }
end

g.test_names_of_actions = function()
    t.assert_equals({ operation.GIVE, operation.DROP }, { 'give', 'drop' })
end

g.test_verdict_reads_three_kinds_of_refusal = function()
    t.assert_equals(operation.verdict({ ok = 1 }), nil)
    t.assert_equals(operation.verdict({ ok = 1, writeErrors = {} }), nil)
    t.assert_equals(operation.verdict({ ok = 1, writeErrors = 'x' }), nil)

    t.assert_equals(
        shape(operation.verdict({ ok = 0, code = 112, codeName = 'WriteConflict', errmsg = 'Write conflict' })),
        {
            kind = 'conflict',
            retriable = false,
            sent = true,
            server_code = 112,
            message = 'Write conflict',
            reason = 'сервер отказал: WriteConflict, код 112',
        }
    )
    t.assert_equals(
        shape(operation.verdict({
            ok = 1,
            writeErrors = { { index = 1, code = 11000, errmsg = 'E11000 duplicate key dup key: { _id: 7 }' } },
        })),
        {
            kind = 'rejected',
            retriable = false,
            sent = true,
            server_code = 11000,
            message = 'запись 1 отвергнута: E11000 duplicate key dup key: { _id: 7 }',
            reason = 'сервер отказал: без имени, код 11000',
        }
    )
    t.assert_equals(
        shape(operation.verdict({
            ok = 1,
            writeConcernError = {
                code = 64,
                codeName = 'WriteConcernFailed',
                errmsg = 'waiting for replication timed out',
            },
        }, true)),
        {
            kind = 'timeout',
            retriable = true,
            sent = true,
            server_code = 64,
            message = 'waiting for replication timed out',
            reason = 'сервер отказал: WriteConcernFailed, код 64',
        }
    )
    t.assert_equals(
        operation.verdict({
            ok = 0,
            code = 251,
            codeName = 'NoSuchTransaction',
            errmsg = 'x',
            errorLabels = { 'TransientTransactionError' },
        }).kind,
        'conflict'
    )
    t.assert_equals(operation.verdict({ ok = false, errmsg = 'x' }).kind, 'rejected')
    t.assert_equals(operation.verdict({ ok = 0 }).message, 'nil')
end

g.test_a_command_gives_back_its_connection = function()
    local conn = connect(function(command)
        if command.ping ~= nil then
            return { ok = 1, pong = true }
        end

        if command.insert ~= nil then
            return { ok = 0, code = 11000, errmsg = 'dup' }
        end

        if command.drop ~= nil then
            return { ok = 0, code = 10107, codeName = 'NotWritablePrimary', errmsg = 'not primary' }
        end
    end)
    local reply, err, action = operation.command(conn, body('ping', 1), within.deadline(1), call())

    t.assert_equals({ reply.pong, err, action }, { true, nil, 'give' })

    reply, err, action = operation.command(conn, body('insert', 'users'), within.deadline(1), call())
    t.assert_equals({ reply, err.kind, action }, { nil, 'rejected', 'give' })

    -- Узел не ведущий: новое соединение может прийти уже к ведущему.
    reply, err, action = operation.command(conn, body('drop', 'users'), within.deadline(1), call())
    t.assert_equals({ reply, err.kind, err.retriable, action }, { nil, 'busy', true, 'drop' })
end

g.test_a_trouble_of_the_link_names_the_server = function()
    local conn = connect(function(command)
        if command.ping == 1 then
            return { delay = 10 }
        end

        if command.ping == 2 then
            return { raw = helper.frame(3, '\14\0\0\0\13c\0\2\0\0\0x\0\0') }
        end
    end)
    local reply, err, action =
        operation.command(conn, body('ping', 1), within.deadline(0.1), call({ idempotent = true }))

    t.assert_equals(reply, nil)
    t.assert_equals(action, 'drop')
    t.assert_equals(shape(err), {
        kind = 'timeout',
        retriable = true,
        sent = true,
        message = 'mongo db:27017: ответа нет за срок вызова',
        reason = 'mongo db:27017: ответа нет за срок вызова',
    })

    link.close(conn)
    g.fake.stop()

    conn = connect(function(command)
        if command.ping ~= nil then
            return { raw = helper.frame(2, '\14\0\0\0\13c\0\2\0\0\0x\0\0') }
        end
    end)
    reply, err, action = operation.command(conn, body('ping', 2), within.deadline(1), call())
    t.assert_equals({ reply, err.kind, err.sent, action }, { nil, 'rejected', true, 'give' })
end

g.test_a_write_not_sent_keeps_its_verdict = function()
    local conn = connect(function() end)

    conn.socket:close()

    local _, err, action = operation.command(conn, body('ping', 1), within.deadline(1), call())

    t.assert_equals({ err.kind, err.sent, err.retriable, action }, { 'broken', false, true, 'drop' })
end

--- Ответ курсора.
---@param id any
---@param batch string firstBatch либо nextBatch
---@param documents table[]
---@return table
local function cursor(id, batch, documents)
    return { ok = 1, cursor = { id = id, ns = 'shop.users', [batch] = documents } }
end

g.test_a_query_reads_the_cursor_to_the_end = function()
    local id = 9007199254740993LL
    local _, fake = connect(function(command)
        if command.find ~= nil then
            return cursor(id, 'firstBatch', { { n = 1 }, { n = 2 } })
        end

        if command.getMore ~= nil and command.getMore == id then
            return cursor(5, 'nextBatch', { { n = 3 } })
        end

        if command.getMore ~= nil then
            return cursor(0, 'nextBatch', { { n = 4 } })
        end
    end)
    local rows, err, action = operation.query(g.conn, body('find', 'users'), within.deadline(1), call())

    t.assert_equals(err, nil)
    t.assert_equals(action, 'give')
    t.assert_equals(rows, { { n = 1 }, { n = 2 }, { n = 3 }, { n = 4 } })
    t.assert_equals(getmetatable(rows).__serialize, 'seq')

    local asked = helper.sent(fake)

    t.assert_equals(#asked, 3)
    t.assert_equals(asked[2].collection, 'users')
    t.assert_equals(asked[2]['$db'], 'shop')
    -- Номер курсора — всегда int64, даже когда он мал.
    t.assert_equals(tostring(asked[3].getMore), '5')
end

g.test_a_small_cursor_id_goes_as_int64 = function()
    local _, fake = connect(function(command)
        if command.find ~= nil then
            return cursor(5, 'firstBatch', {})
        end

        return cursor(0, 'nextBatch', {})
    end)

    operation.query(g.conn, body('find', 'users'), within.deadline(1), call())

    local raw = helper.encode.encode(helper.types.ordered('getMore', ffi.cast('int64_t', 5)), 1)

    t.assert_equals(raw:byte(5), 0x12)
    t.assert_equals(type(helper.sent(fake)[2].getMore), 'number')
end

g.test_an_empty_query_is_an_empty_array = function()
    connect(function(command)
        if command.find ~= nil then
            return cursor(0, 'firstBatch', {})
        end
    end)

    local rows = operation.query(g.conn, body('find', 'users'), within.deadline(1), call())

    t.assert_equals(rows, {})
    t.assert_equals(getmetatable(rows).__serialize, 'seq')
end

g.test_a_reply_without_a_cursor_is_rejected = function()
    local replies = {
        { ok = 1 },
        { ok = 1, cursor = 'x' },
        { ok = 1, cursor = { id = 0, ns = 'shop.users' } },
        { ok = 1, cursor = { ns = 'shop.users', firstBatch = {} } },
        { ok = 1, cursor = { id = 'x', ns = 'shop.users', firstBatch = {} } },
    }

    for _, reply in ipairs(replies) do
        connect(function(command)
            if command.find ~= nil then
                return reply
            end
        end)

        local rows, err, action = operation.query(g.conn, body('find', 'users'), within.deadline(1), call())

        t.assert_equals(rows, nil)
        t.assert_equals({ err.kind, err.message, action }, {
            'rejected',
            'ответ без курсора: команда не отдаёт документов',
            'give',
        })
        link.close(g.conn)
        g.fake.stop()
    end

    g.conn, g.fake = nil, nil
end

g.test_a_broken_next_batch_is_rejected = function()
    connect(function(command)
        if command.find ~= nil then
            return cursor(5, 'firstBatch', {})
        end

        return { ok = 1, cursor = { id = 0, ns = 'shop.users' } }
    end)

    local rows, err, action = operation.query(g.conn, body('find', 'users'), within.deadline(1), call())

    t.assert_equals({ rows, err.kind, err.message, action }, {
        nil,
        'rejected',
        'ответ getMore без пачки документов',
        'give',
    })
end

g.test_a_failed_first_or_next_batch_is_a_refusal = function()
    connect(function(command)
        if command.find ~= nil then
            return { ok = 0, code = 2, errmsg = 'bad filter' }
        end
    end)

    local rows, err, action = operation.query(g.conn, body('find', 'users'), within.deadline(1), call())

    t.assert_equals({ rows, err.message, action }, { nil, 'bad filter', 'give' })
    link.close(g.conn)
    g.fake.stop()

    connect(function(command)
        if command.find ~= nil then
            return cursor(5, 'firstBatch', {})
        end

        if command.getMore ~= nil then
            return { ok = 0, code = 43, codeName = 'CursorNotFound', errmsg = 'cursor id 5 not found' }
        end
    end)

    rows, err, action = operation.query(g.conn, body('find', 'users'), within.deadline(1), call())
    t.assert_equals({ rows, err.message, err.server_code, action }, { nil, 'cursor id 5 not found', 43, 'give' })
end

g.test_more_documents_than_the_limit_close_the_cursor = function()
    local _, fake = connect(function(command)
        if command.find ~= nil then
            return cursor(5, 'firstBatch', { {}, {} })
        end

        if command.getMore ~= nil then
            return cursor(5, 'nextBatch', { {} })
        end

        return { ok = 1, cursorsKilled = { 5 } }
    end)

    -- Ровно предел — не отказ, и курсор читается дальше.
    local rows, err, action = operation.query(g.conn, body('find', 'users'), within.deadline(1), call({ max_rows = 2 }))

    t.assert_equals({ rows, err.kind, err.message, err.retriable, action }, {
        nil,
        'overflow',
        'документов больше max_rows 2',
        false,
        'give',
    })

    local asked = helper.sent(fake)

    t.assert_equals(#asked, 3)
    t.assert_equals(asked[2].getMore, 5)
    t.assert_equals(asked[3].killCursors, 'users')
    t.assert_equals(asked[3].cursors, { 5 })
    t.assert_equals(asked[3]['$db'], 'shop')
end

g.test_more_documents_at_the_last_batch_need_no_kill = function()
    local _, fake = connect(function(command)
        if command.find ~= nil then
            return cursor(0, 'firstBatch', { {}, {}, {} })
        end
    end)
    local rows, err, action = operation.query(g.conn, body('find', 'users'), within.deadline(1), call({ max_rows = 2 }))

    t.assert_equals({ rows, err.kind, action }, { nil, 'overflow', 'give' })
    t.assert_equals(#helper.sent(fake), 1)

    local exact = operation.query(g.conn, body('find', 'users'), within.deadline(1), call({ max_rows = 3 }))

    t.assert_equals(#exact, 3)
end

g.test_a_kill_that_breaks_drops_the_connection = function()
    connect(function(command)
        if command.find ~= nil then
            return cursor(5, 'firstBatch', { {}, {} })
        end

        if command.killCursors ~= nil then
            return { close = true }
        end
    end)

    local _, err, action = operation.query(g.conn, body('find', 'users'), within.deadline(1), call({ max_rows = 1 }))

    t.assert_equals({ err.kind, action }, { 'overflow', 'drop' })
end

g.test_session_fields_go_to_every_batch = function()
    local _, fake = connect(function(command)
        if command.find ~= nil then
            return cursor(5, 'firstBatch', { {} })
        end

        if command.getMore ~= nil then
            return cursor(5, 'nextBatch', { {}, {} })
        end

        return { ok = 1 }
    end)
    local session = { { 'txnNumber', ffi.cast('int64_t', 3) }, { 'autocommit', false } }

    operation.query(g.conn, body('find', 'users'), within.deadline(1), call({ max_rows = 2, session = session }))

    local asked = helper.sent(fake)

    t.assert_equals({ asked[2].txnNumber, asked[2].autocommit }, { 3, false })
    t.assert_equals({ asked[3].txnNumber, asked[3].autocommit }, { 3, false })
end
