--- Проверки SCRAM-SHA-256: вектор RFC 7677, имя с запятой, ответы
--- подставного сервера и растягивание пароля.

local digest = require('digest')
local t = require('luatest')

local helper = dofile('test/helper.lua')

local scram = helper.scram

local g = t.group('tnt.mongo.scram')

g.after_each(function()
    helper.restore()
end)

--- Случайное клиента из RFC 7677 и уступки, которые считаются.
---@return table yields Счётчик уступок
local function rfc()
    local yields = { count = 0 }

    scram._set_source({
        nonce = function()
            return 'rOprNGfwEbeRWgbNEkqO'
        end,
        yield = function()
            yields.count = yields.count + 1
        end,
    })

    return yields
end

--- Первое сообщение сервера из RFC 7677.
local SERVER_FIRST = 'r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096'

g.test_the_rfc_7677_conversation_goes = function()
    local yields = rfc()
    local state, first = scram.first('user')

    t.assert_equals(scram.MECHANISM, 'SCRAM-SHA-256')
    t.assert_equals(first, 'n,,n=user,r=rOprNGfwEbeRWgbNEkqO')
    t.assert_equals({ scram.final(state, SERVER_FIRST, scram.salter('pencil')) }, {
        'c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=',
    })
    t.assert_equals({ scram.verify(state, 'v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=') }, { true })
    -- 4096 проходов — уступки на 1000-м, 2000-м, 3000-м и 4000-м.
    t.assert_equals(yields.count, 4)
end

g.test_a_name_escapes_comma_and_equals = function()
    rfc()

    local _, first = scram.first('we,ird=name')

    t.assert_equals(first, 'n,,n=we=2Cird=3Dname,r=rOprNGfwEbeRWgbNEkqO')
end

g.test_the_real_nonce_is_random_base64 = function()
    local _, first = scram.first('user')
    local _, second = scram.first('user')
    local nonce = first:match('r=(.*)$')

    t.assert_equals(#nonce, 32)
    t.assert_equals(#digest.base64_decode(nonce), 24)
    t.assert_not_equals(first, second)
end

g.test_a_foreign_server_first_is_refused = function()
    rfc()

    local salted = scram.salter('pencil')
    local refused =
        'ответ сервера на вход не по SCRAM либо не на наше случайное: '
    local replies = {
        -- Чужое случайное и наше без продолжения.
        'r=someone-else,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096',
        'r=rOprNGfwEbeRWgbNEkqO,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096',
        -- Нет соли, нет проходов, лишнее в конце, отказ вместо ответа.
        'r=rOprNGfwEbeRWgbNEkqOxyz,s=,i=4096',
        'r=rOprNGfwEbeRWgbNEkqOxyz,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=',
        'r=rOprNGfwEbeRWgbNEkqOxyz,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096x',
        'e=other-error',
    }

    for _, reply in ipairs(replies) do
        local state = scram.first('user')

        t.assert_equals({ scram.final(state, reply, salted) }, { nil, refused .. reply })
    end

    local low = scram.first('user')

    t.assert_equals(
        { scram.final(low, 'r=rOprNGfwEbeRWgbNEkqOxyz,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4095', salted) },
        { nil, 'сервер назначил 4095 проходов, а меньше 4096 не бывает' }
    )

    -- Ровно 4096 — годится.
    local state = scram.first('user')

    t.assert_not_equals(scram.final(state, 'r=rOprNGfwEbeRWgbNEkqOxyz,s=c2FsdA==,i=4096', salted), nil)
end

g.test_a_nonce_with_pattern_signs_is_matched_as_it_is = function()
    scram._set_source({
        nonce = function()
            return 'a+b/c='
        end,
        yield = function() end,
    })

    local salted = scram.salter('pencil')
    local state = scram.first('user')

    t.assert_not_equals(scram.final(state, 'r=a+b/c=xyz,s=c2FsdA==,i=4096', salted), nil)
    -- `+` — знак, а не «одно и больше»: `aab/c=` — чужое случайное.
    t.assert_equals(scram.final(scram.first('user'), 'r=aab/c=xyz,s=c2FsdA==,i=4096', salted), nil)
end

g.test_a_server_signature_must_match = function()
    rfc()

    local state = scram.first('user')

    scram.final(state, SERVER_FIRST, scram.salter('pencil'))

    local mismatch = { nil, 'подпись сервера не сошлась: он не знает пароля' }

    t.assert_equals({ scram.verify(state, 'v=AAAATRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=') }, mismatch)
    t.assert_equals({ scram.verify(state, 'x=1') }, mismatch)
    t.assert_equals({ scram.verify(state, 'v=') }, mismatch)
    t.assert_equals(
        { scram.verify(state, 'e=invalid-proof') },
        { nil, 'сервер отказал во входе: invalid-proof' }
    )
    -- Расширения после подписи не мешают ей сойтись.
    t.assert_equals({ scram.verify(state, 'v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=,x=y') }, { true })
end

g.test_pbkdf2_is_rfc_6070_like_and_nul_safe = function()
    rfc()

    -- Вектор PBKDF2-HMAC-SHA256 (RFC 7914, раздел 11): passwd, salt, 1.
    t.assert_equals(
        scram.pbkdf2('passwd', 'salt', 1):hex(),
        '55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc'
    )
    -- Нулевой байт в соли — законный байт, а не конец строки.
    t.assert_equals(scram.pbkdf2('passwd', 'salt', 2), digest.pbkdf2('passwd', 'salt', 2, 32))
    t.assert_not_equals(scram.pbkdf2('passwd', 'sa\0lt', 2), digest.pbkdf2('passwd', 'sa\0lt', 2, 32))
    t.assert_equals(digest.pbkdf2('passwd', 'sa\0lt', 2, 32), digest.pbkdf2('passwd', 'sa', 2, 32))
end

g.test_pbkdf2_yields_every_thousand_rounds = function()
    local yields = rfc()

    scram.pbkdf2('p', 's', 999)
    t.assert_equals(yields.count, 0)

    scram.pbkdf2('p', 's', 1000)
    t.assert_equals(yields.count, 1)

    scram.pbkdf2('p', 's', 1999)
    t.assert_equals(yields.count, 2)

    scram.pbkdf2('p', 's', 2000)
    t.assert_equals(yields.count, 4)
end

g.test_the_salted_password_is_remembered_per_salt = function()
    local yields = rfc()
    local salted = scram.salter('pencil')
    local first = salted('salt', 4096)

    t.assert_equals(yields.count, 4)
    t.assert_equals(salted('salt', 4096), first)
    t.assert_equals(yields.count, 4)
    t.assert_equals(salted('other', 4096) == first, false)
    t.assert_equals(yields.count, 8)
    t.assert_equals(salted('other', 5000) == salted('other', 4096), false)
    t.assert_equals(yields.count, 17)
    t.assert_equals(salted('salt', 4096), first)
end
