--- Связь с MongoDB: открыть и войти, обменяться командой, проверить,
--- закрыть.
---
--- Здесь всё, что ходит в сеть. Пул (`tnt-pool`) зовёт `open`, `alive`
--- и `close`, фасад — `exchange`. Срок у каждого ожидания — остаток одного
--- мига: `open` отмечает миг по остатку срока `take`, `exchange` получает
--- миг вызова. Встроенный сокет срок принимает сам, поэтому работник
--- в отдельном файбере не нужен: ожидание, не дождавшееся срока,
--- возвращает управление, и соединение выбрасывается — в нём остался
--- недочитанный ответ.
---
--- Вход: `hello` с описанием клиента (его видно в журнале сервера и в
--- `currentOp`), сверка имени набора реплик, если оно задано, затем
--- SCRAM-SHA-256 на базе учётной записи. Ответ на `hello` нужен и без
--- входа: сервер, которому некуда принять соединение, отвечает отказом
--- на первую команду, и лучше услышать это при входе.
---
--- У каждого соединения свой сеанс (`lsid`) и свой счёт транзакций:
--- сеанс MongoDB к соединению не привязан, но соединение в пуле выдаётся
--- одному взявшему за раз, и транзакции одного сеанса так не пересекаются.
---
--- Живость без сети: у открытого сокета — неблокирующий `sysread`.
--- Свободному соединению сервер не шлёт ничего, и если читать есть что —
--- конец потока после перезапуска сервера либо лишние байты, — соединение
--- негодно. Под TLS так нельзя — в сокете бывают служебные записи, — и
--- соединение, умершее в простое, узнаётся первым запросом.

local errno = require('errno')
local uuid = require('uuid')

local codes = require('tnt.storage.codes')
local decode = require('tnt.mongo.bson.decode')
local failure = require('tnt.storage.failure')
local request = require('tnt.mongo.request')
local scram = require('tnt.mongo.scram')
local external = require('tnt.external')
local value = require('tnt.storage.value')
local wire = require('tnt.mongo.wire')
local within = require('tnt.storage.within')

local Module = {}

--- Внешние средства: сеть и шифрование.
local source = external.install(Module, {
    connect = function(host, port, timeout)
        return require('socket').tcp_connect(host, port, timeout)
    end,
    tls = function()
        return require('tnt.tls')
    end,
})

--- Больше этого за одно чтение не просится: ответ в мегабайты читается
--- кусками и склеивается разом, а не наращиванием строки.
Module.PIECE = 64 * 1024

--- Номер запроса — целое со знаком в четыре байта: после предела счёт
--- идёт с единицы.
local MAX_ID = 2 ^ 31 - 1

--- Ответ ядра «читать пока нечего»: соединение свободно и цело.
local AGAIN = errno.EAGAIN

--- Команды входа идут без сеанса.
local NONE = {}

---@class TntMongoIo Сокет либо соединение TLS: чтение и запись со сроком
---@field read fun(self: TntMongoIo, opts: table, timeout: number): string|nil, string|nil
---@field write fun(self: TntMongoIo, data: string, timeout: number): any, string|nil
---@field close fun(self: TntMongoIo)
---@field error fun(self: TntMongoIo): string|nil

---@class TntMongoLink Соединение пула
---@field io TntMongoIo Чем читать и писать
---@field socket any Сам сокет: по нему судится живость
---@field secured boolean Идёт ли разговор под TLS
---@field next_id integer Номер следующего запроса
---@field session any UUID сеанса этого соединения
---@field transactions integer Сколько транзакций начато в сеансе

---@class TntMongoTlsSettings
---@field verify boolean|nil Проверять ли сертификат; выключается только словом false
---@field ca_file string|nil Файл доверенных корней
---@field ca_path string|nil Каталог доверенных корней
---@field sni string|nil Имя для SNI

---@class TntMongoLinkSettings
---@field name string Имя драйвера: его видит сервер в описании клиента
---@field host string Узел
---@field port integer Порт
---@field where string Узел и порт для текста отказа
---@field tls TntMongoTlsSettings|nil Шифрование; пусто — открытый текст
---@field username string|nil Учётная запись
---@field auth_source string База учётной записи
---@field salted (fun(salt: string, iterations: integer): string)|nil Растягивание пароля
---@field replica_set string|nil Имя набора реплик, которое узел обязан назвать
---@field max_bytes integer Предел байтов ответа

--- Род беды посреди обмена: остатка нет — срок, иначе обрыв.
---
--- Сокет и TLS называют истёкший срок каждый по-своему, а отказ сети —
--- словами ядра. Надёжнее спросить часы.
---@param deadline number
---@return string
local function kind_of(deadline)
    return within.left(deadline) <= 0 and failure.TIMEOUT or failure.BROKEN
