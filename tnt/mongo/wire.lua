--- Сообщение OP_MSG: рамка запроса и разбор рамки ответа.
---
--- С MongoDB 5.1 сервер понимает только OP_MSG (и сжатый OP_COMPRESSED,
--- о котором драйвер не договаривается): заголовок из четырёх целых —
--- длина, номер запроса, номер того, на что ответ, код операции, — затем
--- флаги и секции. Запрос драйвера — одна секция вида 0, тело команды.
---
--- Ответ сверяется целиком до разбора документа: не OP_MSG, ответ не на
--- этот запрос, неизвестный обязательный флаг, секция не того вида — всё
--- это поломка протокола, и соединение после неё не вернуть: следующий
--- ответ в нём мог бы оказаться чужим. Длина ответа сверяется
--- с пределом до чтения тела: принимать то, от чего предел защищает,
--- ради соединения нельзя, и такое соединение выбрасывается.
---
--- Контрольная сумма (флаг `checksumPresent`) отрезается, а не сверяется:
--- драйвер её не просит, и сервер шлёт её, только если просят; целость
--- байтов держат TCP и TLS.

local bit = require('bit')

local encode = require('tnt.mongo.bson.encode')
local failure = require('tnt.storage.failure')

local Module = {}

--- Код операции OP_MSG.
Module.OP_MSG = 2013

--- Заголовок сообщения: четыре целых по четыре байта.
Module.HEADER = 16

--- Заголовок, флаги и байт вида секции: короче ответа не бывает.
local SHORTEST = Module.HEADER + 5

--- Флаг ответа: в конце четыре байта контрольной суммы.
local CHECKSUM = 1

--- Флаги, которые драйвер понимает; прочие из младших шестнадцати —
--- обязательные, и незнакомый обязательный — отказ протокола.
local KNOWN = CHECKSUM

--- Младшие шестнадцать флагов обязательны к пониманию.
local REQUIRED = 0xFFFF

--- Вид секции: тело.
local BODY = 0

--- С этого значения четыре байта — отрицательное целое.
local SIGN = 2 ^ 31

--- Целое со знаком из четырёх байтов младшим вперёд.
---@param bytes string
---@param at integer С какого байта, от единицы
---@return integer
local function int32_at(bytes, at)
    local value = bytes:byte(at) + bytes:byte(at + 1) * 256 + bytes:byte(at + 2) * 65536 + bytes:byte(at + 3) * 16777216

    if value < SIGN then
        return value
    end

    return value - SIGN * 2
end

--- Беда протокола: ответ, которому нельзя верить.
---@param message string
---@return TntMongoTrouble
local function broken(message)
    return { kind = failure.BROKEN, message = message }
end

---@class TntMongoTrouble Беда обмена: род, текст и то, что нужно повторам
---@field kind string timeout, broken, overflow либо rejected
---@field message string
---@field sent boolean|nil Могла ли команда дойти до сервера; пусто — по роду
---@field retriable boolean|nil Приговор повтору, если его выносит обмен
---@field clean boolean|nil Ответ дочитан: соединение можно вернуть

--- Сообщение запроса: заголовок, флаги, секция тела.
---@param request_id integer Номер запроса
---@param body string Тело команды в BSON
---@return string
function Module.message(request_id, body)
    local int32 = encode.int32

    return int32(SHORTEST + #body)
        .. int32(request_id)
        .. int32(0)
        .. int32(Module.OP_MSG)
        .. int32(0)
        .. string.char(BODY)
        .. body
end

--- Читает ответ на запрос и отдаёт тело — документ BSON байтами.
---
--- `receive(size)` читает ровно столько байтов либо отдаёт беду связи:
--- её род решают часы и сеть, а не рамка.
---@param receive fun(size: integer): string|nil, TntMongoTrouble|nil
---@param request_id integer На что ждём ответ
---@param budget integer Предел длины ответа
---@return string|nil body
---@return TntMongoTrouble|nil trouble
function Module.read(receive, request_id, budget)
    local head, trouble = receive(Module.HEADER)

    if head == nil then
        return nil, trouble
    end

    local length, response_to, opcode = int32_at(head, 1), int32_at(head, 9), int32_at(head, 13)

    if opcode ~= Module.OP_MSG then
        return nil, broken(('ответ с кодом операции %d, а ждали OP_MSG'):format(opcode))
    end

    if response_to ~= request_id then
        return nil, broken(('ответ на запрос %d, а ждали на %d'):format(response_to, request_id))
    end

    if length < SHORTEST then
        return nil,
            broken(('ответ длиной %d байт короче заголовка OP_MSG'):format(length))
    end

    if length > budget then
        return nil,
            {
                kind = failure.OVERFLOW,
                message = ('ответ %d байт длиннее предела max_bytes %d'):format(length, budget),
            }
    end

    local rest, cut = receive(length - Module.HEADER)

    if rest == nil then
        return nil, cut
    end

    local flags = int32_at(rest, 1)
    local unknown = bit.band(flags, bit.bnot(KNOWN), REQUIRED)

    if unknown ~= 0 then
        return nil,
            broken(('в ответе незнакомые обязательные флаги 0x%X'):format(unknown))
    end

    if rest:byte(5) ~= BODY then
        return nil,
            broken(('первая секция ответа вида %d, а ждали тело'):format(rest:byte(5)))
    end

    local tail = bit.band(flags, CHECKSUM) * 4

    return rest:sub(6, #rest - tail)
end

return Module
