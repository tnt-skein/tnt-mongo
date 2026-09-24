--- Настройки драйвера MongoDB: умолчания и проверка.
---
--- Проверяется всё и сразу, в `mongo.new`, а не там, где до настройки
--- впервые дошло дело: драйвер заводят при подъёме узла, а первую команду
--- шлют через час под нагрузкой. Негодная настройка — исключение на строке
--- того, кто завёл драйвер. Незнакомый ключ — тоже: опечатка в имени
--- (`pasword`) иначе молча оставила бы драйвер без входа.
---
--- Сроки проверяет `tnt-storage` (`within.settings`), набор ключей пула
--- и повторов — тот же, что у драйвера SQL (`tnt.storage.driver`), а их
--- границы — сами `tnt-pool` и `tnt-retry`.

local must = require('tnt.must')

local driver = require('tnt.storage.driver')
local scram = require('tnt.mongo.scram')
local within = require('tnt.storage.within')

local Module = {}

--- Узел по умолчанию: MongoDB на той же машине.
Module.DEFAULT_HOST = '127.0.0.1'

--- Порт MongoDB по умолчанию.
Module.DEFAULT_PORT = 27017

--- Предел байтов на ответ по умолчанию: предел сообщения самого сервера.
---
--- Пачка документов в ответе у MongoDB — до 16 МиБ, сообщение целиком — до
--- 48 миллионов байт (`maxMessageSizeBytes`). Предел ниже серверного
--- отказывал бы на законной пачке; кому надо меньше, опускает его.
Module.DEFAULT_MAX_BYTES = 48000000

--- Имя драйвера по умолчанию: в журнале, в пуле, в ведре повторов и
--- в описании клиента на сервере.
Module.DEFAULT_NAME = 'mongo'

--- База учётных записей по умолчанию.
Module.DEFAULT_AUTH_SOURCE = 'admin'

--- Уровень вины: строка того, кто завёл драйвер.
---
--- `check` зовёт `mongo.new` не хвостовым вызовом: уровень 2 — строка
--- в `mongo.lua`, 3 — строка вызывающего.
local OWNER = 3

--- Проверки с виной на строке того, кто завёл драйвер.
local owner = must.at(OWNER)

--- Как настройки называются в отказе.
local TITLE = 'настройки mongo'

--- Шифрование: то, что уходит в `tnt-tls`.
local TLS = { ca_file = '?not_empty', ca_path = '?not_empty', sni = '?not_empty', verify = '?boolean' }

--- Все настройки драйвера. Незнакомый ключ — отказ.
local OPTIONS = {
    auth_source = '?not_empty',
    db = 'not_empty',
    host = '?not_empty',
    max_bytes = '?integer',
    max_rows = '?integer',
    max_timeout = '?number',
    name = '?not_empty',
    password = '?not_empty',
    pool = driver.OPTIONS.pool,
    port = '?integer',
    replica_set = '?not_empty',
    retry = driver.OPTIONS.retry,
    timeout = '?number',
    tls = '?boolean|table',
    username = '?not_empty',
}

---@class TntMongoOptions
---@field host string|nil Узел; по умолчанию 127.0.0.1
---@field port integer|nil Порт; по умолчанию 27017
---@field username string|nil Учётная запись; только вместе с паролем
---@field password string|nil Пароль; только вместе с учётной записью
---@field auth_source string|nil База учётной записи; admin
---@field db string База команд по умолчанию
---@field replica_set string|nil Имя набора реплик: сверяется при входе и открывает транзакции
---@field tls boolean|TntMongoTlsSettings|nil Шифрование: true либо настройки `tnt-tls`
---@field timeout number|nil Срок вызова по умолчанию, секунд; 5
---@field max_timeout number|nil Потолок срока вызова, секунд; 60
---@field max_bytes integer|nil Предел байтов на ответ; 48 000 000
---@field max_rows integer|nil Предел документов выборки; 10 000
---@field pool table|nil Настройки пула: size, wait_timeout, idle_timeout, max_lifetime и прочие `tnt-pool`
---@field retry table|nil Настройки повторов: attempts, base, factor, jitter, max
---@field name string|nil Имя драйвера; mongo

---@class TntMongoSettings: TntMongoLinkSettings
---@field db string
---@field limits TntStorageLimits Сроки вызова
---@field max_rows integer
---@field pool table Настройки для `tnt-pool`: данные и имя драйвера
---@field retry table Настройки для `tnt-retry`: данные и ведро по имени драйвера

--- Проверяет настройки и дополняет их умолчаниями.
---@param opts TntMongoOptions
---@return TntMongoSettings
function Module.check(opts)
    owner.options(opts, TITLE, OPTIONS)

    local port = opts.port or Module.DEFAULT_PORT

    owner.between(port, TITLE .. '.port', 1, 65535)
    owner.optional.positive(opts.max_bytes, TITLE .. '.max_bytes')
    owner.optional.positive(opts.max_rows, TITLE .. '.max_rows')

    if (opts.username == nil) ~= (opts.password == nil) then
        error(('%s: username и password задаются только вместе'):format(TITLE), OWNER)
    end

    local tls = opts.tls

    if type(tls) == 'table' then
        owner.options(tls, TITLE .. '.tls', TLS)
    elseif tls == true then
        tls = {}
    else
        tls = nil
    end

    local host = opts.host or Module.DEFAULT_HOST
    local name = opts.name or Module.DEFAULT_NAME

    -- Копии: крюки пула и ведро повторов дописываются к ним, а не к тому,
    -- что дал вызывающий. Бюджет и размыкатель повторов — на драйвер.
    local pool = table.copy(opts.pool or {})
    local retry = table.copy(opts.retry or {})

    pool.name, retry.scope = name, name

    return {
        name = name,
        host = host,
        port = port,
        where = ('%s:%d'):format(host, port),
        tls = tls,
        username = opts.username,
        auth_source = opts.auth_source or Module.DEFAULT_AUTH_SOURCE,
        salted = opts.password and scram.salter(opts.password),
        replica_set = opts.replica_set,
        db = opts.db,
        max_bytes = opts.max_bytes or Module.DEFAULT_MAX_BYTES,
        max_rows = opts.max_rows or driver.DEFAULT_MAX_ROWS,
        limits = within.settings(opts.timeout, opts.max_timeout, OWNER),
        pool = pool,
        retry = retry,
    }
end

return Module
