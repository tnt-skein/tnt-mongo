--- Проверки настроек: умолчания, шифрование, вход, пул и повторы;
--- негодная настройка — исключение на строке того, кто завёл драйвер.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local mongo, settings = helper.mongo, helper.settings

local g = t.group('tnt.mongo.settings')

g.after_each(function()
    if g.client ~= nil then
        g.client:close()
        g.client = nil
    end
end)

g.test_defaults_fill_what_is_not_given = function()
    local given = settings.check({ db = 'shop' })

    t.assert_equals(given.name, 'mongo')
    t.assert_equals(given.host, '127.0.0.1')
    t.assert_equals(given.port, 27017)
    t.assert_equals(given.where, '127.0.0.1:27017')
    t.assert_equals(given.tls, nil)
    t.assert_equals(given.username, nil)
    t.assert_equals(given.salted, nil)
    t.assert_equals(given.auth_source, 'admin')
    t.assert_equals(given.replica_set, nil)
    t.assert_equals(given.db, 'shop')
    t.assert_equals(given.max_bytes, 48000000)
    t.assert_equals(given.max_rows, 10000)
    t.assert_equals(given.limits, { timeout = 5, max_timeout = 60 })
    t.assert_equals(given.pool, { name = 'mongo' })
    t.assert_equals(given.retry, { scope = 'mongo' })
end

g.test_given_settings_win = function()
    local pool = { size = 2 }
    local retry = { attempts = 5 }
    local given = settings.check({
        name = 'orders',
        host = 'db',
        port = 27018,
        username = 'app',
        password = 'secret',
        auth_source = 'shop',
        db = 'shop',
        replica_set = 'rs0',
        timeout = 2,
        max_timeout = 30,
        max_bytes = 100,
        max_rows = 7,
        pool = pool,
        retry = retry,
    })

    t.assert_equals(given.name, 'orders')
    t.assert_equals(given.where, 'db:27018')
    t.assert_equals(given.username, 'app')
    t.assert_equals(type(given.salted), 'function')
    t.assert_equals(given.auth_source, 'shop')
    t.assert_equals(given.replica_set, 'rs0')
    t.assert_equals({ given.max_bytes, given.max_rows }, { 100, 7 })
    t.assert_equals(given.limits, { timeout = 2, max_timeout = 30 })
    t.assert_equals(given.pool, { size = 2, name = 'orders' })
    t.assert_equals(given.retry, { attempts = 5, scope = 'orders' })
    -- Своё дописано к копиям: таблицы вызывающего не тронуты.
    t.assert_equals(pool, { size = 2 })
    t.assert_equals(retry, { attempts = 5 })
end

g.test_tls_is_a_word_or_a_table = function()
    t.assert_equals(settings.check({ db = 'shop', tls = true }).tls, {})
    t.assert_equals(settings.check({ db = 'shop', tls = false }).tls, nil)
    t.assert_equals(
        settings.check({ db = 'shop', tls = { verify = false, ca_file = '/ca.pem', ca_path = '/ca', sni = 'db' } }).tls,
        { verify = false, ca_file = '/ca.pem', ca_path = '/ca', sni = 'db' }
    )
end

--- Бросок `mongo.new` на строке вызывающего.
---@param opts any
---@param message string
local function refused(opts, message)
    helper.assert_blamed({
        {
            function()
                mongo.new(opts)
            end,
            message,
        },
    })
end

g.test_wrong_settings_are_an_error_of_the_owner = function()
    refused(nil, 'настройки mongo — таблица, а не nil')
    refused({}, 'настройки mongo.db — непустая строка, а не nil')
    refused(
        { db = 'shop', pasword = 'x' },
        'настройки mongo: ключа «pasword» нет, есть auth_source, db, host, max_bytes, max_rows, max_timeout,'
            .. ' name, password, pool, port, replica_set, retry, timeout, tls, username'
    )
    refused({ db = 'shop', port = 0 }, 'настройки mongo.port — число от 1 до 65535, а не 0')
    refused(
        { db = 'shop', port = 65536 },
        'настройки mongo.port — число от 1 до 65535, а не 65536'
    )
    refused(
        { db = 'shop', max_bytes = 0 },
        'настройки mongo.max_bytes — число больше 0, а не 0'
    )
    refused({ db = 'shop', max_rows = 0 }, 'настройки mongo.max_rows — число больше 0, а не 0')
    refused(
        { db = 'shop', username = 'app' },
        'настройки mongo: username и password задаются только вместе'
    )
    refused(
        { db = 'shop', password = 'x' },
        'настройки mongo: username и password задаются только вместе'
    )
    refused(
        { db = 'shop', tls = { verfy = true } },
        'настройки mongo.tls: ключа «verfy» нет, есть ca_file, ca_path, sni, verify'
    )
    refused(
        { db = 'shop', timeout = 0 },
        'timeout — число секунд больше нуля и меньше бесконечности, а не 0'
    )
    refused(
        { db = 'shop', retry = { attempts = 0 } },
        'настройки mongo.retry: настройка attempts — целое число от 1, а пришло: 0'
    )
end

g.test_a_client_opens_nothing_and_knows_its_features = function()
    g.client = mongo.new({ db = 'shop', port = helper.closed_port() })

    t.assert_equals(g.client.features, { transaction = false })
    t.assert_equals(g.client.transaction, nil)
    t.assert_equals(g.client:stats().total, 0)
    g.client:close()

    g.client = mongo.new({ db = 'shop', replica_set = 'rs0', name = 'orders' })

    t.assert_equals(g.client.features, { transaction = true })
    t.assert_equals(type(g.client.transaction), 'function')
    t.assert_equals(g.client:stats().name, 'orders')
end
