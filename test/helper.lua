--- Общие средства проверок драйвера MongoDB.
---
--- Двойник сервера — настоящий сокет `tcp_server` на петле, говорящий
--- OP_MSG и BSON и входящий по SCRAM-SHA-256 сам, по паролю из своего
--- списка: сроки, обрыв посреди ответа, закрытое в простое соединение
--- и отмена файбера держатся на ядре, и подделка сокета доказала бы
--- только, что мы правильно разговариваем сами с собой. Поведение
--- настоящего MongoDB проверяет `mongo_live_test.lua`.
---
--- Исходники читаются с диска, а не через `require`: у Tarantool свой
--- загрузчик `.rocks`, он идёт раньше `package.path` и подсунул бы
--- установленную копию пакета, если она есть. Проверки тогда шли бы
--- против вчерашнего кода, а покрытие считалось бы по нему. Зависимости
--- пакета — `tnt.must`, `tnt.hash`, `tnt.log`, `tnt.pool`, `tnt.retry`,
--- `tnt.external`, `tnt.storage`, `tnt.tls` — берутся из `.rocks` обычным
--- `require`: проверяется этот пакет, а не они.
---
--- Оснастка в `test/testing/` — загрузчик исходников, ловушка журнала,
--- запись файлов и временный узел — грузится так же, файлами, и один раз
--- на процесс: второй экземпляр загрузчика не знал бы, что вытеснил
--- первый, и не вернул бы вытесненное на место.
---
--- Проверки берут всё через этот помощник, а не из оснастки напрямую:
--- помощник — единственное, чем файл проверок отличается от того же файла
--- в наборе, где пакет живёт рядом со своими зависимостями.

local bit = require('bit')
local crypto = require('crypto') --[[@as any]]
local digest = require('digest')
local ffi = require('ffi')
local fiber = require('fiber')
local fio = require('fio')
local socket = require('socket')
local t = require('luatest')
local varbinary = require('varbinary')

--- Модули оснастки в порядке зависимостей: узел берёт файлы и загрузчик,
--- ловушка журнала — загрузчик.
local TESTING = {
    { name = 'tnt.testing.sources', path = 'test/testing/sources.lua' },
    { name = 'tnt.testing.files', path = 'test/testing/files.lua' },
    { name = 'tnt.testing.journal', path = 'test/testing/journal.lua' },
    { name = 'tnt.testing.node', path = 'test/testing/node.lua' },
}

for _, module in ipairs(TESTING) do
    if package.loaded[module.name] == nil then
        local chunk, failure = loadfile(fio.abspath(module.path))

        if chunk == nil then
            error(('оснастка %s не читается: %s'):format(module.name, tostring(failure)))
        end

        package.loaded[module.name] = chunk()
    end
end

--- Оснастка проверок под теми именами, что зовёт помощник.
local testing = {
    load_sources = package.loaded['tnt.testing.sources'].load,
    module = package.loaded['tnt.testing.sources'].module,
    capture_log = package.loaded['tnt.testing.journal'].capture,
    start_node = package.loaded['tnt.testing.node'].start,
    stop_node = package.loaded['tnt.testing.node'].stop,
}

local helper = {
    --- Модули пакета в порядке зависимостей.
    MODULES = {
        { name = 'tnt.mongo.types', path = 'tnt/mongo/types.lua' },
        { name = 'tnt.mongo.decimal128', path = 'tnt/mongo/decimal128.lua' },
        { name = 'tnt.mongo.bson.encode', path = 'tnt/mongo/bson/encode.lua' },
        { name = 'tnt.mongo.bson.decode', path = 'tnt/mongo/bson/decode.lua' },
        { name = 'tnt.mongo.wire', path = 'tnt/mongo/wire.lua' },
        { name = 'tnt.mongo.scram', path = 'tnt/mongo/scram.lua' },
        { name = 'tnt.mongo.request', path = 'tnt/mongo/request.lua' },
        { name = 'tnt.mongo.link', path = 'tnt/mongo/link.lua' },
        { name = 'tnt.mongo.operation', path = 'tnt/mongo/operation.lua' },
        { name = 'tnt.mongo.settings', path = 'tnt/mongo/settings.lua' },
        { name = 'tnt.mongo.transaction', path = 'tnt/mongo/transaction.lua' },
        { name = 'tnt.mongo', path = 'tnt/mongo.lua' },
    },
}

