--- BSON: байты ответа в документ Lua.
---
--- Документ читается таблицей с `__serialize = 'map'`, массив —
--- с `'seq'`: пустые остаются собой при записи обратно. `null` —
--- `box.NULL` и в документе, и в массиве: у MongoDB поле со значением
--- `null` и отсутствующее поле — разное (`$exists`). Целое `int64` —
--- числом, пока оно не дальше ±2⁵³, дальше — `int64`, как у msgpack самого
--- Tarantool. Двоичное общего вида — `varbinary`, UUID — `uuid`, время —
--- `datetime`, точное — `decimal`; прочее без пары в Lua — значения
--- `tnt.mongo.types`, и уходят обратно тем же типом.
---
--- Отказ чтения — пара: запись, противоречащая себе (длины, окончания),
--- — поломка протокола, и соединение не вернуть; тип, которого Tarantool
--- не выразит (`decimal128` NaN, дата за пределом `datetime`, старый код
--- JavaScript), — отказ этого ответа, а соединение цело.

local datetime = require('datetime')
local ffi = require('ffi')
local uuid = require('uuid')
local varbinary = require('varbinary')

local decimal128 = require('tnt.mongo.decimal128')
local types = require('tnt.mongo.types')

local Module = {}

--- Глубже этого документ в ответе не вкладывается: у MongoDB предел тот же.
Module.MAX_DEPTH = 100

--- Байты типов BSON.
local DOUBLE, STRING, DOCUMENT, ARRAY, BINARY = 0x01, 0x02, 0x03, 0x04, 0x05
local UNDEFINED, OBJECT_ID, BOOLEAN, DATE, NULL, REGEX = 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B
local INT32, TIMESTAMP, INT64, DECIMAL128, MIN_KEY, MAX_KEY = 0x10, 0x11, 0x12, 0x13, 0xFF, 0x7F

--- Виды двоичного со своей парой в Lua.
local GENERIC, UUID = 0, 4

--- Дальше этого целое `int64` отдаётся числом без потерь.
local EXACT = 2 ^ 53

--- Метатаблицы прочитанного: пустые документ и массив остаются собой.
local MAP = { __serialize = 'map' }
local SEQ = { __serialize = 'seq' }

--- Отметка брошенного здесь: текст и то, можно ли вернуть соединение.
local Raised = {}

--- Бросает отказ разбора.
---@param text string
---@param fatal boolean Поломка ли это записи, после которой соединение не вернуть
local function raise(text, fatal)
    error(setmetatable({ text = text, fatal = fatal }, Raised))
end

---@class TntMongoBsonReader Разбор одного ответа
---@field data string Байты ответа
---@field base any Указатель на них
---@field size integer Длина ответа

--- Сколько байтов требуется от смещения; не хватает — поломка записи.
---@param state TntMongoBsonReader
---@param offset integer
---@param need integer
local function demand(state, offset, need)
    if need < 0 or offset + need > state.size then
        raise(
            ('запись BSON обрывается: на смещении %d нужно %d байт, а есть %d'):format(
                offset,
                need,
                state.size - offset
            ),
            true
        )
    end
end

--- Число из памяти по смещению.
---@param state TntMongoBsonReader
---@param ctype string Тип указателя: 'const int32_t *' и соседи
---@param offset integer
---@param need integer Сколько байтов должно быть в ответе
---@return any
local function number_at(state, ctype, offset, need)
    demand(state, offset, need)

    local pointer = ffi.cast(ctype, state.base + offset) --[[@as any]]

    return pointer[0]
end

--- Строка с нулём в конце по смещению: сама строка и смещение за нулём.
---@param state TntMongoBsonReader
---@param offset integer
---@return string
---@return integer
local function cstring_at(state, offset)
    -- Нуль найдётся всегда: ответ кончается нулём документа, это сверено
    -- раньше. Съеденный конец документа сверяет тот, кто читает поля.
    -- Образец `%z` — ровно нулевой байт, и простого поиска не нужно.
    local stop = state.data:find('%z', offset + 1) --[[@as integer]]

    return state.data:sub(offset + 1, stop - 1), stop
end

--- Дата из миллисекунд: за пределами `datetime` — отказ ответа.
---@param milliseconds any int64
---@return any datetime
local function date_of(milliseconds)
    local number = tonumber(milliseconds) --[[@as number]]
    local seconds = math.floor(number / 1000)
    local units = { timestamp = seconds, nsec = (number - seconds * 1000) * 1e6 } --[[@as any]]
    local ok, moment = pcall(datetime.new, units)

    if not ok then
        raise(('дата %s мс за пределами datetime'):format(tostring(milliseconds)), false)
    end

    return moment
end

--- Двоичное: общий вид — `varbinary`, UUID — `uuid`, прочее — `types.binary`.
---@param bytes string
---@param subtype integer
---@return any
local function binary_of(bytes, subtype)
    if subtype == GENERIC then
        return varbinary.new(bytes)
    end

    if subtype == UUID and #bytes == 16 then
        return uuid.frombin(bytes, 'b')
    end

    return types.of('binary', { bytes = bytes, subtype = subtype })
end

--- Чтение значений по байту типа: значение и смещение за ним.
---@type table<integer, fun(state: TntMongoBsonReader, offset: integer): any, integer>
local READERS = {}

READERS[DOUBLE] = function(state, offset)
    return number_at(state, 'const double *', offset, 8), offset + 8
end

