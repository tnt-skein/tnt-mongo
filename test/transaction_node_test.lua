--- Проверка на временном узле с настоящим `box`: транзакция box видна
--- транзакции MongoDB.
---
--- В процессе проверок `box` не настроен, и транзакций там не бывает, а само
--- обращение к `box.is_in_txn` до `box.cfg` роняет процесс. Что умолчание
--- внешней зависимости видит транзакцию box, показывает только узел.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.mongo.transaction.node')

g.before_all(function()
    g.server = helper.start_node()
end)

g.after_all(function()
    helper.stop_node(g.server)
end)

g.test_a_transaction_inside_a_box_transaction_is_raised = function()
    local raised = g.server:exec(function()
        local db = require('tnt.mongo').new({ db = 'shop', replica_set = 'rs0' })
        -- У набора реплик метод есть всегда.
        local transact = db.transaction --[[@as fun(client: any, fn: function, opts: table): any, any]]

        box.begin()

        -- Срок короткий: без броска вызов ушёл бы в сеть к пустому порту.
        local ok, err = pcall(function()
            return transact(db, function() end, { timeout = 0.1 })
        end)

        box.rollback()
        db:close()

        return { ok, tostring(err) }
    end)

    t.assert_equals(raised[1], false)
    t.assert_str_contains(
        raised[2],
        'transaction внутри транзакции box: ожидание сети оборвёт её'
    )
end
