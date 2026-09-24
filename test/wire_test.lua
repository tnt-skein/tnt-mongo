--- Проверки рамки OP_MSG: запрос байт в байт и каждая беда ответа.

local ffi = require('ffi')
local t = require('luatest')

local helper = dofile('test/helper.lua')

local wire = helper.wire

local g = t.group('tnt.mongo.wire')

--- Целые в байты младшим вперёд.
---@param ... integer
---@return string
local function ints(...)
    local count = select('#', ...)

    return ffi.string(ffi.new('int32_t[?]', count, { ... }), count * 4)
end

--- Читатель из строки: ровно столько байтов, сколько просят.
---@param text string
---@return fun(size: integer): string|nil, table|nil
---@return integer[] asked Запрошенные длины
local function receiver(text)
    local at, asked = 1, {}

    return function(size)
        table.insert(asked, size)

        local piece = text:sub(at, at + size - 1)

        at = at + size

        return piece
    end,
        asked
end

--- Тело ответа: `{ ok: 1 }`.
local BODY = helper.document('ok', 1)

g.test_a_request_is_header_flags_and_body = function()
    t.assert_equals(wire.OP_MSG, 2013)
    t.assert_equals(wire.HEADER, 16)
    t.assert_equals(wire.message(7, BODY), ints(21 + #BODY, 7, 0, 2013, 0) .. '\0' .. BODY)
end

g.test_a_reply_gives_its_body = function()
    local read, asked = receiver(helper.frame(7, BODY))

    t.assert_equals({ wire.read(read, 7, 1000) }, { BODY })
    t.assert_equals(asked, { 16, 5 + #BODY })
end

g.test_a_checksum_is_cut_off = function()
    local read = receiver(helper.frame(7, BODY .. 'CRC!', 1))

    t.assert_equals({ wire.read(read, 7, 1000) }, { BODY })
end

g.test_the_budget_is_checked_before_the_body = function()
    local frame = helper.frame(7, BODY)

    t.assert_equals({ wire.read(receiver(frame), 7, #frame) }, { BODY })

    local read, asked = receiver(frame)

    t.assert_equals({ wire.read(read, 7, #frame - 1) }, {
        nil,
        {
            kind = 'overflow',
            message = ('ответ %d байт длиннее предела max_bytes %d'):format(#frame, #frame - 1),
        },
    })
    t.assert_equals(asked, { 16 })
end

g.test_a_foreign_reply_is_broken = function()
    local cases = {
        {
            ints(21 + #BODY, 7, 7, 1, 0) .. '\0' .. BODY,
            'ответ с кодом операции 1, а ждали OP_MSG',
        },
        { ints(21 + #BODY, 7, 8, 2013, 0) .. '\0' .. BODY, 'ответ на запрос 8, а ждали на 7' },
        { ints(20, 7, 7, 2013, 0), 'ответ длиной 20 байт короче заголовка OP_MSG' },
        { helper.frame(7, BODY, 2), 'в ответе незнакомые обязательные флаги 0x2' },
        {
            helper.frame(7, BODY, 0x8000),
            'в ответе незнакомые обязательные флаги 0x8000',
        },
        {
            ints(21 + #BODY, 7, 7, 2013, 0) .. '\1' .. BODY,
            'первая секция ответа вида 1, а ждали тело',
        },
    }

    for _, case in ipairs(cases) do
        t.assert_equals({ wire.read(receiver(case[1]), 7, 1000) }, { nil, { kind = 'broken', message = case[2] } })
    end

    -- Старшие флаги необязательны: 0x10000 — exhaustAllowed.
    t.assert_equals({ wire.read(receiver(helper.frame(7, BODY, 0x10000)), 7, 1000) }, { BODY })
end

g.test_a_trouble_of_the_link_goes_as_it_is = function()
    local trouble = { kind = 'timeout', message = 'ответа нет за срок вызова' }

    t.assert_equals({ wire.read(function()
        return nil, trouble
    end, 7, 1000) }, { nil, trouble })

    local calls = 0

    t.assert_equals({
        wire.read(function(size)
            calls = calls + 1

            if calls == 1 then
                return ints(21 + #BODY, 7, 7, 2013), nil
            end

            t.assert_equals(size, 5 + #BODY)

            return nil, trouble
        end, 7, 1000),
    }, { nil, trouble })
end

g.test_wide_numbers_go_in_all_four_bytes = function()
    t.assert_equals(wire.message(0x12345678, BODY), ints(21 + #BODY, 0x12345678, 0, 2013, 0) .. '\0' .. BODY)

    local cases = {
        { ints(21 + #BODY, 7, 0x12345678, 2013, 0), 'ответ на запрос 305419896, а ждали на 7' },
        {
            ints(21 + #BODY, 7, 7, -2 ^ 31, 0),
            'ответ с кодом операции -2147483648, а ждали OP_MSG',
        },
        { ints(21 + #BODY, 7, 7, -1, 0), 'ответ с кодом операции -1, а ждали OP_MSG' },
        {
            ints(21 + #BODY, 7, 7, 2 ^ 31 - 1, 0),
            'ответ с кодом операции 2147483647, а ждали OP_MSG',
        },
    }

    for _, case in ipairs(cases) do
        t.assert_equals({ wire.read(receiver(case[1]), 7, 1000) }, { nil, { kind = 'broken', message = case[2] } })
    end
end

g.test_the_shortest_reply_has_an_empty_body = function()
    t.assert_equals({ wire.read(receiver(ints(21, 7, 7, 2013, 0) .. '\0'), 7, 1000) }, { '' })
end
