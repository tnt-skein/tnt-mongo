--- Проверки транзакции: сеанс и номер у каждой команды, фиксация
--- и отмена, пометка первым отказом, исключение тела, выброс соединения,
--- повтор конфликта и ошибки программиста.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.mongo.transaction')

--- Драйвер и двойник этой проверки: закрываются после неё.
---@type { client: any, fake: TntMongoFake|nil }
local current = {}

g.after_each(function()
    helper.restore()

    if current.client then
        current.client:close()
    end

    if current.fake then
        current.fake.stop()
    end

    current = {}
end)

--- Двойник, который ведёт записи, и драйвер набора реплик к нему.
---@param respond (fun(command: table, number: integer): any)|nil Ответ на команду поверх обычного
---@param opts table|nil Настройки драйвера
---@return any client
---@return TntMongoFake fake
local function connect(respond, opts)
    local given = table.deepcopy(opts or {})

    given.replica_set = 'rs0'
    local fake = helper.serve(function(command, number)
        local answer = respond and respond(command, number)

        if answer ~= nil then
            return answer
        end

        if command.hello == nil and command.saslStart == nil and command.saslContinue == nil then
            return { ok = 1, n = 1 }
        end
    end, { set_name = 'rs0' })
    local client = helper.client(fake, given)

    current = { client = client, fake = fake }

    return client, fake
end

--- Имена команд, что дошли до двойника, по порядку.
---@param fake TntMongoFake
---@return string[]
local function names(fake)
    local found = {}

    for _, command in ipairs(helper.sent(fake)) do
        for _, name in ipairs({ 'insert', 'find', 'getMore', 'commitTransaction', 'abortTransaction', 'ping' }) do
            if command[name] ~= nil then
                table.insert(found, name)
            end
        end
    end

    return found
end

g.test_a_body_without_return_commits_and_every_command_carries_the_session = function()
    local client, fake = connect()
    local done, err = client:transaction(function(tx)
        t.assert_equals(tx:command({ 'insert', 'users', documents = { { _id = 1 } } }).n, 1)
        t.assert_equals(tx:command({ 'insert', 'logs', documents = { {} } }, { db = 'audit' }).n, 1)
    end)

    t.assert_equals({ done, err }, { true, nil })
    t.assert_equals(names(fake), { 'insert', 'insert', 'commitTransaction' })

    local sent = helper.sent(fake)
    local session = sent[1].lsid.id

    t.assert_equals(sent[1].startTransaction, true)
    t.assert_equals(sent[1].autocommit, false)
    t.assert_equals(sent[1].txnNumber, 1)
    t.assert_equals(sent[1]['$db'], 'shop')
    t.assert_equals(sent[2].startTransaction, nil)
    t.assert_equals(sent[2]['$db'], 'audit')
    t.assert_equals(sent[2].lsid.id, session)
    t.assert_equals(sent[3].commitTransaction, 1)
    t.assert_equals(sent[3]['$db'], 'admin')
    t.assert_equals({ sent[3].txnNumber, sent[3].autocommit, sent[3].startTransaction }, { 1, false, nil })
    t.assert_equals(sent[3].lsid.id, session)
    t.assert_equals(client:stats().idle, 1)
end

g.test_the_transaction_number_grows_in_the_session = function()
    local client, fake = connect()

    for _ = 1, 2 do
        client:transaction(function(tx)
            tx:command({ 'insert', 'users', documents = { {} } })
        end)
    end

    local sent = helper.sent(fake)

    t.assert_equals({ sent[1].txnNumber, sent[3].txnNumber }, { 1, 2 })
    t.assert_equals(sent[1].lsid.id, sent[3].lsid.id)
    t.assert_equals(fake.connections, 1)
end

g.test_a_value_of_the_body_is_returned_after_commit = function()
    local client = connect()
    local result = {
        client:transaction(function(tx)
            tx:command({ 'insert', 'users', documents = { {} } })

            return 'готово', 'лишнее'
        end),
    }

    t.assert_equals(result, { 'готово' })
end

g.test_a_body_that_did_nothing_commits_nothing = function()
    local client, fake = connect()

    t.assert_equals({ client:transaction(function() end) }, { true })
    t.assert_equals({ client:transaction(function()
        return 7
    end) }, { 7 })
    t.assert_equals(names(fake), {})
    t.assert_equals(client:stats().idle, 1)