READERS[STRING] = function(state, offset)
    local length = number_at(state, 'const int32_t *', offset, 4)

    demand(state, offset + 4, length)

    if length < 1 or state.base[offset + 3 + length] ~= 0 then
        raise(
            ('строка BSON на смещении %d без нулевого байта в конце'):format(
                offset
            ),
            true
        )
    end

    return state.data:sub(offset + 5, offset + 3 + length), offset + 4 + length
end

READERS[BINARY] = function(state, offset)
    local length = number_at(state, 'const int32_t *', offset, 4)

    demand(state, offset + 5, length)

    return binary_of(state.data:sub(offset + 6, offset + 5 + length), state.base[offset + 4]), offset + 5 + length
end

READERS[UNDEFINED] = function(_, offset)
    return box.NULL, offset
end

READERS[NULL] = READERS[UNDEFINED]

READERS[OBJECT_ID] = function(state, offset)
    demand(state, offset, 12)

    return types.of('object_id', { bytes = state.data:sub(offset + 1, offset + 12) }), offset + 12
end

-- Байт логики есть всегда: поле стоит до нуля своего документа, а длина
-- документа и его нуль сверены до полей.
READERS[BOOLEAN] = function(state, offset)
    if state.base[offset] > 1 then
        raise(('логика BSON на смещении %d — байт %d'):format(offset, state.base[offset]), true)
    end

    return state.base[offset] == 1, offset + 1
end

READERS[DATE] = function(state, offset)
    return date_of(number_at(state, 'const int64_t *', offset, 8)), offset + 8
end

READERS[REGEX] = function(state, offset)
    local pattern, after = cstring_at(state, offset)
    local flags, stop = cstring_at(state, after)

    return types.of('regex', { pattern = pattern, flags = flags }), stop
end

READERS[INT32] = function(state, offset)
    return number_at(state, 'const int32_t *', offset, 4), offset + 4
end

-- Отметка — два целых без знака: номер в секунде, затем секунды. Длина
-- сверяется одна на обе половины.
READERS[TIMESTAMP] = function(state, offset)
    demand(state, offset, 8)

    local halves = ffi.cast('const uint32_t *', state.base + offset) --[[@as any]]

    return types.of('timestamp', { t = halves[1], i = halves[0] }), offset + 8
end

READERS[INT64] = function(state, offset)
    local integer = number_at(state, 'const int64_t *', offset, 8)

    if integer > EXACT or integer < -EXACT then
        return integer, offset + 8
    end

    return tonumber(integer), offset + 8
end

READERS[DECIMAL128] = function(state, offset)
    demand(state, offset, 16)

    local exact, why = decimal128.decode(state.data:sub(offset + 1, offset + 16))

    if exact == nil then
        raise(why --[[@as string]], false)
    end

    return exact, offset + 16
end

READERS[MIN_KEY] = function(_, offset)
    return types.MIN_KEY, offset
end

READERS[MAX_KEY] = function(_, offset)
    return types.MAX_KEY, offset
end

--- Документ либо массив по смещению: таблица и смещение за ним.
---@param state TntMongoBsonReader
---@param offset integer
---@param depth integer
---@param array boolean
---@return table
---@return integer
local function read_document(state, offset, depth, array)
    -- Та же запись предела, что у записи: у глубины от нуля шагом в единицу
    -- `>=` и `==` неотличимы, а так отличима всякая порча.
    if depth > Module.MAX_DEPTH - 1 then
        raise(('документ в ответе вложен глубже %d'):format(Module.MAX_DEPTH), true)
    end

    local length = number_at(state, 'const int32_t *', offset, 4)

    demand(state, offset, length)

    local stop = offset + length - 1

    if length < 5 or state.base[stop] ~= 0 then
        raise(
            ('документ BSON на смещении %d без нулевого байта в конце'):format(
                offset
            ),
            true
        )
    end

    local result = setmetatable({}, array and SEQ or MAP)
    local at = offset + 4

    while at < stop do
        local kind = state.base[at] --[[@as integer]]
        local key, after = cstring_at(state, at + 1)
        local item

        if after > stop then
            raise(
                ('имя поля на смещении %d без нулевого байта до конца документа'):format(
                    at + 1
                ),
                true
            )
        end

        if kind == DOCUMENT or kind == ARRAY then
            item, at = read_document(state, after, depth + 1, kind == ARRAY)
        elseif READERS[kind] ~= nil then
            item, at = READERS[kind](state, after)
        else
            raise(('тип BSON 0x%02X у поля %q не поддерживается'):format(kind, key), false)
        end

        if array then
            result[#result + 1] = item
        else
            result[key] = item
        end
    end

    if at ~= stop then
        raise(
            ('поля документа на смещении %d выходят за его длину'):format(
                offset
            ),
            true
        )
    end

    return result, stop + 1
end

--- Документ из байтов.
---
--- Брошенное не этим модулем — тоже отказ записи: разбор идёт по байтам
--- сервера, и что бы в нём ни сломалось, соединение после этого не вернуть.
---@param data string
---@return table|nil document
---@return string|nil err Почему не прочесть
---@return boolean|nil fatal Поломка записи: соединение не вернуть
function Module.decode(data)
    ---@type TntMongoBsonReader
    local state = { data = data, base = ffi.cast('const uint8_t *', data), size = #data }
    local ok, result, after = pcall(read_document, state, 0, 0, false)

    if not ok then
        local raised = getmetatable(result) == Raised

        local refused = result --[[@as any]]

        return nil, raised and refused.text or tostring(refused), not raised or refused.fatal
    end

    if after ~= #data then
        return nil, ('после документа ещё %d байт'):format(#data - after), true
    end

    return result
end

return Module
