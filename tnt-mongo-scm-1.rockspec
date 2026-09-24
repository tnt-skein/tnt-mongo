rockspec_format = '3.0'

package = 'tnt-mongo'
version = 'scm-1'

source = {
    url = 'git+https://github.com/tnt-skein/tnt-mongo.git',
    branch = 'main',
}

description = {
    summary = 'Клиент MongoDB для Tarantool: OP_MSG и BSON на неблокирующем сокете, пул, срок, повторы, отказ парой',
    detailed = [[
        Готового неблокирующего клиента MongoDB у Tarantool нет ни в ядре,
        ни среди официальных роков, а обёртки над клиентской библиотекой
        MongoDB на C ждут сети в потоке событий и останавливают узел
        целиком. Пакет говорит протоколом сам, поверх встроенного
        неблокирующего сокета: OP_MSG, BSON и вход SCRAM-SHA-256
        со сверкой подписи сервера.

        db:command шлёт команду — список { имя, значение, поле = … } —
        и отдаёт ответ сервера документом; db:query читает курсор до конца
        с пределом max_rows и закрывает его на сервере, если документов
        больше. Значение уходит тем типом BSON, который ему нужен: int64,
        decimal128 с масштабом, uuid, datetime, двоичное; ObjectId,
        документ с порядком полей и прочие типы без пары в Lua даёт сам
        пакет.

        Соединения живут в пуле с проверкой живости без сети, срок один
        на вызов, отказ — пара nil, err с родом по коду MongoDB, признаком
        отправки и приговором повтору. Повторяет вызов tnt-retry, после
        отправки — только с согласия вызывающего. Транзакции — у набора
        реплик (replica_set): одно соединение, фиксация по итогу тела
        и повтор всей транзакции после конфликта.

        Зависит от tnt-must (проверки аргументов), tnt-hash (HMAC и SHA-256
        входа), tnt-log (журнал), tnt-pool (соединения), tnt-retry
        (повторы), tnt-external (подмена сети, шифрования, часов,
        случайного и транзакции box в проверках), tnt-storage (срок, отказ
        с родом и тип BSON значения) и tnt-tls (шифрование). Покрытие строк
        и убитых мутантов — 100 %.
    ]],
    homepage = 'https://github.com/tnt-skein/tnt-mongo',
    issues_url = 'https://github.com/tnt-skein/tnt-mongo/issues',
    maintainer = 'tnt-skein',
    license = 'MIT',
    labels = { 'tarantool', 'mongodb', 'bson', 'database', 'driver', 'scram' },
}

dependencies = {
    'lua >= 5.1',
    -- Проверки настроек, команды и значений на строке вызывающего.
    'tnt-must',
    -- HMAC и SHA-256 входа SCRAM и сверка подписи сервера.
    'tnt-hash',
    -- Запись о выброшенном соединении.
    'tnt-log',
    -- Соединения с проверкой живости без сети.
    'tnt-pool',
    -- Повторы вызова и транзакции по полю retriable отказа.
    'tnt-retry',
    -- Подмена сети, шифрования, часов, случайного и транзакции box в проверках.
    'tnt-external',
    -- Срок вызова, отказ с родом по коду MongoDB и тип BSON значения.
    'tnt-storage',
    -- Шифрование соединения с сервером.
    'tnt-tls',
}

build = {
    type = 'builtin',
    modules = {
        ['tnt.mongo'] = 'tnt/mongo.lua',
        ['tnt.mongo.bson.decode'] = 'tnt/mongo/bson/decode.lua',
        ['tnt.mongo.bson.encode'] = 'tnt/mongo/bson/encode.lua',
        ['tnt.mongo.decimal128'] = 'tnt/mongo/decimal128.lua',
        ['tnt.mongo.link'] = 'tnt/mongo/link.lua',
        ['tnt.mongo.operation'] = 'tnt/mongo/operation.lua',
        ['tnt.mongo.request'] = 'tnt/mongo/request.lua',
        ['tnt.mongo.scram'] = 'tnt/mongo/scram.lua',
        ['tnt.mongo.settings'] = 'tnt/mongo/settings.lua',
        ['tnt.mongo.transaction'] = 'tnt/mongo/transaction.lua',
        ['tnt.mongo.types'] = 'tnt/mongo/types.lua',
        ['tnt.mongo.wire'] = 'tnt/mongo/wire.lua',
    },
}