end

g.test_nil_or_false_of_the_body_aborts = function()
    local client, fake = connect()
    local done, err = client:transaction(function(tx)
        tx:command({ 'insert', 'users', documents = { {} } })

        return nil, 'передумали'
    end)

    t.assert_equals({ done, err }, { nil, 'передумали' })
    t.assert_equals(names(fake), { 'insert', 'abortTransaction' })
    t.assert_equals(helper.sent(fake)[2]['$db'], 'admin')

    local _, refusal = client:transaction(function(tx)
        tx:command({ 'insert', 'users', documents = { {} } })

        return false
    end)

    t.assert_equals({ refusal.kind, refusal.message }, { 'rejected', 'тело отменило транзакцию' })

    local _, quiet = client:transaction(function()
        return false
    end)

    t.assert_equals(quiet.message, 'тело отменило транзакцию')
    t.assert_equals(names(fake), { 'insert', 'abortTransaction', 'insert', 'abortTransaction' })
end

g.test_the_first_refusal_marks_the_transaction = function()
    local client, fake = connect(function(command)
        if command.insert == 'users' then
            return { ok = 1, n = 0, writeErrors = { { index = 0, code = 11000, errmsg = 'dup' } } }
        end
    end)
    local seen = {}
    local done, err = client:transaction(function(tx)
        local _, first = tx:command({ 'insert', 'users', documents = { {} } })
        local _, second = tx:command({ 'insert', 'logs', documents = { {} } })

        seen = { first, second }

        return true
    end)

    t.assert_equals(done, nil)
    t.assert_equals({ err.kind, err.retriable, err.server_code }, { 'rejected', false, 11000 })
    t.assert(rawequal(seen[1], seen[2]))
    t.assert(rawequal(seen[1], err))
    t.assert_equals(names(fake), { 'insert', 'abortTransaction' })
end

g.test_a_conflict_is_not_repeated_inside_and_is_final = function()
    local client = connect(function(command)
        if command.insert ~= nil then
            return {
                ok = 0,
                code = 112,
                codeName = 'WriteConflict',
                errmsg = 'Write conflict',
                errorLabels = { 'TransientTransactionError' },
            }
        end
    end)
    local _, err = client:transaction(function(tx)
        local _, refused = tx:command({ 'insert', 'users', documents = { {} } })

        return nil, refused
    end)

    t.assert_equals({ err.kind, err.retriable }, { 'conflict', false })
end

g.test_a_silent_command_dooms_the_connection_without_abort = function()
    local client, fake = connect(function(command)
        if command.insert ~= nil then
            return { delay = 5 }
        end
    end)
    local done, err = client:transaction(function(tx)
        local _, refused = tx:command({ 'insert', 'users', documents = { {} } })

        t.assert_equals(refused.kind, 'timeout')

        return true
    end, { timeout = 0.2 })

    t.assert_equals({ done, err.kind }, { nil, 'timeout' })
    t.assert_equals(names(fake), { 'insert' })
    t.assert_equals(client:stats().drops, 1)
end

g.test_a_broken_reply_dooms_the_connection_without_abort = function()
    local client, fake = connect(function(command)
        if command.insert ~= nil then
            -- Кадр цел и дочитан, а BSON в нём противоречит себе: поломка
            -- протокола. Двойник жив и ответил бы на отмену — её и не
            -- должно быть. Номер 2 — вслед за `hello`.
            return { raw = helper.frame(2, '\5\0\0\0\0\1') }
        end
    end)
    local done, err = client:transaction(function(tx)
        tx:command({ 'insert', 'users', documents = { {} } })
    end)

    t.assert_equals({ done, err.kind }, { nil, 'broken' })
    t.assert_equals(names(fake), { 'insert' })
    t.assert_equals(client:stats().drops, 1)
end

