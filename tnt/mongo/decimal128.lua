--- Точное число `decimal` Tarantool в `decimal128` BSON и обратно.
---
--- `decimal128` — десятичное с плавающей точкой по IEEE 754-2008 в двоичной
--- записи (BID): знак, порядок со сдвигом 6176 и коэффициент до 34 знаков
--- целым числом в 113 битах. У `decimal` Tarantool 38 знаков и порядок
--- шире, поэтому в одну сторону не всё выразимо: число длиннее 34 знаков
--- и порядок за пределами `decimal128` — исключение, а не округление.
--- Округлённая сумма денег — тихая порча, которую потом не найти:
--- отказ виден сразу, округление — никогда.
---
--- Коэффициент считается четырьмя словами по 32 бита в числах Lua:
--- произведение слова на 10 с переносом меньше 2⁵³, и double держит его
--- точно — ни `uint64`, ни длинной арифметики не нужно.
---
--- Масштаб сохраняется в обе стороны: `1.10` уходит коэффициентом 110
--- с порядком −2 и возвращается `1.10`, а не `1.1`.

local decimal = require('decimal')

local Module = {}

--- Сдвиг порядка в записи.
local BIAS = 6176

--- Границы порядка.
local MIN_EXPONENT = -6176
local MAX_EXPONENT = 6111

--- Наибольшая длина коэффициента в знаках.
local MAX_DIGITS = 34

--- Длина записи в байтах.
local SIZE = 16

--- Основание слова коэффициента.
local WORD = 2 ^ 32

--- Знак в старшем слове.
local SIGN = 2 ^ 31

--- Шаг порядка в старшем слове: порядок стоит над 17 битами коэффициента.
local EXPONENT_STEP = 2 ^ 17

--- С этого значения старшего слова без знака запись особая: бесконечность,
--- NaN либо коэффициент за 113 битами.
local SPECIAL = 3 * 2 ^ 29

--- Слово в четыре байта младшим вперёд.
---@param word number
---@return string
local function bytes_of(word)
    local out = {}

    for index = 1, 4 do
        out[index] = string.char(math.floor(word % 256))
        word = math.floor(word / 256)
    end

    return table.concat(out)
end

--- Слово из четырёх байтов младшим вперёд.
---@param bytes string
---@param at integer С какого байта, от единицы
---@return number
local function word_of(bytes, at)
    return bytes:byte(at) + bytes:byte(at + 1) * 256 + bytes:byte(at + 2) * 65536 + bytes:byte(at + 3) * 16777216
end

--- Запись `decimal128` числа.
---
--- Число, которого `decimal128` не выразит, — отказ текстом: бросает его
--- запись документа, на строке того, кто документ дал.
---@param number any decimal
---@return string|nil bytes Шестнадцать байтов
---@return string|nil err
function Module.encode(number)
    local text = tostring(number)
    -- Перед точкой у `decimal` всегда есть цифра: `0.5`, а не `.5`.
    local sign, whole, fraction, power = text:match('^(%-?)(%d%d*)%.?(%d*)E?([-+]?%d*)$')
    local digits = whole .. fraction
    -- Ведущие нули значащими не считаются: `0.000…01` — одна цифра.
    local significant = #digits - #digits:match('^0*')
    local exponent = (tonumber(power) or 0) - #fraction

    if significant > MAX_DIGITS or exponent < MIN_EXPONENT or exponent > MAX_EXPONENT then
        return nil,
            ('decimal %s не уходит в decimal128: до 34 знаков и порядок от -6176 до 6111'):format(
                text
            )
    end

    -- Слова — таблица без типа: их четыре всегда, и пустоты в них не бывает.
    ---@type table
    local words = { 0, 0, 0, 0 }

    for digit in digits:gmatch('%d') do
        local carry = tonumber(digit) --[[@as number]]

        for index = 1, 4 do
            local next = words[index] * 10 + carry

            words[index] = next % WORD
            carry = math.floor(next / WORD)
        end
    end

    local high = (sign == '-' and SIGN or 0) + (exponent + BIAS) * EXPONENT_STEP + words[4]

    return bytes_of(words[1]) .. bytes_of(words[2]) .. bytes_of(words[3]) .. bytes_of(high)
end

--- Число из записи `decimal128`.
---
--- Бесконечность, NaN и коэффициент за 34 знаками `decimal` не выразит:
--- это отказ, а не нуль и не ошибка кода.
---@param bytes string Шестнадцать байтов
---@return any|nil number decimal
---@return string|nil err
function Module.decode(bytes)
    -- Длину даёт свой же разбор BSON, и чужая — ошибка кода, а не данных.
    -- Без сверки лишние байты пропускались бы молча: слова читаются
    -- с начала записи.
    if #bytes ~= SIZE then
        error(('decimal128 — 16 байтов, а дали %d'):format(#bytes), 2)
    end

    local high = word_of(bytes, 13)
    local unsigned = high % SIGN

    if unsigned >= SPECIAL then
        return nil,
            'decimal128: бесконечность, NaN либо особая запись — decimal её не выразит'
    end

    ---@type table
    local words = { word_of(bytes, 1), word_of(bytes, 5), word_of(bytes, 9), unsigned % EXPONENT_STEP }
    local exponent = math.floor(unsigned / EXPONENT_STEP) - BIAS
    local digits = {}

    repeat
        local rest = 0

        for index = 4, 1, -1 do
            local current = rest * WORD + words[index]

            words[index] = math.floor(current / 10)
            rest = current % 10
        end

        table.insert(digits, 1, rest)
    until words[1] + words[2] + words[3] + words[4] == 0

    if #digits > MAX_DIGITS then
        return nil,
            'decimal128: коэффициент длиннее 34 знаков — запись неканоническая'
    end

    local sign = high >= SIGN and '-' or ''

    return decimal.new(('%s%sE%d'):format(sign, table.concat(digits), exponent))
end

return Module
