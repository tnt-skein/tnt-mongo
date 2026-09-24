--- Проверки значений BSON без пары в Lua: опознаватель, документ
--- с порядком, отметка оплога, образец, двоичное с видом, крайние ключи.

local json = require('json')
local t = require('luatest')

local helper = dofile('test/helper.lua')

local types = helper.types

local g = t.group('tnt.mongo.types')

--- Бросок на строке вызова: вызов стоит первой строкой замыкания.
---@param fn function
---@param message string
local function blamed(fn, message)
    helper.assert_blamed({ { fn, message } })
end

g.after_each(function()
    helper.restore()
    types._reset()
end)

--- Случайное и часы двойником: восемь байтов и 0x650f1c2e секунд.
---@param seed string
local function fixed(seed)
    types._set_source({
        random = function(size)
            t.assert_equals(size, 8)

            return seed
        end,
        now = function()
            return 0x650f1c2e + 0.9
        end,
    })
end

g.test_a_new_id_is_seconds_process_and_counter = function()
    fixed('\1\2\3\4\5\0\0\254')

    local first = types.object_id()
    local second = types.object_id()

    t.assert_equals(tostring(first), '650f1c2e01020304050000fe')
    t.assert_equals(tostring(second), '650f1c2e01020304050000ff')
    t.assert(types.is_object_id(first))
    t.assert_not(types.is_object_id({ bytes = first.bytes }))
end

g.test_the_counter_starts_from_the_seed_and_wraps = function()
    fixed('\0\0\0\0\0\255\255\255')

    t.assert_equals(tostring(types.object_id()), '650f1c2e0000000000ffffff')
    t.assert_equals(tostring(types.object_id()), '650f1c2e0000000000000000')

    types._reset()
    fixed('\0\0\0\0\0\1\2\3')

    t.assert_equals(tostring(types.object_id()), '650f1c2e0000000000010203')
end

g.test_seconds_wrap_at_four_bytes = function()
    types._set_source({
        random = function()
            return '\0\0\0\0\0\0\0\0'
        end,
        now = function()
            return 2 ^ 32 + 5
        end,
    })

    t.assert_equals(tostring(types.object_id()), '000000050000000000000000')
end

g.test_the_process_part_is_drawn_once = function()
    local draws = 0

    types._set_source({
        random = function()
            draws = draws + 1

            return 'abcdefgh'
        end,
        now = function()
            return 0
        end,
    })

    local first, second = types.object_id(), types.object_id()

    t.assert_equals(draws, 1)
    t.assert_equals(first.bytes:sub(5, 9), 'abcde')
    t.assert_equals(second.bytes:sub(5, 9), 'abcde')
end

g.test_an_id_from_hex_is_equal_by_bytes = function()
    local id = types.object_id('650F1C2E9B1E8A0001A2B3C4')

    t.assert_equals(tostring(id), '650f1c2e9b1e8a0001a2b3c4')
    t.assert(id == types.object_id('650f1c2e9b1e8a0001a2b3c4'))
    t.assert_not(id == types.object_id('650f1c2e9b1e8a0001a2b3c5'))
    t.assert_equals(json.encode({ id = id }), '{"id":"650f1c2e9b1e8a0001a2b3c4"}')
end

g.test_a_wrong_hex_is_an_error_of_the_caller = function()
    for _, wrong in ipairs({ '650f1c2e9b1e8a0001a2b3c', '650f1c2e9b1e8a0001a2b3c4f', 'xyz', 7 }) do
        blamed(
            function()
                types.object_id(helper.wrong(wrong))
            end,
            ('опознаватель — 24 шестнадцатеричных знака, а не %s'):format(wrong)
        )
    end
end

