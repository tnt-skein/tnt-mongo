# tnt-mongo

Клиент MongoDB для Tarantool: свои OP_MSG, BSON и вход SCRAM-SHA-256
поверх встроенного неблокирующего сокета. Соединения живут в пуле, срок
один на вызов, отказ — пара `nil, err` с родом по коду MongoDB,
а транзакции есть у набора реплик.

```lua
local mongo = require('tnt.mongo')

local db = mongo.new({ host = 'db', username = 'app', password = secret, db = 'shop', replica_set = 'rs0' })

db:command({ 'insert', 'users', documents = { { _id = 7, name = 'Анна', age = 34 } } })
local users, err = db:query({ 'find', 'users', filter = { age = { ['$gt'] = 30 } } })   -- курсор до конца

local ok, err = db:transaction(function(tx)
    tx:command({ 'insert', 'orders', documents = { { _id = 1, user = 7 } } })
    tx:command({ 'update', 'users', updates = { { q = { _id = 7 }, u = { ['$inc'] = { orders = 1 } } } } })
end)
```

Зависимости: `tnt-must` (проверки аргументов), `tnt-hash` (HMAC
и SHA-256 входа), `tnt-log` (журнал), `tnt-pool` (соединения),
`tnt-retry` (повторы), `tnt-external` (подмена сети, часов и случайного
в проверках), `tnt-storage` (срок, отказ с родом и тип BSON значения)
и `tnt-tls` (шифрование).

## Зачем

Готового неблокирующего клиента MongoDB у Tarantool нет ни в ядре, ни
среди официальных роков, а обёртка над клиентской библиотекой на C ждала
бы сети в потоке событий и останавливала узел целиком. Пакет говорит
протоколом сам, на файберах, и закрывает места, где голый протокол
подводит молча:

- **Команда — список**, `{ 'find', 'users', filter = …, limit = 10 }`:
  таблица Lua порядка ключей не держит, а у MongoDB имя команды обязано
  стоять первым. Порядок там, где он важен (сортировка, ключ индекса), —
  `mongo.ordered`.
- **Значение уходит тем типом BSON, какой ему нужен**: `int64` —
  `int64`, `decimal` — `decimal128` с масштабом, `uuid`, `datetime`,
  двоичное; `ObjectId` из базы уходит обратно `ObjectId`, а не строкой,
  которая ничего не нашла бы.
- **Отказ — пара `nil, err` с родом** (`unreachable`, `denied`, `busy`,
  `conflict`, `timeout`, `broken`, `rejected`, `overflow`, `closed`),
  признаком отправки и приговором повтору — и отказ записи внутри ответа
  `ok: 1` тоже.
- **Подпись сервера в конце входа сверяется**: вход к подставному
  серверу, который не знает пароля, молча не пройдёт.
- **Повтор после отправки — только с `idempotent = true`**: вставка,
  оборванная после записи, не ляжет дважды.

## Установка

```sh
tt rocks install tnt-mongo --server=https://tnt-skein.github.io/rocks
```

Или из исходников:

```sh
git clone https://github.com/tnt-skein/tnt-mongo.git
cd tnt-mongo && tt rocks make
```

## Как пользоваться

| Вызов | Что делает |
|---|---|
| `mongo.new(opts)` | заводит драйвер, соединений не открывает; негодная или незнакомая настройка — исключение |
| `db:command(command, opts)` | команда; ответ сервера документом; `timeout`, `idempotent`, `db` |
| `db:query(command, opts)` | `find`, `aggregate`, `listCollections`, `listIndexes` — документы курсора до конца; ещё `max_rows` |
| `db:transaction(fn, opts)` | транзакция на одном соединении, только у набора реплик; `timeout`, `retry` |
| `db:stats()` | показатели пула без учётных данных |
| `db:close()` | закрывает пул: свободные соединения сразу, занятые — когда вернут |
| `mongo.object_id(hex)`, `mongo.ordered(…)` | опознаватель документа и документ с порядком полей |
| `mongo.timestamp`, `mongo.regex`, `mongo.binary`, `mongo.MIN_KEY`, `mongo.MAX_KEY` | прочие типы BSON без пары в Lua |

Настройки драйвера: `host`, `port` (27017), `username` и `password`
(только вместе), `auth_source` (`admin`), `db` (обязательна),
`replica_set`, `tls` (`true` либо `{ verify, ca_file, ca_path, sni }`),
`timeout` и `max_timeout` (5 и 60 с), `max_bytes`, `max_rows` (10 000),
`pool` и `retry` (как у `tnt-pool` и `tnt-retry`), `name`.

```lua
local reply, err = db:command({ 'insert', 'users', documents = { { _id = 7 } } })

if err ~= nil and err.kind == 'rejected' and err.server_code == 11000 then
    -- дубликат ключа: такой пользователь уже есть
end

local rows, err = db:query({ 'find', 'users', filter = {} }, { idempotent = true, max_rows = 100 })
```

## Проверки

```sh
make deps          # luatest, luacheck, luacov с cluacov и зависимости пакета в .rocks
make check         # форматирование, линт, проверки, покрытие с порогом 100 %
make mutants-all   # мутационное тестирование утилитой tnt-mutants из PATH, порог 100 % убитых
make mongo-up      # MongoDB 7 в докере для живых проверок; make mongo-down — погасить
```

Покрытие строк — 100 %, убитых мутантов — 100 % (165 проверок,
1610 мутантов в двенадцати модулях). Протокол проверяется двойником
сервера на настоящем сокете, который говорит OP_MSG и входит по SCRAM
сам, а восемь живых проверок идут против MongoDB 7 стенда; без поднятого
сервера они пропускаются.

## Документ

Полное описание с командой, выборкой, настройками, значениями, отказами,
сроком, повторами, транзакциями, соединениями, журналом, шифрованием,
подменой в проверках и обоснованием решений: [docs/mongo.md](docs/mongo.md).

## Лицензия

MIT.