end

--- Чтение ровно `size` байтов в остаток срока.
---@param io TntMongoIo
---@param deadline number
---@return fun(size: integer): string|nil, TntMongoTrouble|nil
local function receiver(io, deadline)
    return function(size)
        local parts, got = {}, 0

        while got < size do
            -- Под pcall: сокет, закрытый соседом, бросает, а не отвечает.
            local ok, piece, why =
                pcall(io.read, io, { chunk = math.min(size - got, Module.PIECE) }, within.left(deadline))

            if not (ok and piece ~= nil and piece ~= '') then
                local kind = kind_of(deadline)
                local reason = kind == failure.TIMEOUT and 'ответа нет за срок вызова'
                    or ('соединение оборвалось: %s'):format(
                        piece == '' and 'сервер закрыл его'
                            or tostring(ok and (why or io:error()) or piece)
                    )

                return nil, { kind = kind, message = reason }
            end

            parts[#parts + 1] = piece
            got = got + #piece
        end

        return table.concat(parts)
    end
end

--- Отправляет команду и читает ответ на неё.
---
--- Сообщение, записанное не целиком, сервер не выполняет: он ждёт его
--- длины. Поэтому обрыв на записи — без отправки и с повтором, а срок на
--- записи — без отправки и без повтора: повторять уже некогда.
---@param link TntMongoLink
---@param body string Тело команды в BSON
---@param deadline number Миг срока
---@param budget integer Предел байтов ответа
---@return table|nil reply
---@return TntMongoTrouble|nil trouble
function Module.exchange(link, body, deadline, budget)
    local id = link.next_id
    local io = link.io

    link.next_id = id % MAX_ID + 1

    local ok, written, why = pcall(io.write, io, wire.message(id, body), within.left(deadline))

    if not (ok and written) then
        local kind = kind_of(deadline)

        return nil,
            {
                kind = kind,
                message = ('команда не ушла: %s'):format(tostring(ok and (why or io:error()) or written)),
                sent = false,
                retriable = kind == failure.BROKEN or nil,
            }
    end

    local raw, trouble = wire.read(receiver(io, deadline), id, budget)

    if raw == nil then
        return nil, trouble
    end

    local reply, wrong, fatal = decode.decode(raw)

    if reply == nil then
        ---@type TntMongoTrouble
        local unread = {
            kind = fatal and failure.BROKEN or failure.REJECTED,
            message = wrong --[[@as string]],
            clean = not fatal,
        }

        return nil, unread
    end

    return reply
end

--- Живо ли свободное соединение — без сети и без уступки.
---
--- Под TLS в сокете бывают служебные записи протокола, и судить по нему
--- нечем: такое соединение живо, пока первый запрос не скажет иного.
---@param link TntMongoLink
---@return boolean
function Module.alive(link)
    if link.secured then
        return true
    end

    local sock = link.socket
    local read, extra = pcall(sock.sysread, sock)

    return read and extra == nil and sock:errno() == AGAIN
end

--- Закрывает соединение, чем бы оно ни кончилось.
---@param link TntMongoLink
function Module.close(link)
    local io = link.io

    pcall(io.close, io)
end

--- Отказ входа: закрывает соединение и отдаёт отказ.
---@param link TntMongoLink
---@param kind string
---@param text string
---@param code integer|nil
---@return nil
---@return TntStorageFailure
local function refuse(link, kind, text, code)
    Module.close(link)

    return nil, failure.new(kind, text, { server_code = code })
end

--- Команда входа: ответ либо отказ входа.
---@param link TntMongoLink
---@param settings TntMongoLinkSettings
---@param body string
---@param deadline number
---@return table|nil reply
---@return TntStorageFailure|nil err
local function ask(link, settings, body, deadline)
    local reply, trouble = Module.exchange(link, body, deadline, settings.max_bytes)
    local where = settings.where

    if reply == nil then
        ---@cast trouble TntMongoTrouble
        return refuse(
            link,
            failure.UNREACHABLE,
            ('mongo %s: вход не завершился: %s'):format(where, trouble.message)
        )
    end

    if reply.ok ~= 1 then
        local text = ('mongo %s: вход не удался: %s'):format(where, tostring(reply.errmsg))

        return refuse(link, codes.mongo_login(reply.code), text, reply.code)
    end

    return reply
end

--- SCRAM-SHA-256 на базе учётной записи.
---@param link TntMongoLink
---@param settings TntMongoLinkSettings
---@param deadline number
---@return TntMongoLink|nil link
---@return TntStorageFailure|nil err
local function authenticate(link, settings, deadline)
    local db = settings.auth_source
    local state, first = scram.first(settings.username --[[@as string]])
    local reply, err = ask(
        link,
        settings,
        request.system(
            db,
            NONE,
            'saslStart',
            1,
            'mechanism',
            scram.MECHANISM,
            'payload',
            value.binary(first),
            'options',
            { skipEmptyExchange = true }
        ),
        deadline
    )

    if reply == nil then
        return nil, err
    end

    local salted = settings.salted --[[@as fun(salt: string, iterations: integer): string]]
    local proof, wrong = scram.final(state, tostring(reply.payload), salted)
    local denied = ('mongo %s: вход не удался: %%s'):format(settings.where)

    if proof == nil then
        return refuse(link, failure.DENIED, denied:format(wrong))
    end

    local payload = proof
    ---@type boolean|nil
    local verified = false

    -- С `skipEmptyExchange` сервер кончает разговор на втором шаге;
    -- сервер без него просит ещё один пустой, и подпись он прислал раньше.
    while not reply.done do
        reply, err = ask(
            link,
            settings,
            request.system(
                db,
                NONE,
                'saslContinue',
                1,
                'conversationId',
                reply.conversationId,
                'payload',
                value.binary(payload)
            ),
            deadline
        )

        if reply == nil then
            return nil, err
        end

        if not verified then
            verified, wrong = scram.verify(state, tostring(reply.payload))

            if not verified then
                return refuse(link, failure.DENIED, denied:format(wrong))
            end
        end

        payload = ''
    end

    -- Сервер, объявивший вход законченным уже на первом шаге, подписи
    -- не прислал: доказательства клиента он не видел и пароля не доказал.
    -- Без этой сверки подставной сервер впускал бы одним словом `done`.
    if not verified then
        return refuse(
            link,
            failure.DENIED,
            denied:format(
                'сервер кончил вход, не подписавшись: он не знает пароля'
            )
        )
    end

    return link
end

--- Описание клиента для `hello`: его видно в журнале сервера.
---@param name string
---@return table
local function client_of(name)
    return {
        application = { name = name },
        driver = { name = 'tnt-mongo', version = 'scm-1' },
        os = { type = jit.os },
        platform = 'Tarantool ' .. _TARANTOOL,
    }
end

--- Открывает соединение и входит — в срок, который дал пул.
---
--- Отказ — `TntStorageFailure`: `denied` пул отдаёт взявшему сразу
--- (`retriable = false`), `unreachable` повторяет внутри срока.
---@param settings TntMongoLinkSettings
---@param left number Остаток срока `take`, секунд; больше нуля
---@return TntMongoLink|nil link
---@return TntStorageFailure|nil err
function Module.open(settings, left)
    local deadline = within.deadline(left)
    local where = settings.where
    local connected, socket = pcall(source().connect, settings.host, settings.port, left)

    if not (connected and socket) then
        local why = connected and errno.strerror() or tostring(socket)

        return nil,
            failure.new(
                failure.UNREACHABLE,
                ('mongo %s: соединение не открылось: %s'):format(where, why)
            )
    end

    ---@type TntMongoLink
    local link = {
        io = socket,
        socket = socket,
        secured = settings.tls ~= nil,
        next_id = 1,
        session = uuid.new(),
        transactions = 0,
    }

    if link.secured then
        local tls = settings.tls --[[@as TntMongoTlsSettings]]
        local secured, refusal = source().tls().wrap(socket, {
            host = settings.host,
            -- Срок вышел — tnt-tls откажет сам, и отказ уйдёт в текст ниже.
            timeout = within.left(deadline),
            verify = tls.verify,
            ca_file = tls.ca_file,
            ca_path = tls.ca_path,
            sni = tls.sni,
        })

        if secured == nil then
            return refuse(
                link,
                failure.UNREACHABLE,
                ('mongo %s: рукопожатие TLS не прошло: %s'):format(where, refusal)
            )
        end

        link.io = secured
    end

    local hello, err =
        ask(link, settings, request.system('admin', NONE, 'hello', 1, 'client', client_of(settings.name)), deadline)

    if hello == nil then
        return nil, err
    end

    if settings.replica_set ~= nil and hello.setName ~= settings.replica_set then
        local text = ('mongo %s: узел не из набора реплик %s, а из %s'):format(
            where,
            settings.replica_set,
            tostring(hello.setName or 'никакого')
        )

        return refuse(link, failure.DENIED, text)
    end

    if settings.username == nil then
        return link
    end

    return authenticate(link, settings, deadline)
end

return Module