g.test_ordered_keeps_names_in_order_and_drops_nil = function()
    local ordered = types.ordered('age', -1, 'name', 1, 'gone', nil, 'empty', box.NULL)

    t.assert_equals(types.kind(ordered), 'ordered')
    t.assert_equals(#ordered.fields, 3)
    t.assert_equals(ordered.fields[1], { 'age', -1 })
    t.assert_equals(ordered.fields[2], { 'name', 1 })
    t.assert_equals(ordered.fields[3][1], 'empty')
    t.assert(rawequal(ordered.fields[3][2], box.NULL))
end

g.test_ordered_wants_pairs_of_a_name_and_a_value = function()
    blamed(function()
        types.ordered('age', -1, 'name')
    end, 'документ с порядком: имён и значений поровну, а аргументов 3')
    blamed(function()
        types.ordered('age', -1, helper.wrong(5), 1)
    end, 'имя поля 2 — строка, а не число')
end

g.test_a_timestamp_is_two_unsigned_halves = function()
    local stamp = types.timestamp(1789814865, 5)

    t.assert_equals(types.kind(stamp), 'timestamp')
    t.assert_equals({ stamp.t, stamp.i }, { 1789814865, 5 })
    t.assert_equals(tostring(stamp), 'Timestamp(1789814865, 5)')
    t.assert_equals(tostring(types.timestamp(0, 2 ^ 32 - 1)), 'Timestamp(0, 4294967295)')

    blamed(function()
        types.timestamp(helper.wrong(1.5), 0)
    end, 'секунды отметки — целое число, а не 1.5')
    blamed(function()
        types.timestamp(0, helper.wrong(1.5))
    end, 'номер отметки — целое число, а не 1.5')
    blamed(function()
        types.timestamp(-1, 0)
    end, 'секунды отметки — число от 0 до 4294967295, а не -1')
    blamed(function()
        types.timestamp(0, 2 ^ 32)
    end, 'номер отметки — число от 0 до 4294967295, а не 4294967296')
end

g.test_a_regex_sorts_its_flags = function()
    local regex = types.regex('^Ан', 'xmi')

    t.assert_equals(types.kind(regex), 'regex')
    t.assert_equals({ regex.pattern, regex.flags }, { '^Ан', 'imx' })
    t.assert_equals(types.regex('a').flags, '')

    blamed(function()
        types.regex('a\0b')
    end, 'образец с нулевым байтом: BSON его не выразит')
    blamed(function()
        types.regex(helper.wrong(5))
    end, 'образец — строка, а не число')
    blamed(function()
        types.regex('a', 'g')
    end, 'флаги образца — строка по образцу ^[ilmsux]*$, а не «g»')
end

g.test_a_binary_has_its_subtype = function()
    local binary = types.binary('\0\1', 128)

    t.assert_equals(types.kind(binary), 'binary')
    t.assert_equals({ binary.bytes, binary.subtype }, { '\0\1', 128 })
    t.assert_equals(types.binary('', 0).subtype, 0)
    t.assert_equals(types.binary('', 255).subtype, 255)

    blamed(function()
        types.binary(helper.wrong(5), 3)
    end, 'байты — строка, а не число')
    blamed(function()
        types.binary('', helper.wrong(1.5))
    end, 'вид двоичного — целое число, а не 1.5')
    blamed(function()
        types.binary('', 256)
    end, 'вид двоичного — число от 0 до 255, а не 256')
    blamed(function()
        types.binary('', -1)
    end, 'вид двоичного — число от 0 до 255, а не -1')
end

g.test_bounds_are_named = function()
    t.assert_equals(types.kind(types.MIN_KEY), 'bound')
    t.assert_equals(types.kind(types.MAX_KEY), 'bound')
    t.assert_equals(tostring(types.MIN_KEY), 'MinKey')
    t.assert_equals(tostring(types.MAX_KEY), 'MaxKey')
end

g.test_kind_knows_only_its_own_values = function()
    t.assert_equals(types.kind({}), nil)
    t.assert_equals(types.kind('x'), nil)
    t.assert_equals(types.kind(nil), nil)
    t.assert_equals(types.kind(setmetatable({}, { __serialize = 'map' })), nil)
    t.assert_equals(types.kind(types.object_id('650f1c2e9b1e8a0001a2b3c4')), 'object_id')
end

g.test_of_builds_values_of_a_reply_without_checks = function()
    local regex = types.of('regex', { pattern = 'a', flags = 'zz' })
    local stamp = types.of('timestamp', { t = 1, i = 2 })
    local binary = types.of('binary', { bytes = 'x', subtype = 9 })
    local id = types.of('object_id', { bytes = ('\1'):rep(12) })

    t.assert_equals(types.kind(regex), 'regex')
    t.assert_equals(regex.flags, 'zz')
    t.assert_equals(tostring(stamp), 'Timestamp(1, 2)')
    t.assert_equals(types.kind(binary), 'binary')
    t.assert_equals(tostring(id), ('01'):rep(12))
end
