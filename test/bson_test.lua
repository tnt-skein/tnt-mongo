--- Проверки BSON: каждый тип байт в байт в обе стороны, массив против
--- документа, исключения записи и отказы чтения.

local datetime = require('datetime')
local decimal = require('decimal')
local ffi = require('ffi')
local t = require('luatest')
local uuid = require('uuid')
local varbinary = require('varbinary')

local helper = dofile('test/helper.lua')

local encode, decode, types, storage = helper.encode, helper.decode, helper.types, helper.storage

local g = t.group('tnt.mongo.bson')

--- Целое в четыре байта младшим вперёд.
---@param number integer
---@return string
local function le32(number)
    return ffi.string(ffi.new('int32_t[1]', number), 4)
end

--- Целое в восемь байтов младшим вперёд.
---@param number any
---@return string
local function le64(number)
    return ffi.string(ffi.new('int64_t[1]', number), 8)
end

--- Документ из готовых элементов.
---@param ... string Элементы: байт типа, имя с нулём, значение
---@return string
local function doc(...)
    local body = table.concat({ ... })

    return le32(#body + 5) .. body .. '\0'
end

--- Элемент документа.
---@param kind integer
---@param name string
---@param bytes string
---@return string
local function element(kind, name, bytes)
    return string.char(kind) .. name .. '\0' .. bytes
end

--- Документ с одним полем `v` байтами и значением, прочитанным обратно.
---@param value any
---@return string bytes
---@return any back
local function one(value)
    local bytes = encode.encode(types.ordered('v', value), 1)

    return bytes, decode.decode(bytes).v
end

g.test_scalars_go_in_their_types = function()
    local cases = {
        { true, element(0x08, 'v', '\1') },
        { false, element(0x08, 'v', '\0') },
        { 'Анна', element(0x02, 'v', le32(9) .. 'Анна\0') },
        { '', element(0x02, 'v', le32(1) .. '\0') },
        { 7, element(0x10, 'v', le32(7)) },
        { -2 ^ 31, element(0x10, 'v', le32(-2 ^ 31)) },
        { 2 ^ 31, element(0x12, 'v', le64(2 ^ 31)) },
        { 2 ^ 53, element(0x12, 'v', le64(2 ^ 53)) },
        { 1.5, element(0x01, 'v', ffi.string(ffi.new('double[1]', 1.5), 8)) },
        { 9007199254740993LL, element(0x12, 'v', le64(9007199254740993LL)) },
        { box.NULL, element(0x0A, 'v', '') },
    }

    for _, case in ipairs(cases) do
        local bytes, back = one(case[1])

        t.assert_equals(bytes, doc(case[2]), tostring(case[1]))

        if type(case[1]) == 'cdata' and case[1] ~= nil then
            t.assert_equals(tostring(back), tostring(case[1]))
        elseif case[1] == nil then
            t.assert(rawequal(back, box.NULL))
        else
            t.assert_equals(back, case[1], tostring(case[1]))
        end
    end
end

g.test_tarantool_values_go_without_loss = function()
    local id = uuid.fromstr('6f5d9c77-6a4e-4a8b-9d7e-3a2f1c0b9e8d')
    local moment = datetime.new({ timestamp = 1789292096, nsec = 789999999 })
    local price = decimal.new('1.10')

    local bytes, back = one(id)

    t.assert_equals(bytes, doc(element(0x05, 'v', le32(16) .. '\4' .. id:bin('b'))))
    t.assert_equals(back, id)

    bytes, back = one(moment)
    t.assert_equals(bytes, doc(element(0x09, 'v', le64(1789292096789LL))))
    t.assert_equals(tostring(back), '2026-09-13T09:34:56.789Z')

    bytes, back = one(price)
    t.assert_equals(bytes, doc(element(0x13, 'v', helper.decimal128.encode(price))))
    t.assert_equals(tostring(back), '1.10')

    bytes, back = one(varbinary.new('\0\255'))
    t.assert_equals(bytes, doc(element(0x05, 'v', le32(2) .. '\0\0\255')))
    t.assert_equals(tostring(back), '\0\255')
    t.assert(varbinary.is(back))

    bytes, back = one(storage.binary('\1'))
    t.assert_equals(bytes, doc(element(0x05, 'v', le32(1) .. '\0\1')))
    t.assert_equals(tostring(back), '\1')

    bytes, back = one(storage.json({ a = 1 }))
    t.assert_equals(bytes, doc(element(0x02, 'v', le32(8) .. '{"a":1}\0')))
    t.assert_equals(back, '{"a":1}')
end

g.test_a_date_before_the_epoch_keeps_its_millisecond = function()
    local bytes, back = one(datetime.new({ timestamp = -1.5 }))

    t.assert_equals(bytes, doc(element(0x09, 'v', le64(-1500))))
    t.assert_equals(tostring(back), '1969-12-31T23:59:58.500Z')
end

g.test_values_without_a_pair_in_lua_go_back_as_themselves = function()
    local id = types.object_id('650f1c2e9b1e8a0001a2b3c4')
    local bytes, back = one(id)

    t.assert_equals(bytes, doc(element(0x07, 'v', id.bytes)))
    t.assert(back == id)

    bytes, back = one(types.timestamp(1789814865, 5))
    t.assert_equals(bytes, doc(element(0x11, 'v', le32(5) .. le32(1789814865))))
    t.assert_equals(tostring(back), 'Timestamp(1789814865, 5)')

    bytes, back = one(types.regex('^a', 'mi'))
    t.assert_equals(bytes, doc(element(0x0B, 'v', '^a\0im\0')))
    t.assert_equals({ types.kind(back), back.pattern, back.flags }, { 'regex', '^a', 'im' })

    bytes, back = one(types.binary('\3\4', 3))
    t.assert_equals(bytes, doc(element(0x05, 'v', le32(2) .. '\3\3\4')))
    t.assert_equals({ types.kind(back), back.bytes, back.subtype }, { 'binary', '\3\4', 3 })

    bytes, back = one(types.MIN_KEY)
    t.assert_equals(bytes, doc(element(0xFF, 'v', '')))
    t.assert(back == types.MIN_KEY)

    bytes, back = one(types.MAX_KEY)
    t.assert_equals(bytes, doc(element(0x7F, 'v', '')))
    t.assert(back == types.MAX_KEY)
end

g.test_a_uuid_subtype_of_another_length_stays_binary = function()
    local body = doc(element(0x05, 'v', le32(2) .. '\4ab'))
    local back = decode.decode(body).v

    t.assert_equals({ types.kind(back), back.bytes, back.subtype }, { 'binary', 'ab', 4 })
end

g.test_a_sequence_is_an_array_and_the_rest_a_document = function()
    local bytes = one({ 1, 'a', box.NULL })

    t.assert_equals(
        bytes,
        doc(
            element(
                0x04,
                'v',
                doc(element(0x10, '0', le32(1)), element(0x02, '1', le32(2) .. 'a\0'), element(0x0A, '2', ''))
            )
        )
    )

    local _, back = one({ 1, 'a', box.NULL })

    t.assert_equals(#back, 3)
    t.assert(rawequal(back[3], box.NULL))
    t.assert_equals(getmetatable(back).__serialize, 'seq')

    t.assert_equals(one({ x = 1 }), doc(element(0x03, 'v', doc(element(0x10, 'x', le32(1))))))
    t.assert_equals(one({}), doc(element(0x03, 'v', doc())))

    for _, shape in ipairs({ 'seq', 'sequence', 'array' }) do
        t.assert_equals(one(setmetatable({}, { __serialize = shape })), doc(element(0x04, 'v', doc())), shape)
    end

    for _, shape in ipairs({ 'map', 'mapping' }) do
        t.assert_equals(
            one(setmetatable({ x = 1 }, { __serialize = shape })),
            doc(element(0x03, 'v', doc(element(0x10, 'x', le32(1))))),
            shape
        )
    end
end

g.test_empty_ones_come_back_as_themselves = function()
    local back = decode.decode(encode.encode({ a = {}, b = setmetatable({}, { __serialize = 'seq' }) }, 1))

    t.assert_equals(getmetatable(back).__serialize, 'map')
    t.assert_equals(getmetatable(back.a).__serialize, 'map')
    t.assert_equals(getmetatable(back.b).__serialize, 'seq')
    t.assert_equals(encode.encode(back, 1), encode.encode({ a = {}, b = setmetatable({}, { __serialize = 'seq' }) }, 1))
end

g.test_nested_documents_come_back = function()
    local source = { a = { b = { c = { 1, { d = 'x' } } } } }
    local back = decode.decode(encode.encode(source, 1))

    t.assert_equals(back.a.b.c[1], 1)
    t.assert_equals(back.a.b.c[2].d, 'x')
end

--- Бросок `encode` на строке вызывающего.
---@param source any
---@param message string
local function refused(source, message)
    helper.assert_blamed({
        {
            function()
                encode.encode(source, 1)
            end,
            message,
        },
    })
end

g.test_what_bson_cannot_hold_is_an_error_of_the_caller = function()
    local mixed =
        'массив — ключи 1..n без дыр (пустое — box.NULL), документ — имена строками'

    refused({ 1, nil, 3 }, 'имя поля number 1: ' .. mixed)
    refused({ 1, x = 2 }, 'имя поля number 1: ' .. mixed)
    refused({ [true] = 2 }, 'имя поля boolean true: ' .. mixed)
    refused(
        setmetatable({ x = 1 }, { __serialize = 'seq' }),
        'дыра в массиве на месте 1: пустое значение пишут box.NULL'
    )
    refused({ ['a\0b'] = 1 }, 'имя поля "a\\0b" с нулевым байтом')
    refused(
        { v = print },
        'значение function не уходит в BSON: документ — таблица, байты — binary'
    )
    refused(
        { v = 2 ^ 60 },
        'число 1.1529215046068e+18 за пределом ±2^53: целые там неточны — передайте int64 либо decimal'
    )
    refused(
        { v = decimal.new('1E+7000') },
        'decimal 1E+7000 не уходит в decimal128: до 34 знаков и порядок от -6176 до 6111'
    )
    refused({ 1, 2 }, 'документ BSON — таблица с именами полей, а не массив')
    refused('x', 'документ BSON — таблица с именами полей, а не массив')
end

g.test_depth_is_bounded = function()
    local deep = {}
    local cursor = deep

    for _ = 1, encode.MAX_DEPTH - 1 do
        cursor.next = {}
        cursor = cursor.next
    end

    t.assert(#encode.encode(deep, 1) > 0)

    cursor.next = {}

    refused(deep, 'документ вложен глубже 100: таблица ссылается на себя?')

    local looped = {}

    looped.self = looped

    refused(looped, 'документ вложен глубже 100: таблица ссылается на себя?')
end

g.test_an_ordered_document_keeps_its_order = function()
    t.assert_equals(
        encode.encode(types.ordered('b', 1, 'a', types.ordered('y', 2, 'x', 3)), 1),
        doc(
            element(0x10, 'b', le32(1)),
            element(0x03, 'a', doc(element(0x10, 'y', le32(2)), element(0x10, 'x', le32(3))))
        )
    )
end

--- Отказ чтения: текст и поломка ли записи.
---@param bytes string
---@param text string
---@param fatal boolean
local function unread(bytes, text, fatal)
    t.assert_equals({ decode.decode(bytes) }, { nil, text, fatal })
end

g.test_a_broken_record_is_fatal = function()
    local cases = {
        {
            '\5\0\0',
            'запись BSON обрывается: на смещении 0 нужно 4 байт, а есть 3',
        },
        {
            le32(9) .. '\0',
            'запись BSON обрывается: на смещении 0 нужно 9 байт, а есть 5',
        },
        {
            le32(4) .. '\0',
            'документ BSON на смещении 0 без нулевого байта в конце',
        },
        {
            le32(5) .. '\1',
            'документ BSON на смещении 0 без нулевого байта в конце',
        },
        { doc() .. 'x', 'после документа ещё 1 байт' },
        {
            le32(7) .. '\16a\0',
            'имя поля на смещении 5 без нулевого байта до конца документа',
        },
        {
            le32(9) .. '\16v\0\0\0',
            'запись BSON обрывается: на смещении 7 нужно 4 байт, а есть 2',
        },
        {
            doc(element(0x02, 'v', le32(2) .. 'ab')),
            'строка BSON на смещении 7 без нулевого байта в конце',
        },
        {
            doc(element(0x02, 'v', le32(0))),
            'строка BSON на смещении 7 без нулевого байта в конце',
        },
        {
            doc(element(0x02, 'v', le32(-1))),
            'запись BSON обрывается: на смещении 11 нужно -1 байт, а есть 1',
        },
        { doc(element(0x08, 'v', '\2')), 'логика BSON на смещении 7 — байт 2' },
        {
            doc(element(0x05, 'v', le32(9) .. '\0ab')),
            'запись BSON обрывается: на смещении 12 нужно 9 байт, а есть 3',
        },
        {
            doc(element(0x07, 'v', 'short')),
            'запись BSON обрывается: на смещении 7 нужно 12 байт, а есть 6',
        },
        {
            doc(element(0x13, 'v', 'short')),
            'запись BSON обрывается: на смещении 7 нужно 16 байт, а есть 6',
        },
        {
            doc(element(0x10, 'v', le32(1) .. 'x')),
            'имя поля на смещении 12 без нулевого байта до конца документа',
        },
        {
            doc(element(0x03, 'v', le32(8) .. '\16a\0' .. '\0\0\0\0')),
            'поля документа на смещении 7 выходят за его длину',
        },
    }

    for index, case in ipairs(cases) do
        t.assert_equals({ decode.decode(case[1]) }, { nil, case[2], true }, index)
    end
end

g.test_what_tarantool_cannot_hold_spoils_only_the_reply = function()
    unread(
        doc(element(0x0D, 'code', le32(2) .. 'x\0')),
        'тип BSON 0x0D у поля "code" не поддерживается',
        false
    )
    unread(
        doc(element(0x09, 'v', le64(-9223372036854775807LL))),
        'дата -9223372036854775807LL мс за пределами datetime',
        false
    )
    unread(
        doc(element(0x13, 'v', ('7C000000000000000000000000000000'):fromhex():reverse())),
        'decimal128: бесконечность, NaN либо особая запись — decimal её не выразит',
        false
    )
end

g.test_depth_of_a_reply_is_bounded = function()
    local body = doc()

    -- Корень и 99 вложенных — сто документов в глубину: предел ровно.
    for _ = 1, 99 do
        body = doc(element(0x03, 'a', body))
    end

    t.assert_equals(type(decode.decode(body).a.a), 'table')

    body = doc(element(0x03, 'a', body))
    unread(body, 'документ в ответе вложен глубже 100', true)
end

--- Значения постоянной длины: байт типа, сколько байтов у значения
--- (у строки и двоичного — у их длины) и отказ, когда значение съело нуль
--- документа.
local SIZED = {
    { 0x01, 8, 'поля документа на смещении 0 выходят за его длину' },
    { 0x02, 4, 'строка BSON на смещении 7 без нулевого байта в конце' },
    {
        0x05,
        4,
        'запись BSON обрывается: на смещении 12 нужно 0 байт, а есть -1',
    },
    { 0x07, 12, 'поля документа на смещении 0 выходят за его длину' },
    { 0x09, 8, 'поля документа на смещении 0 выходят за его длину' },
    { 0x10, 4, 'поля документа на смещении 0 выходят за его длину' },
    { 0x11, 8, 'поля документа на смещении 0 выходят за его длину' },
    { 0x12, 8, 'поля документа на смещении 0 выходят за его длину' },
    { 0x13, 16, 'поля документа на смещении 0 выходят за его длину' },
}

g.test_a_value_cut_by_the_end_of_the_reply_names_what_it_lacks = function()
    for _, case in ipairs(SIZED) do
        local kind, size, swallowed = case[1], case[2], case[3]

        -- Значению не хватает байта: запись кончается раньше, и сказать
        -- это надо до чтения памяти за ней.
        unread(
            le32(7 + size - 1) .. string.char(kind) .. 'v\0' .. ('\0'):rep(size - 1),
            ('запись BSON обрывается: на смещении 7 нужно %d байт, а есть %d'):format(
                size,
                size - 1
            ),
            true
        )

        -- Байтов хватает ровно, но последний из них — нуль документа.
        unread(le32(7 + size) .. string.char(kind) .. 'v\0' .. ('\0'):rep(size), swallowed, true)
    end
end

g.test_integers_come_as_numbers_while_exact = function()
    local cases = {
        { le64(2 ^ 53), 2 ^ 53, 'number' },
        { le64(-2 ^ 53), -2 ^ 53, 'number' },
        { le64(9007199254740993LL), 9007199254740993LL, 'cdata' },
        { le64(-9007199254740993LL), -9007199254740993LL, 'cdata' },
    }

    for _, case in ipairs(cases) do
        local back = decode.decode(doc(element(0x12, 'v', case[1]))).v

        t.assert_equals(type(back), case[3])
        t.assert_equals(back, case[2])
    end

    t.assert(rawequal(decode.decode(doc(element(0x06, 'v', ''))).v, box.NULL))
end

g.test_a_bug_while_reading_is_a_fatal_refusal = function()
    local original = types.of

    types.of = function()
        error('сломалось')
    end

    local ok, err, fatal = decode.decode(doc(element(0x07, 'v', ('\1'):rep(12))))

    types.of = original

    t.assert_equals(ok, nil)
    t.assert_str_contains(err, 'сломалось')
    t.assert_equals(fatal, true)
end

--- Цепочка из `count` вложенных таблиц: массивов либо документов.
---@param count integer
---@param array boolean
---@return table
local function chain(count, array)
    ---@type table
    local root = array and { 1 } or { next = 1 }
    local cursor = root

    for _ = 2, count do
        ---@type table
        local inner = array and { 1 } or { next = 1 }

        if array then
            cursor[1] = inner
        else
            cursor.next = inner
        end

        cursor = inner
    end

    return root
end

g.test_arrays_and_ordered_documents_count_to_the_depth_too = function()
    local deep = 'документ вложен глубже 100: таблица ссылается на себя?'

    -- Корень — документ, в нём массивы: сто таблиц в глубину годятся.
    t.assert(#encode.encode({ list = chain(99, true) }, 1) > 0)
    refused({ list = chain(100, true) }, deep)

    -- Корень с порядком — тот же уровень, что таблица.
    t.assert(#encode.encode(types.ordered('a', chain(99, false)), 1) > 0)
    refused(types.ordered('a', chain(100, false)), deep)
end

g.test_a_key_starting_with_nul_is_refused = function()
    refused({ ['\0a'] = 1 }, 'имя поля "\\0a" с нулевым байтом')
end

g.test_negative_and_wide_integers_keep_every_byte = function()
    for _, number in ipairs({ -5LL, -2 ^ 40, -9007199254740993LL, 2 ^ 40 + 7 }) do
        local bytes, back = one(number)

        t.assert_equals(bytes, doc(element(0x12, 'v', le64(number))), tostring(number))
        t.assert_equals(back, number)
    end

    for _, number in ipairs({ -1, -256, -65536, 16777217, 2 ^ 31 - 1 }) do
        local bytes = one(number)

        t.assert_equals(bytes, doc(element(0x10, 'v', le32(number))), tostring(number))
    end

    local bytes = one(-0.1)

    t.assert_equals(bytes, doc(element(0x01, 'v', ffi.string(ffi.new('double[1]', -0.1), 8))))
end