g.test_a_query_inside_is_bounded_by_the_client_or_its_own_limit = function()
    local client = connect(function(command)
        if command.find ~= nil then
            return { ok = 1, cursor = { id = 0, ns = 'shop.users', firstBatch = { { n = 1 }, { n = 2 } } } }
        end
    end, { max_rows = 1 })
    local done, err = client:transaction(function(tx)
        tx:query({ 'find', 'users' })
    end)

    t.assert_equals(
        { done, err.kind, err.message },
        { nil, 'overflow', 'документов больше max_rows 1' }
    )

    local rows

    done, err = client:transaction(function(tx)
        rows = tx:query({ 'find', 'users' }, { max_rows = 2 })
    end)

    t.assert_equals({ done, err, rows }, { true, nil, { { n = 1 }, { n = 2 } } })
end

g.test_a_query_inside_reads_the_cursor_with_the_session = function()
    local client, fake = connect(function(command)
        if command.find ~= nil then
            return { ok = 1, cursor = { id = 5, ns = 'shop.users', firstBatch = { { n = 1 } } } }
        end

        if command.getMore ~= nil then
            return { ok = 1, cursor = { id = 0, ns = 'shop.users', nextBatch = { { n = 2 } } } }
        end
    end)
    local rows

    client:transaction(function(tx)
        rows = tx:query({ 'find', 'users' }, { max_rows = 5 })
    end)

    t.assert_equals(rows, { { n = 1 }, { n = 2 } })

    local sent = helper.sent(fake)

    t.assert_equals(names(fake), { 'find', 'getMore', 'commitTransaction' })
    t.assert_equals({ sent[2].txnNumber, sent[2].autocommit }, { 1, false })
    t.assert_equals(sent[2].startTransaction, nil)
end

g.test_an_exception_in_the_body_aborts_drops_and_goes_on = function()
    local client, fake = connect()
    local raised = {
        pcall(client.transaction, client, function(tx)
            tx:command({ 'insert', 'users', documents = { {} } })
            error({ code = 'сломалось' })
        end),
    }

    t.assert_equals(raised, { false, { code = 'сломалось' } })
    t.assert_equals(names(fake), { 'insert', 'abortTransaction' })
    t.assert_equals(client:stats().drops, 1)

    local plain = { pcall(client.transaction, client, function()
        error('без команд', 0)
    end) }

    t.assert_equals(plain, { false, 'без команд' })
    t.assert_equals(names(fake), { 'insert', 'abortTransaction' })
    t.assert_equals(client:stats().drops, 2)
end

g.test_an_exception_after_a_doomed_command_sends_no_abort = function()
    local client, fake = connect(function(command)
        if command.insert ~= nil then
            return { delay = 5 }
        end
    end)
    local ok = pcall(client.transaction, client, function(tx)
        tx:command({ 'insert', 'users', documents = { {} } })
        error('после срока')
    end, { timeout = 0.2 })

    t.assert_equals(ok, false)
    t.assert_equals(names(fake), { 'insert' })
    t.assert_equals(client:stats().drops, 1)
end

g.test_a_refused_commit_is_a_pair = function()
    local client = connect(function(command)
        if command.commitTransaction ~= nil then
            return {
                ok = 0,
                code = 251,
                codeName = 'NoSuchTransaction',
                errmsg = 'Transaction has been aborted',
                errorLabels = { 'TransientTransactionError' },
            }
        end
    end)
    local done, err = client:transaction(function(tx)
        tx:command({ 'insert', 'users', documents = { {} } })
    end)

    t.assert_equals(done, nil)
    t.assert_equals({ err.kind, err.message }, { 'conflict', 'Transaction has been aborted' })
    t.assert_equals(client:stats().idle, 1)
end

g.test_an_abort_that_breaks_drops_the_connection = function()
    local client = connect(function(command)
        if command.abortTransaction ~= nil then
            return { close = true }
        end
    end)
    local _, err = client:transaction(function(tx)
        tx:command({ 'insert', 'users', documents = { {} } })

        return nil, 'передумали'
    end)

    t.assert_equals(err, 'передумали')
    t.assert_equals(client:stats().drops, 1)
end