--- Значение мимо проверки типов: негодный аргумент нарочно.
---@param value any
---@return any
function helper.wrong(value)
    return value
end

--- Сверяет, что каждый вызов бросает названный отказ и винит строку
--- вызова в файле проверок, а не внутри пакета.
---
--- Вызов стоит в замыкании первой строкой тела, то есть строкой ниже
--- слова `function`: место броска сверяется с ней целиком — файлом,
--- строкой и текстом.
---@param cases table[] Пары: замыкание с вызовом и текст броска
function helper.assert_blamed(cases)
    for _, case in ipairs(cases) do
        local _, err = pcall(case[1])
        local info = debug.getinfo(case[1], 'S') --[[@as { short_src: string, linedefined: integer }]]

        t.assert_equals(err, ('%s:%d: %s'):format(info.short_src, info.linedefined + 1, case[2]))
    end
end

--- Фасад пакета из исходников.
helper.mongo = testing.load_sources(helper.MODULES, 'tnt.mongo')

-- Части пакета берутся из той же загрузки, что и фасад: взятые `require`,
-- они пришли бы установленной копией из `.rocks`. Срок, отказ и общее
-- для драйверов — зависимость, и они те же, что зовёт пакет.
helper.types = testing.module('tnt.mongo.types')
helper.decimal128 = testing.module('tnt.mongo.decimal128')
helper.encode = testing.module('tnt.mongo.bson.encode')
helper.decode = testing.module('tnt.mongo.bson.decode')
helper.wire = testing.module('tnt.mongo.wire')
helper.scram = testing.module('tnt.mongo.scram')
helper.request = testing.module('tnt.mongo.request')
helper.link = testing.module('tnt.mongo.link')
helper.operation = testing.module('tnt.mongo.operation')
helper.settings = testing.module('tnt.mongo.settings')
helper.transaction = testing.module('tnt.mongo.transaction')
helper.within = require('tnt.storage.within')
helper.failure = require('tnt.storage.failure')
helper.storage = require('tnt.storage')

--- Части с внешними зависимостями: проверки подменяют их средства и возвращают назад.
local SEAMED = { 'within', 'link', 'scram', 'types', 'transaction' }

--- Возвращает пакету настоящие часы, сеть, случайное и транзакцию box.
function helper.restore()
    for _, part in ipairs(SEAMED) do
        helper[part]._set_source(nil)
    end
end

--- Ловушка журнала на время проверки: выброс соединения виден только
--- записью.
helper.capture_log = testing.capture_log

--- Временный узел с исходниками пакета: транзакция box бывает только
--- на нём, в процессе проверок `box` не настроен. Остановить узел
--- проверка обязана сама.
---@return table server
function helper.start_node()
    local server = testing.start_node({ modules = helper.MODULES })

    return server
end

--- Останавливает узел и убирает его каталог.
helper.stop_node = testing.stop_node

--- Чтение окружения для настроек живых проверок: порт и каталог
--- сертификатов стенда.
---
--- `tnt-env` приходит из `.rocks`: сам пакет окружения не читает,
--- и его зависимостью он не объявлен — его ставит `make deps`.
---@return table
function helper.stand_env()
    return require('tnt.env')
end

--- Документ BSON байтами: порядок полей — как дан.
---@param ... any Имя, значение, имя, значение…
---@return string
function helper.document(...)
    return helper.encode.encode(helper.types.ordered(...), 1)
end

