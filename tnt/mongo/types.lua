--- Значения BSON, у которых нет пары в Lua: опознаватель документа,
--- документ с порядком полей, отметка оплога, образец, двоичное с видом,
--- крайние ключи.
---
--- Каждое — таблица со своей метатаблицей: так драйвер отличает их от
--- документа при записи и отдаёт их же при чтении, и прочитанное уходит
--- обратно тем же типом. Опознаватель, прочитанный из базы и отданный
--- в фильтр строкой, не нашёл бы ничего: строка и `ObjectId` в MongoDB —
--- разные значения.
---
---     local id = types.object_id()                        -- новый
---     local same = types.object_id('650f1c2e9b1e8a0001a2b3c4')
---     local sort = types.ordered('age', -1, 'name', 1)    -- порядок полей важен
---
--- Порядок полей важен сортировке и ключу индекса: `{ age = -1, name = 1 }`
--- у таблицы Lua порядка не имеет, и индекс вышел бы не тем. Для прочего
--- порядок безразличен, и документ — простая таблица.

local clock = require('clock')
local digest = require('digest')

local must = require('tnt.must')
local external = require('tnt.external')

local Module = {}

--- Внешние средства: стенные часы и случайные байты.
local source = external.install(Module, {
    now = clock.realtime,
    random = digest.urandom,
})

--- Опознаватель строкой: 24 шестнадцатеричных знака.
local HEX = '^' .. ('%x'):rep(24) .. '$'

--- Наибольшее целое в четырёх байтах без знака: половины отметки оплога.
local UINT32_MAX = 2 ^ 32 - 1

--- Опознаватель строкой: шестнадцатеричная запись его байтов.
---@param id { bytes: string }
---@return string
local function hex_of(id)
    return id.bytes:hex()
end

--- Опознаватель документа: 12 байтов — секунды создания, случайное
--- на процесс и счётчик. В журнале и в JSON он виден шестнадцатеричной
--- строкой; равны опознаватели с равными байтами.
local ObjectId = {
    __tostring = hex_of,
    __serialize = hex_of,
    __eq = function(left, right)
        return left.bytes == right.bytes
    end,
}

--- Документ с порядком полей.
local Ordered = {}

--- Отметка оплога: секунды и порядковый номер в них.
local Timestamp = {
    __tostring = function(stamp)
        return ('Timestamp(%d, %d)'):format(stamp.t, stamp.i)
    end,
}

--- Образец регулярного выражения MongoDB и его флаги.
local Regex = {}

--- Двоичное с видом, отличным от общего (0) и UUID (4).
local Binary = {}

--- Крайние ключи: меньше и больше любого значения.
local Bound = {
    __tostring = function(bound)
        return bound.name
    end,
}

--- Меньше любого значения.
Module.MIN_KEY = setmetatable({ name = 'MinKey' }, Bound)

--- Больше любого значения.
Module.MAX_KEY = setmetatable({ name = 'MaxKey' }, Bound)

--- Имена значений по метатаблице.
local KINDS = {
    [ObjectId] = 'object_id',
    [Ordered] = 'ordered',
    [Timestamp] = 'timestamp',
    [Regex] = 'regex',
    [Binary] = 'binary',
    [Bound] = 'bound',
}

--- Метатаблицы по именам.
local METAS = {}

for meta, name in pairs(KINDS) do
    METAS[name] = meta
end

---@class TntMongoObjectIdState Случайное на процесс и счётчик
---@field process string Пять случайных байтов процесса
---@field counter number Следующее значение счётчика: в опознаватель идут его три младших байта

--- Случайное на процесс и счётчик: заводятся первым опознавателем.
---@type TntMongoObjectIdState|nil
local generator = nil

--- Целое в байты старшим вперёд: так пишет опознаватель сервер, и так
--- опознаватели одной секунды сортируются по счётчику.
---@param number number Целое
---@param size integer Сколько байтов
---@return string
local function big_endian(number, size)
    local bytes = ''

    for _ = 1, size do
        bytes = string.char(math.floor(number % 256)) .. bytes
        number = math.floor(number / 256)
    end

    return bytes
end