g.test_retry_repeats_the_whole_transaction_after_a_conflict = function()
    local commits = 0
    local client, fake = connect(function(command)
        if command.commitTransaction ~= nil then
            commits = commits + 1

            if commits == 1 then
                return { ok = 0, code = 112, codeName = 'WriteConflict', errmsg = 'Write conflict' }
            end
        end
    end)
    local runs = 0
    local done = client:transaction(function(tx)
        runs = runs + 1
        tx:command({ 'insert', 'users', documents = { {} } })

        return runs
    end, { retry = true })

    t.assert_equals(done, 2)
    t.assert_equals(names(fake), { 'insert', 'commitTransaction', 'insert', 'commitTransaction' })

    local sent = helper.sent(fake)

    t.assert_equals({ sent[1].txnNumber, sent[3].txnNumber }, { 1, 2 })
end

g.test_retry_does_not_repeat_other_refusals_or_hide_exceptions = function()
    local client, fake = connect(function(command)
        if command.insert ~= nil then
            return { ok = 0, code = 2, errmsg = 'bad' }
        end
    end)
    local runs = 0
    local _, err = client:transaction(function(tx)
        runs = runs + 1

        local _, refused = tx:command({ 'insert', 'users', documents = { {} } })

        return nil, refused
    end, { retry = true })

    t.assert_equals({ runs, err.message }, { 1, 'bad' })

    local raised = {
        pcall(client.transaction, client, function()
            error({ code = 'нарочно' })
        end, { retry = true }),
    }

    t.assert_equals(raised, { false, { code = 'нарочно' } })
    t.assert_equals(names(fake), { 'insert', 'abortTransaction' })
end

g.test_a_closed_driver_refuses_the_transaction = function()
    local client = connect()

    client:close()

    local done, err = client:transaction(function() end)

    t.assert_equals({ done, err.kind }, { nil, 'closed' })
end

g.test_programmer_errors_are_raised_at_the_caller = function()
    local client = connect()
    ---@type any
    local kept

    client:transaction(function(tx)
        kept = tx
    end)

    helper.transaction._set_source({
        box_txn = function()
            return true
        end,
    })
    helper.assert_blamed({
        {
            function()
                client:transaction(function() end)
            end,
            'transaction внутри транзакции box: ожидание сети оборвёт её',
        },
    })
    helper.restore()

    helper.assert_blamed({
        {
            function()
                client:transaction('нет')
            end,
            'тело транзакции — функция или вызываемая таблица, а не строка',
        },
        {
            function()
                client:transaction(function() end, { retries = 1 })
            end,
            'настройки транзакции: ключа «retries» нет, есть retry, timeout',
        },
        {
            function()
                client:transaction(function() end, { timeout = 61 })
            end,
            'timeout 61 с длиннее потолка max_timeout 60 с',
        },
        {
            function()
                kept:command({ 'ping', 1 })
            end,
            'tx годен только внутри тела транзакции, а она уже закончена',
        },
    })

    -- Изнутри тела: место броска — строка тела, а не транзакции.
    client:transaction(function(tx)
        helper.assert_blamed({
            {
                function()
                    client:transaction(function() end)
                end,
                'transaction внутри transaction: вторая взяла бы второе соединение и ждала бы первого',
            },
            {
                function()
                    tx:command({ 'ping', 1 }, { timeout = 1 })
                end,
                'у команды транзакции нет своего срока и повтора: их задаёт transaction',
            },
            {
                function()
                    tx:query({ 'find', 'users' }, { idempotent = true })
                end,
                'у команды транзакции нет своего срока и повтора: их задаёт transaction',
            },
            {
                function()
                    tx:command({ 'ping', 1 }, { max_rows = 0 })
                end,
                'max_rows — число больше 0, а не 0',
            },
            {
                function()
                    tx:command({ 'ping', 1 }, { dbs = 'x' })
                end,
                'настройки команды транзакции: ключа «dbs» нет, есть db, max_rows',
            },
            {
                function()
                    tx:query({ 'count', 'users' })
                end,
                'query ходит с командами курсора, а не count',
            },
            {
                function()
                    tx:command({ 'ping' })
                end,
                'у команды ping нет значения: { "ping", коллекция либо 1, … }',
            },
        })
    end)
end

g.test_a_nested_transaction_is_raised = function()
    local client = connect()
    local message

    client:transaction(function()
        message = select(2, pcall(client.transaction, client, function() end))
    end)

    t.assert_str_contains(
        message,
        'transaction внутри transaction: вторая взяла бы второе соединение и ждала бы первого'
    )
end
