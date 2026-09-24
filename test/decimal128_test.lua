--- Проверки `decimal128`: векторы записи из спецификации BSON в обе
--- стороны, масштаб, пределы и особые записи.

local decimal = require('decimal')
local t = require('luatest')

local helper = dofile('test/helper.lua')

local decimal128 = helper.decimal128

local g = t.group('tnt.mongo.decimal128')

--- Запись старшим словом вперёд, как в спецификации, — байты младшим вперёд.
---@param hex string 32 шестнадцатеричных знака, старшие первыми
---@return string
local function bid(hex)
    return (hex:fromhex():reverse())
end

--- Векторы: текст числа и запись BID (bson-corpus, decimal128-1.json).
local VECTORS = {
    { '0', '30400000000000000000000000000000' },
    { '-0', 'B0400000000000000000000000000000' },
    { '1', '30400000000000000000000000000001' },
    { '-1', 'B0400000000000000000000000000001' },
    { '0.1', '303E0000000000000000000000000001' },
    { '0.001234', '303400000000000000000000000004D2' },
    { '1.10', '303C000000000000000000000000006E' },
    { '0.000', '303A0000000000000000000000000000' },
    { '123456789012', '30400000000000000000001CBE991A14' },
    { '9999999999999999999999999999999999', '3041ED09BEAD87C0378D8E63FFFFFFFF' },
    { '1E+6111', '5FFE0000000000000000000000000001' },
    { '1E-6176', '00000000000000000000000000000001' },
    { '-9.999999999999999999999999999999999E-6143', '8001ED09BEAD87C0378D8E63FFFFFFFF' },
    { '-0E-6176', '80000000000000000000000000000000' },
}

g.test_vectors_go_both_ways = function()
    for _, vector in ipairs(VECTORS) do
        local text, hex = vector[1], vector[2]
        local number = decimal.new(text)

        t.assert_equals(decimal128.encode(number):hex(), bid(hex):hex(), text)

        local back, err = decimal128.decode(bid(hex))

        t.assert_equals(err, nil, text)
        t.assert_equals(tostring(back), tostring(number), text)
    end
end

g.test_the_scale_survives = function()
    for _, text in ipairs({ '1.10', '0.000', '100', '1E+3', '-12.3400' }) do
        local back = decimal128.decode(decimal128.encode(decimal.new(text)))

        t.assert_equals(tostring(back), tostring(decimal.new(text)), text)
    end
end

g.test_what_decimal128_cannot_hold_is_refused_by_text = function()
    for _, text in ipairs({ '12345678901234567890123456789012345', '1E+6112', '1E-6177' }) do
        local shown = tostring(decimal.new(text))

        t.assert_equals({ decimal128.encode(decimal.new(text)) }, {
            nil,
            ('decimal %s не уходит в decimal128: до 34 знаков и порядок от -6176 до 6111'):format(
                shown
            ),
        })
    end
end

g.test_the_edges_of_the_range_go = function()
    for _, text in ipairs({ '1234567890123456789012345678901234', '1E+6111', '1E-6176' }) do
        t.assert_equals(tostring(decimal128.decode(decimal128.encode(decimal.new(text)))), text)
    end
end

g.test_special_records_are_refused = function()
    local special =
        'decimal128: бесконечность, NaN либо особая запись — decimal её не выразит'

    for _, hex in ipairs({
        '7C000000000000000000000000000000',
        '78000000000000000000000000000000',
        'F8000000000000000000000000000000',
        '6C10000000000000000000000000000A',
    }) do
        t.assert_equals({ decimal128.decode(bid(hex)) }, { nil, special }, hex)
    end

    -- Старшие биты 01 и 10 — обычная запись, а не особая.
    t.assert_equals(tostring(decimal128.decode(bid('5FFE0000000000000000000000000001'))), '1E+6111')
end

g.test_a_coefficient_over_34_digits_is_not_canonical = function()
    -- 10^34 = 0x1ED09BEAD87C0378D8E6400000000: на единицу больше предела.
    t.assert_equals({ decimal128.decode(bid('3041ED09BEAD87C0378D8E6400000000')) }, {
        nil,
        'decimal128: коэффициент длиннее 34 знаков — запись неканоническая',
    })
end

g.test_every_word_of_the_coefficient_is_read_to_the_end = function()
    -- После первого деления на десять одно из слов коэффициента — ноль,
    -- а соседнее — нет: чтение обязано дойти до конца всех четырёх.
    local cases = {
        '42949672960',
        '42949672970',
        '184467440737095516160',
        '184467440737095516170',
        '792281625142643375935439503360',
        '792281625142643375935439503370',
        '79228162514264337593543950336',
    }

    for _, text in ipairs(cases) do
        t.assert_equals(tostring(decimal128.decode(decimal128.encode(decimal.new(text)))), text)
    end
end

g.test_leading_zeros_are_not_significant = function()
    -- Тридцать значащих цифр за пятью нулями: сорок знаков записи, но в
    -- decimal128 помещается.
    local text = '0.0000123456789012345678901234567890'

    t.assert_equals(tostring(decimal128.decode(decimal128.encode(decimal.new(text)))), text)
end

g.test_the_special_form_starts_at_its_edge = function()
    t.assert_equals({ decimal128.decode(bid('60000000000000000000000000000000')) }, {
        nil,
        'decimal128: бесконечность, NaN либо особая запись — decimal её не выразит',
    })
end

g.test_a_record_of_another_length_is_an_error_of_the_code = function()
    helper.assert_blamed({
        {
            function()
                decimal128.decode(('\0'):rep(15))
            end,
            'decimal128 — 16 байтов, а дали 15',
        },
        {
            function()
                decimal128.decode(bid('30400000000000000000000000000001') .. '\1')
            end,
            'decimal128 — 16 байтов, а дали 17',
        },
    })
end
