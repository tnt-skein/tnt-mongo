--- BSON: документ Lua в байты.
---
--- Значение уходит тем типом, который назвал `tnt-storage`
--- (`value.wire('mongo', v)`): правило «чем передать `int64`, время и
--- точное число» одно на все драйверы, что стоят на `tnt-storage`.
--- Здесь — только то, что есть у одного BSON: документ и массив, запись
--- типов байтами и значения без пары в Lua (`tnt.mongo.types`).
---
--- Таблица — массив, если `__serialize` говорит `seq` либо ключи — ровно
--- `1..n`; иначе документ, и тогда ключи — строки. Пустая таблица —
--- документ: пустой фильтр `{}` MongoDB понимает как «всё», а пустой
--- массив пишут `setmetatable({}, { __serialize = 'seq' })`, как для
--- `json.encode`. Дыра в массиве и ключ не строкой — исключение: `nil`
--- посреди массива пишут `box.NULL`.
---
--- Чтение — соседний `tnt.mongo.bson.decode`.

local bit = require('bit')
local ffi = require('ffi')
local msgpack = require('msgpack')

local decimal128 = require('tnt.mongo.decimal128')
local failure = require('tnt.storage.failure')
local types = require('tnt.mongo.types')
local value = require('tnt.storage.value')

local Module = {}

--- Глубже этого документ не вкладывается: у MongoDB предел тот же, а
--- бесконечная вложенность — это таблица, ссылающаяся на себя.
Module.MAX_DEPTH = 100

--- Байты типов BSON.
local DOUBLE, STRING, DOCUMENT, ARRAY, BINARY = 0x01, 0x02, 0x03, 0x04, 0x05
local OBJECT_ID, BOOLEAN, DATE, NULL, REGEX = 0x07, 0x08, 0x09, 0x0A, 0x0B
local INT32, TIMESTAMP, INT64, DECIMAL128, MIN_KEY, MAX_KEY = 0x10, 0x11, 0x12, 0x13, 0xFF, 0x7F

--- Виды двоичного со своей парой в Lua.
local GENERIC, UUID = 0, 4

--- Слова `__serialize`, которые делают таблицу массивом.
---@type table<any, boolean>
local SEQUENCE = { seq = true, sequence = true, array = true }

--- Свой кодировщик msgpack: чужой `msgpack.cfg` не должен менять запись.
---@diagnostic disable-next-line: undefined-field
local packer = msgpack.new()

--- Отметка брошенного здесь: наружу отказ уходит текстом.
local Raised = {}

--- Бросает отказ записи.
---@param text string
local function raise(text)
    error(setmetatable({ text = text }, Raised))
end

--- Целое в четыре байта младшим вперёд; отрицательное — дополнением до 2³².
---
--- Модуль — литералом, а не `2 ^ 32`: байтов берётся четыре, и у остатков
--- от 2³² и от 2³³ они одни и те же, так что порча степени прошла бы
--- незамеченной, а порчу литерала выдаёт уже `-1`.
---@param number integer
---@return string
function Module.int32(number)
    local rest = number % 4294967296
    local bytes = {}

    for index = 1, 4 do
        bytes[index] = math.floor(rest % 256)
        rest = math.floor(rest / 256)
    end

    return string.char(unpack(bytes))
end

local int32 = Module.int32

--- Целое в восемь байтов младшим вперёд.
---@param number any number либо int64
---@return string
local function int64(number)
    local rest = ffi.cast('int64_t', number) --[[@as any]]
    local bytes = {}

    for index = 1, 8 do
        bytes[index] = tonumber(bit.band(rest, 255))
        rest = bit.rshift(rest, 8)
    end

    return string.char(unpack(bytes))
end

