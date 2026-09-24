--- Проверки сборки команды: имя первым, поля, поля драйвера и база;
--- негодная команда — исключение на строке вызывающего.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local request = helper.request

local g = t.group('tnt.mongo.request')

--- Имена полей документа байтами по порядку.
---@param body string
---@return string[]
local function names(body)
    local found = {}
    local at = 5

    while at < #body do
        local stop = body:find('\0', at + 1, true) --[[@as integer]]

        table.insert(found, body:sub(at + 1, stop - 1))

        -- Значения проверок — короткие: пропускаем по типу.
        local kind = body:byte(at)

        if kind == 0x02 then
            local length = body:byte(stop + 1) + body:byte(stop + 2) * 256

            at = stop + 4 + length + 1
        elseif kind == 0x10 then
            at = stop + 4 + 1
        elseif kind == 0x08 then
            at = stop + 1 + 1
        else
            break
        end
    end

    return found
end

g.test_the_name_goes_first_and_the_database_last = function()
    local name, body = request.command({ 'count', 'users', skip = 1 }, 'shop', {}, 1)
    local document = helper.decode.decode(body)

    t.assert_equals(name, 'count')
    t.assert_equals(names(body), { 'count', 'skip', '$db' })
    t.assert_equals({ document.count, document.skip, document['$db'] }, { 'users', 1, 'shop' })
end

g.test_fields_of_the_driver_go_before_the_database = function()
    local _, body = request.command({ 'ping', 1 }, 'admin', { { 'autocommit', false }, { 'txnNumber', 7 } }, 1)

    t.assert_equals(names(body), { 'ping', 'autocommit', 'txnNumber', '$db' })
end

g.test_a_system_command_keeps_its_order = function()
    local body = request.system('admin', { { 'autocommit', false } }, 'commitTransaction', 1, 'x', 'y')

    t.assert_equals(names(body), { 'commitTransaction', 'x', 'autocommit', '$db' })
    t.assert_equals(helper.decode.decode(body)['$db'], 'admin')
end

g.test_cursor_commands_are_named = function()
    t.assert_equals(request.CURSORS, { find = true, aggregate = true, listCollections = true, listIndexes = true })
end

--- Бросок `command` на строке вызывающего.
---@param command any
---@param message string
local function refused(command, message)
    helper.assert_blamed({
        {
            function()
                request.command(command, 'shop', {}, 1)
            end,
            message,
        },
    })
end

g.test_a_wrong_command_is_an_error_of_the_caller = function()
    refused('ping', 'команда — таблица, а не строка')
    refused({}, 'имя команды — непустая строка, а не nil')
    refused({ '' }, 'имя команды — непустая строка, а не пустая')
    refused(
        { 'ping' },
        'у команды ping нет значения: { "ping", коллекция либо 1, … }'
    )
    refused({ 'ping', 1, 'extra' }, 'в команде ping лишнее без имени: [3]')
    refused({ 'ping', 1, [true] = 1 }, 'в команде ping лишнее без имени: [true]')
    refused(
        { 'find', 'users', filter = { v = print } },
        'значение function не уходит в BSON: документ — таблица, байты — binary'
    )
end

g.test_the_driver_keeps_its_own_commands_and_fields = function()
    local commands = {
        saslStart = 'вход задают настройки драйвера',
        saslContinue = 'вход задают настройки драйвера',
        authenticate = 'вход задают настройки драйвера',
        logout = 'соединение в пуле достанется другому без входа',
        commitTransaction = 'транзакцию ведёт transaction',
        abortTransaction = 'транзакцию ведёт transaction',
        endSessions = 'сеансы ведёт драйвер',
    }

    for name, why in pairs(commands) do
        refused({ name, 1 }, ('команду %s драйвер не отправит: %s'):format(name, why))
    end

    for _, field in ipairs({ '$db', 'lsid', 'txnNumber', 'autocommit', 'startTransaction' }) do
        refused(
            { 'find', 'users', [field] = 1 },
            ('поле %s ставит драйвер, а не команда'):format(field)
        )
    end
end

g.test_a_system_command_blames_the_caller_too = function()
    helper.assert_blamed({
        {
            function()
                request.system('admin', {}, 'ping', print)
            end,
            'значение function не уходит в BSON: документ — таблица, байты — binary',
        },
    })
end