--- Новый опознаватель.
---
--- Случайное на процесс тянется при первом опознавателе, а не при загрузке:
--- до него проверкам нечего подменять. Счётчик начинается со случайного
--- числа, как велит спецификация ObjectId: два процесса, стартовавшие
--- в одну секунду с одним случайным, иначе выдали бы одни и те же
--- опознаватели.
---@return string bytes
local function fresh()
    if generator == nil then
        local seed = source().random(8)

        generator = {
            process = seed:sub(-#seed, 5),
            counter = seed:byte(6) * 65536 + seed:byte(7) * 256 + seed:byte(8),
        }
    end

    local counter = generator.counter

    generator.counter = counter + 1

    -- Секунды и счётчик — младшими байтами: старшие отрезает запись.
    return big_endian(math.floor(source().now()), 4) .. generator.process .. big_endian(counter, 3)
end

--- Опознаватель документа: новый либо из 24 шестнадцатеричных знаков.
---@param hex string|nil
---@return table
function Module.object_id(hex)
    if hex == nil then
        return setmetatable({ bytes = fresh() }, ObjectId)
    end

    if type(hex) ~= 'string' or not hex:match(HEX) then
        error(
            ('опознаватель — 24 шестнадцатеричных знака, а не %s'):format(
                tostring(hex)
            ),
            2
        )
    end

    return setmetatable({ bytes = hex:fromhex() }, ObjectId)
end

--- Значение прочитанного ответа, без проверок: что прислал сервер, то
--- и отдаётся — отказывать данным из базы тут нечем и незачем.
---@param kind string object_id, timestamp, regex либо binary
---@param fields table Поля значения
---@return table
function Module.of(kind, fields)
    return setmetatable(fields, METAS[kind])
end

--- Опознаватель ли это.
---@param value any
---@return boolean
function Module.is_object_id(value)
    return getmetatable(value) == ObjectId
end

--- Документ с порядком полей: имя, значение, имя, значение…
---
--- Пустое значение — `box.NULL`: `nil` посреди аргументов считается, но в
--- документ не пишется, как и у таблицы.
---@param ... any
---@return table
function Module.ordered(...)
    local count = select('#', ...)

    if count % 2 == 1 then
        error(
            ('документ с порядком: имён и значений поровну, а аргументов %d'):format(
                count
            ),
            2
        )
    end

    local fields = {}

    for position = 1, count / 2 do
        local name, value = select(position * 2 - 1, ...)

        must.at(2).string(name, ('имя поля %d'):format(position))

        -- `rawequal`: `box.NULL == nil` в LuaJIT верно, а он — законное пустое.
        if not rawequal(value, nil) then
            table.insert(fields, { name, value })
        end
    end

    return setmetatable({ fields = fields }, Ordered)
end

--- Отметка оплога.
---@param seconds integer Секунды от начала эпохи
---@param increment integer Номер в этой секунде
---@return table
function Module.timestamp(seconds, increment)
    local caller = must.at(2)

    caller.integer(seconds, 'секунды отметки')
    caller.integer(increment, 'номер отметки')
    caller.between(seconds, 'секунды отметки', 0, UINT32_MAX)
    caller.between(increment, 'номер отметки', 0, UINT32_MAX)

    return setmetatable({ t = seconds, i = increment }, Timestamp)
end

--- Образец регулярного выражения: MongoDB хранит флаги по алфавиту
--- и сравнивает образцы вместе с ними.
---@param pattern string
---@param flags string|nil Буквы флагов: `i`, `m`, `s`, `x`, `l`, `u`
---@return table
function Module.regex(pattern, flags)
    local caller = must.at(2)

    caller.string(pattern, 'образец')

    if pattern:find('%z') then
        error('образец с нулевым байтом: BSON его не выразит', 2)
    end

    caller.optional.matches(flags, 'флаги образца', '^[ilmsux]*$')

    local letters = {}

    for letter in (flags or ''):gmatch('.') do
        table.insert(letters, letter)
    end

    table.sort(letters)

    return setmetatable({ pattern = pattern, flags = table.concat(letters) }, Regex)
end

--- Двоичное с видом: `binary(bytes, subtype)`.
---
--- Общий вид (0) — `storage.binary` либо `varbinary`, UUID (4) — `uuid`;
--- здесь — прочие: старый UUID (3), MD5 (5), свой (128 и выше).
---@param bytes string
---@param subtype integer
---@return table
function Module.binary(bytes, subtype)
    local caller = must.at(2)

    caller.string(bytes, 'байты')
    caller.integer(subtype, 'вид двоичного')
    caller.between(subtype, 'вид двоичного', 0, 255)

    return setmetatable({ bytes = bytes, subtype = subtype }, Binary)
end

--- Какой это значение BSON без пары в Lua: `object_id`, `ordered`,
--- `timestamp`, `regex`, `binary`, `bound` либо `nil` — не из этого модуля.
---@param value any
---@return string|nil
function Module.kind(value)
    return KINDS[getmetatable(value)]
end

--- Сбрасывает случайное на процесс — для проверок.
function Module._reset()
    generator = nil
end

return Module