--- Строка BSON: длина с нулём в конце, байты, нуль.
---@param text string
---@return string
local function bson_string(text)
    return int32(#text + 1) .. text .. '\0'
end

--- Имя поля: строка без нулевого байта.
---@param key any
---@return string
local function cstring(key)
    if type(key) ~= 'string' then
        raise(
            ('имя поля %s %s: массив — ключи 1..n без дыр (пустое — box.NULL), документ — имена строками'):format(
                type(key),
                tostring(key)
            )
        )
    end

    if key:find('%z') then
        raise(('имя поля %q с нулевым байтом'):format(key))
    end

    return key .. '\0'
end

---@type fun(item: any, depth: integer): integer, string
local encode_value

--- Документ из списка пар `{ имя, значение }`.
---@param fields table[]
---@param depth integer
---@return string
local function document_of(fields, depth)
    local parts = {}

    for _, field in ipairs(fields) do
        local kind, bytes = encode_value(field[2], depth)

        parts[#parts + 1] = string.char(kind) .. cstring(field[1]) .. bytes
    end

    local body = table.concat(parts)

    return int32(#body + 5) .. body .. '\0'
end

--- Таблица Lua документом либо массивом.
---@param source table
---@param depth integer
---@return integer kind
---@return string bytes
local function table_of(source, depth)
    if depth > Module.MAX_DEPTH - 1 then
        raise(
            ('документ вложен глубже %d: таблица ссылается на себя?'):format(
                Module.MAX_DEPTH
            )
        )
    end

    local marker = getmetatable(source)
    local shape = marker and marker.__serialize
    local count = 0

    for _ in pairs(source) do
        count = count + 1
    end

    local fields = {}

    if SEQUENCE[shape] or (shape == nil and count > 0 and count == #source) then
        for index = 1, count do
            -- `rawequal`: `box.NULL == nil` в LuaJIT верно, а `box.NULL` в массиве — законное пустое.
            if rawequal(source[index], nil) then
                raise(
                    ('дыра в массиве на месте %d: пустое значение пишут box.NULL'):format(
                        index
                    )
                )
            end

            fields[index] = { tostring(index - 1), source[index] }
        end

        return ARRAY, document_of(fields, depth + 1)
    end

    for key, item in pairs(source) do
        fields[#fields + 1] = { key, item }
    end

    return DOCUMENT, document_of(fields, depth + 1)
end

--- Запись значений без пары в Lua.
---@type table<string, fun(item: any, depth: integer): integer, string>
local SPECIAL = {
    object_id = function(id)
        return OBJECT_ID, id.bytes
    end,
    ordered = function(ordered, depth)
        return DOCUMENT, document_of(ordered.fields, depth + 1)
    end,
    timestamp = function(stamp)
        return TIMESTAMP, int32(stamp.i) .. int32(stamp.t)
    end,
    regex = function(regex)
        return REGEX, regex.pattern .. '\0' .. regex.flags .. '\0'
    end,
    binary = function(binary)
        return BINARY, int32(#binary.bytes) .. string.char(binary.subtype) .. binary.bytes
    end,
    bound = function(bound)
        return bound == types.MIN_KEY and MIN_KEY or MAX_KEY, ''
    end,
}

--- Запись значений по типу, который назвал `tnt-storage`.
---@type table<string, fun(item: any): integer, string>
local WIRED = {
    null = function()
        return NULL, ''
    end,
    bool = function(flag)
        return BOOLEAN, flag and '\1' or '\0'
    end,
    string = function(text)
        return STRING, bson_string(text)
    end,
    int32 = function(number)
        return INT32, int32(number)
    end,
    int64 = function(number)
        return INT64, int64(number)
    end,
    double = function(number)
        -- msgpack пишет дробное double старшим байтом вперёд за байтом типа.
        return DOUBLE, packer.encode(number):sub(2):reverse()
    end,
    date = function(milliseconds)
        return DATE, int64(milliseconds)
    end,
    binary = function(bytes)
        return BINARY, int32(#bytes) .. string.char(GENERIC) .. bytes
    end,
    uuid = function(id)
        return BINARY, int32(16) .. string.char(UUID) .. id:bin('b')
    end,
    decimal128 = function(number)
        local bytes, wrong = decimal128.encode(number)

        if bytes == nil then
            raise(wrong --[[@as string]])
        end

        return DECIMAL128, bytes --[[@as string]]
    end,
}

--- Значение: байт типа и запись.
---@param item any
---@param depth integer
---@return integer kind
---@return string bytes
function encode_value(item, depth)
    local special = types.kind(item)

    if special ~= nil then
        local write = SPECIAL[special]

        return write(item, depth)
    end

    local marker = getmetatable(item)

    if type(item) == 'table' and (marker == nil or marker.__serialize ~= nil) then
        return table_of(item, depth)
    end

    local wired, kind = value.wire(value.MONGO, item)
    local write = WIRED[
        kind --[[@as string]]
    ]

    return write(wired)
end

--- Документ в байты.
---
--- Негодное значение — исключение на строке того, кто звал: его место
--- ставит этот вызов, а не глубина, на которой нашлась беда.
---@param source table Таблица либо `types.ordered`
---@param level integer Уровень вины, как у `error`, в кадрах того, кто зовёт
---@return string
function Module.encode(source, level)
    local ok, kind, bytes = pcall(encode_value, source, 0)

    if not ok then
        local raised = kind --[[@as any]]
        local text = getmetatable(raised) == Raised and raised.text or failure.text(raised)

        error(text, level + 1)
    end

    if kind ~= DOCUMENT then
        error('документ BSON — таблица с именами полей, а не массив', level + 1)
    end

    return bytes --[[@as string]]
end

return Module
