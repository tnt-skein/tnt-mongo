--- Команда MongoDB из таблицы Lua: имя первым, поля, база.
---
--- Команда — документ, у которого первым стоит имя команды, а таблица Lua
--- порядка ключей не держит. Поэтому команда пишется списком с полями:
---
---     { 'find', 'users', filter = { age = { ['$gt'] = 30 } }, limit = 10 }
---
--- Первый элемент — имя, второй — его значение (коллекция, `1`), прочее —
--- поля; их порядок серверу безразличен. Порядок внутри поля, где он
--- важен (`sort`, ключ индекса), даёт `types.ordered`.
---
--- Команда проверяется и кодируется здесь, до сети: негодная — исключение
--- на строке того, кто звал, а не отказ после отправки. Поля, которые
--- ставит драйвер (`$db`, сеанс и транзакция), и команды, меняющие
--- соединение в пуле (вход, выход) либо транзакцию драйвера, — тоже
--- исключение: соединение после вызова достаётся другому.

local must = require('tnt.must')

local encode = require('tnt.mongo.bson.encode')
local types = require('tnt.mongo.types')

local Module = {}

--- Команды, отдающие курсор: с ними ходит `query`.
Module.CURSORS = { find = true, aggregate = true, listCollections = true, listIndexes = true }

--- Команды, которых драйвер не отправит, и почему.
local FORBIDDEN = {
    saslStart = 'вход задают настройки драйвера',
    saslContinue = 'вход задают настройки драйвера',
    authenticate = 'вход задают настройки драйвера',
    logout = 'соединение в пуле достанется другому без входа',
    commitTransaction = 'транзакцию ведёт transaction',
    abortTransaction = 'транзакцию ведёт transaction',
    endSessions = 'сеансы ведёт драйвер',
}

--- Поля, которые ставит драйвер.
---@type table<any, boolean>
local OWN = {
    ['$db'] = true,
    lsid = true,
    txnNumber = true,
    autocommit = true,
    startTransaction = true,
}

--- Дописывает поля драйвера и базу и кодирует документ.
---@param fields any[] Имя, значение, имя, значение…
---@param extra table[] Поля драйвера парами `{ имя, значение }`
---@param db string
---@param level integer Уровень вины, как у `error`, в кадрах того, кто зовёт
---@return string
local function seal(fields, extra, db, level)
    for _, field in ipairs(extra) do
        table.insert(fields, field[1])
        table.insert(fields, field[2])
    end

    table.insert(fields, '$db')
    table.insert(fields, db)

    -- Не хвостовым вызовом: уровень вины считается кадрами.
    local body = encode.encode(types.ordered(unpack(fields)), level + 1)

    return body
end

--- Проверяет команду и кодирует её с базой и полями драйвера.
---@param command table `{ имя, значение, поле = значение, … }`
---@param db string База
---@param extra table[] Поля драйвера парами `{ имя, значение }`: сеанс, транзакция
---@param level integer Уровень вины, как у `error`, в кадрах того, кто зовёт
---@return string name Имя команды
---@return string body Тело команды в BSON
function Module.command(command, db, extra, level)
    local caller = must.at(level + 1)

    caller.table(command, 'команда')

    local name = command[1]

    caller.not_empty(name, 'имя команды')

    if command[2] == nil then
        error(
            ('у команды %s нет значения: { %q, коллекция либо 1, … }'):format(
                name,
                name
            ),
            level + 1
        )
    end

    if FORBIDDEN[name] ~= nil then
        error(('команду %s драйвер не отправит: %s'):format(name, FORBIDDEN[name]), level + 1)
    end

    local fields = { name, command[2] }

    for key, item in pairs(command) do
        if OWN[key] then
            error(('поле %s ставит драйвер, а не команда'):format(key), level + 1)
        end

        if type(key) ~= 'string' and key ~= 1 and key ~= 2 then
            error(('в команде %s лишнее без имени: [%s]'):format(name, tostring(key)), level + 1)
        end

        if type(key) == 'string' then
            table.insert(fields, key)
            table.insert(fields, item)
        end
    end

    return name, seal(fields, extra, db, level + 1)
end

--- Служебная команда драйвера: поля по порядку, поля сеанса и база.
---@param db string
---@param extra table[] Поля сеанса парами `{ имя, значение }`; пусто — без сеанса
---@param ... any Имя, значение, имя, значение…
---@return string body
function Module.system(db, extra, ...)
    return seal({ ... }, extra, db, 1)
end

return Module