--- Сообщение ответа OP_MSG на запрос с тела.
---@param request_id integer
---@param body string Тело BSON
---@param flags integer|nil
---@return string
function helper.frame(request_id, body, flags)
    local header = ffi.new('int32_t[5]', { 21 + #body, 7, request_id, 2013, flags or 0 })

    return ffi.string(header, 20) .. '\0' .. body
end

--- Соль и число проходов двойника: нулевой байт в соли — нарочно,
--- `digest.pbkdf2` обрезал бы её.
local SALT = 'sa\0lt-of-the-fake'
local ITERATIONS = 4096

--- «Исключающее или» двух строк одной длины.
---@param left string
---@param right string
---@return string
local function xor(left, right)
    local out = ffi.new('uint8_t[?]', #left) --[[@as any]]

    for index = 0, #left - 1 do
        out[index] = bit.bxor(left:byte(index + 1), right:byte(index + 1))
    end

    return ffi.string(out, #left)
end

--- Сервер SCRAM-SHA-256 двойника: сверяет доказательство и подписывается.
---@param users table<string, string> Пароли по именам
---@param old boolean|nil Сервер без `skipEmptyExchange`: просит пустой третий шаг
---@return fun(command: table, state: table): table
local function scram_server(users, old)
    local hmac = crypto.hmac.sha256

    return function(command, state)
        local payload = tostring(command.payload)

        if command.saslStart ~= nil then
            local name, nonce = payload:match('^n,,n=([^,]*),r=(.*)$')

            state.skip = not old and command.options.skipEmptyExchange
            state.bare = payload:sub(4)
            state.name = (name --[[@as string]]):gsub('=2C', ','):gsub('=3D', '=')
            state.first = ('r=%sfake-nonce,s=%s,i=%d'):format(nonce, digest.base64_encode(SALT), ITERATIONS)

            return { ok = 1, conversationId = 1, done = false, payload = varbinary.new(state.first) }
        end

        if state.verified then
            return { ok = 1, conversationId = 1, done = true, payload = varbinary.new('') }
        end

        local without, proof = payload:match('^(c=biws,r=[^,]*),p=(.*)$')
        local password = users[state.name]

        if password == nil then
            return { ok = 0, code = 18, codeName = 'AuthenticationFailed', errmsg = 'Authentication failed.' }
        end

        local salted = helper.scram.pbkdf2(password, SALT, ITERATIONS)
        local client_key = hmac(salted, 'Client Key')
        local message = state.bare .. ',' .. state.first .. ',' .. without
        local expected = xor(client_key, hmac(digest.sha256(client_key), message))

        if
            digest.base64_decode(proof --[[@as string]]) ~= expected
        then
            return { ok = 0, code = 18, codeName = 'AuthenticationFailed', errmsg = 'Authentication failed.' }
        end

        state.verified = true

        local signature = hmac(hmac(salted, 'Server Key'), message)

        return {
            ok = 1,
            conversationId = 1,
            done = state.skip,
            payload = varbinary.new('v=' .. digest.base64_encode(signature)),
        }
    end
end

---@class TntMongoFakeAnswer
---@field reply table|nil Ответ документом
---@field raw string|nil Ответ байтами как есть, с рамкой
---@field delay number|nil Сколько помолчать перед ответом
---@field close boolean|nil Закрыть ли соединение после ответа

---@class TntMongoFake
---@field port integer Порт на петле
---@field commands any Команды, которые дошли, по порядку
---@field connections integer Сколько соединений открыто всего
---@field finished integer Сколько соединений кончилось
---@field peers any Сокеты двойника по соединениям
---@field stop fun() Погасить сервер и закрыть соединения

--- Читает запрос: номер и документ.
---@param peer any
---@return integer|nil id
---@return table|nil command
local function request_of(peer)
    local head = peer:read({ chunk = 16 })

    if head == nil or #head < 16 then
        return nil
    end

    local numbers = ffi.new('int32_t[4]') --[[@as any]]

    ffi.copy(numbers, head, 16)

    local rest = peer:read({ chunk = numbers[0] - 16 })

    return numbers[1], helper.decode.decode(rest:sub(6))
end

--- Команды входа: их двойник отвечает сам.
local LOGIN = { hello = true, saslStart = true, saslContinue = true }

--- Команда ли входа.
---@param command table
---@return boolean
local function login_of(command)
    for name in pairs(LOGIN) do
        if command[name] ~= nil then
            return true
        end
    end

    return false
end

--- Двойник сервера MongoDB.
---
--- `respond(command, number)` получает команду документом и номер
--- соединения и отвечает документом либо таблицей `{ reply, raw, delay,
--- close }`; пустой ответ — молчание. `hello` и вход по SCRAM отвечают
--- сами, пока `respond` не ответит на них иначе: `hello` — ведущим узлом
--- набора `opts.set_name`, вход — по паролям `opts.users`.
---@param respond fun(command: table, number: integer): any
---@param opts { set_name: string|nil, users: table<string, string>|nil, old: boolean|nil }|nil
---@return TntMongoFake
function helper.serve(respond, opts)
    local given = opts or {}
    local login = scram_server(given.users or {}, given.old)
    ---@diagnostic disable-next-line: missing-fields
    local fake = { commands = {}, connections = 0, finished = 0, peers = {} } ---@type TntMongoFake

    --- Ответ двойника: что прислал `respond`, а без него — вход сам.
    ---@param command table
    ---@param number integer
    ---@param state table Разговор SCRAM этого соединения
    ---@return table
    local function answer_of(command, number, state)
        local answer = respond(command, number)

        if answer == nil and command.hello ~= nil then
            answer = { ok = 1, isWritablePrimary = true, setName = given.set_name, maxWireVersion = 21 }
        elseif answer == nil and login_of(command) then
            answer = login(command, state)
        end

        -- Документ — это ответ; таблица с полями двойника — указание.
        local plain = answer ~= nil
            and answer.reply == nil
            and answer.raw == nil
            and answer.delay == nil
            and not answer.close

        return plain and { reply = answer } or answer or {}
    end

    local server = socket.tcp_server('127.0.0.1', 0, function(peer)
        fake.connections = fake.connections + 1
        table.insert(fake.peers, peer)

        local number, state = fake.connections, {}
        local talking

        repeat
            local read, id, request = pcall(request_of, peer)

            talking = read and id ~= nil

            if talking then
                local command = request --[[@as table]]

                table.insert(fake.commands, command)

                local answer = answer_of(command, number, state)

                fiber.sleep(answer.delay or 0)

                local number_of = id --[[@as integer]]
                ---@type string|nil
                local bytes = answer.raw
                    or answer.reply and helper.frame(number_of, helper.encode.encode(answer.reply, 1))

                if bytes ~= nil then
                    pcall(peer.write, peer, bytes)
                end

                talking = not answer.close
            end
        until not talking

        pcall(peer.close, peer)
        fake.finished = fake.finished + 1
    end)

    fake.port = server:name().port --[[@as integer]]
    fake.stop = function()
        pcall(server.close, server)

        for index = #fake.peers, 1, -1 do
            pcall(fake.peers[index].close, fake.peers[index])
        end
    end

    return fake
end

--- Команды двойника без входа: то, что прислал вызывающий.
---@param fake TntMongoFake
---@return any
function helper.sent(fake)
    local found = {}

    for index = 1, #fake.commands do
        if not login_of(fake.commands[index]) then
            found[#found + 1] = fake.commands[index]
        end
    end

    return found
end

--- Драйвер к двойнику: без уборки пула и без пауз повторов.
---
--- Уборка заводила бы файбер на каждый пул, пауза повтора — десятые доли
--- секунды на каждую проверку повторов. Пауза после отказа открытия —
--- сотые: без неё пул открывал бы к закрытому порту без передышки.
---@param fake TntMongoFake
---@param opts table|nil Настройки поверх
---@return any
function helper.client(fake, opts)
    local given = table.deepcopy(opts or {})
    local pool, retry = given.pool or {}, given.retry or {}

    pool.sweep_interval = pool.sweep_interval or 0
    pool.open_cooldown = pool.open_cooldown or 0.02
    retry.base = retry.base or 0
    given.port, given.pool, given.retry = fake.port, pool, retry
    given.db = given.db or 'shop'

    return helper.mongo.new(given)
end

--- Свободный порт на петле, на котором никто не слушает.
---@return integer
function helper.closed_port()
    local listener = socket.tcp_server('127.0.0.1', 0, function() end)
    local address = listener:name()

    listener:close()

    return address.port --[[@as integer]]
end

return helper
