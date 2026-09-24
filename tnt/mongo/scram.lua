--- Вход SCRAM-SHA-256 (RFC 5802, RFC 7677): пароль не уходит в сеть,
--- а сервер доказывает, что знает его и сам.
---
--- Разговор в три шага. Клиент шлёт имя и своё случайное; сервер
--- отвечает общим случайным, солью и числом проходов; клиент доказывает
--- знание пароля подписью, построенной из растянутого пароля, и получает
--- подпись сервера, которую обязан сверить: без сверки вход к подставному
--- серверу, который пароля не знает, прошёл бы молча.
---
--- Растянутый пароль — PBKDF2-HMAC-SHA256 — считается здесь, из HMAC
--- `tnt-hash`, а не `digest.pbkdf2`: соль приходит от сервера, и нулевой
--- байт в ней бывает (у соли в 28 байт — примерно в каждой десятой), а
--- `digest.pbkdf2` режет соль по нему (документ `tnt-hash`). Растягивание —
--- десятки миллисекунд работы на 15 000 проходов (умолчание MongoDB),
--- поэтому оно уступает управление через каждую тысячу проходов и
--- запоминается: следующие соединения того же драйвера с той же солью
--- его не повторяют.
---
--- Чего здесь нет: SASLprep. Пароль уходит байтами как есть, и пароль,
--- который SASLprep поменял бы (не в NFKC, с особыми пробелами), не
--- войдёт — отказ `denied`, а не вход с другим паролем. Пароль из
--- печатных знаков ASCII SASLprep не меняет.

local bit = require('bit')
local digest = require('digest')
local fiber = require('fiber')

local hash = require('tnt.hash')
local external = require('tnt.external')

local Module = {}

--- Способ входа, как его называет сервер.
Module.MECHANISM = 'SCRAM-SHA-256'

--- Через столько проходов растягивание уступает управление.
Module.SLICE = 1000

--- Меньше стольких проходов сервер не назначает (RFC 7677): меньшее —
--- подставной сервер, облегчающий перебор.
Module.MIN_ITERATIONS = 4096

--- Внешние средства: случайное клиента и уступка.
local source = external.install(Module, {
    nonce = function()
        return digest.base64_encode(digest.urandom(24))
    end,
    yield = fiber.yield,
})

---@class TntMongoScram Состояние одного входа
---@field bare string Первое сообщение клиента без заголовка
---@field nonce string Случайное клиента
---@field signature string|nil Подпись, которую пришлёт сервер

--- Имя для SCRAM: запятая и знак равенства — служебные знаки разговора.
---@param name string
---@return string
local function saslname(name)
    return (name:gsub('=', '=3D'):gsub(',', '=2C'))
end

--- Первое сообщение: имя и случайное.
---@param username string
---@return TntMongoScram state
---@return string payload
function Module.first(username)
    local nonce = source().nonce()
    local bare = ('n=%s,r=%s'):format(saslname(username), nonce)

    return { bare = bare, nonce = nonce }, 'n,,' .. bare
end

--- «Исключающее или» двух строк одной длины.
---@param left string
---@param right string
---@return string
local function xor(left, right)
    local out = {}

    for index = 1, #left do
        out[index] = string.char(bit.bxor(left:byte(index), right:byte(index)))
    end

    return table.concat(out)
end

--- PBKDF2-HMAC-SHA256 для одного блока итога.
---@param password string
---@param salt string
---@param iterations integer
---@return string
function Module.pbkdf2(password, salt, iterations)
    local block = hash.hmac('sha256', password, salt .. '\0\0\0\1', 'raw')
    local sum = block

    for round = 2, iterations do
        if round % Module.SLICE == 0 then
            source().yield()
        end

        block = hash.hmac('sha256', password, block, 'raw')
        sum = xor(sum, block)
    end

    return sum
end

--- Растягивание пароля с памятью о последней соли.
---
--- Пароль живёт только в замыкании: в настройках, в показателях пула
--- и в отказах его нет.
---@param password string
---@return fun(salt: string, iterations: integer): string
function Module.salter(password)
    local known = {}

    return function(salt, iterations)
        if known.salt ~= salt or known.iterations ~= iterations then
            known = { salt = salt, iterations = iterations, key = Module.pbkdf2(password, salt, iterations) }
        end

        return known.key
    end
end

--- Второе сообщение клиента: доказательство знания пароля.
---
--- Отказ — ответ сервера, которому нельзя верить: чужое случайное, соли
--- нет, проходов меньше 4096.
---@param state TntMongoScram
---@param reply string Первое сообщение сервера
---@param salted fun(salt: string, iterations: integer): string Растягивание пароля
---@return string|nil payload
---@return string|nil err
function Module.final(state, reply, salted)
    -- Случайное сервера — наше и ещё хоть один знак: иначе это ответ
    -- не на наш вход. Наше — base64, и `+` в нём для образца не знак.
    local ours = state.nonce:gsub('%p', function(char)
        return '%' .. char
    end)
    local nonce, salt, rounds = reply:match('^r=(' .. ours .. '[^,]+),s=([^,]+),i=(%d+)$')

    if nonce == nil then
        return nil,
            ('ответ сервера на вход не по SCRAM либо не на наше случайное: %s'):format(
                reply
            )
    end

    local iterations = tonumber(rounds) --[[@as integer]]

    if iterations < Module.MIN_ITERATIONS then
        return nil,
            ('сервер назначил %d проходов, а меньше 4096 не бывает'):format(
                iterations
            )
    end

    local key = salted(digest.base64_decode(salt --[[@as string]]), iterations)
    local client_key = hash.hmac('sha256', key, 'Client Key', 'raw')
    local without_proof = 'c=biws,r=' .. nonce
    local message = table.concat({ state.bare, reply, without_proof }, ',')
    local proof = xor(client_key, hash.hmac('sha256', hash.digest('sha256', client_key, 'raw'), message, 'raw'))

    state.signature = hash.hmac('sha256', hash.hmac('sha256', key, 'Server Key', 'raw'), message, 'raw')

    return without_proof .. ',p=' .. digest.base64_encode(proof)
end

--- Сверяет подпись сервера из его последнего сообщения.
---@param state TntMongoScram
---@param reply string Последнее сообщение сервера
---@return boolean|nil ok
---@return string|nil err
function Module.verify(state, reply)
    local refusal = reply:match('^e=(.*)$')

    if refusal ~= nil then
        return nil, ('сервер отказал во входе: %s'):format(refusal)
    end

    -- Подпись — после `v=` и до расширений; иной ответ подписью не сойдётся.
    local signature = reply:gsub('^v=', ''):gsub(',.*$', '')

    if
        not hash.equals(state.signature --[[@as string]], digest.base64_decode(signature))
    then
        return nil, 'подпись сервера не сошлась: он не знает пароля'
    end

    return true
end

return Module
