# MongoDB

`tnt-mongo` — клиент MongoDB для Tarantool: OP_MSG, BSON и вход
SCRAM-SHA-256 поверх встроенного неблокирующего сокета. Соединения живут
в пуле, срок один на вызов, отказ — пара `nil, err` с родом по коду
MongoDB, а транзакции есть у набора реплик.

```lua
local mongo = require('tnt.mongo')

local db = mongo.new({ host = 'db', username = 'app', password = secret, db = 'shop' })

local reply, err = db:command({ 'insert', 'users', documents = { { _id = 7, name = 'Анна' } } })
local users, err = db:query({ 'find', 'users', filter = { name = 'Анна' } })
```

Отказ — пара `nil, err`, где `err` — отказ `tnt-storage` с родом,
признаком отправки и приговором повтору. Исключение — ошибка
программиста: негодная команда или значение, незнакомая настройка.

Зависимости: [`tnt-must`](https://github.com/tnt-skein/tnt-must)
(проверки аргументов), [`tnt-hash`](https://github.com/tnt-skein/tnt-hash)
(HMAC и SHA-256 входа), [`tnt-log`](https://github.com/tnt-skein/tnt-log)
(журнал), [`tnt-pool`](https://github.com/tnt-skein/tnt-pool)
(соединения), [`tnt-retry`](https://github.com/tnt-skein/tnt-retry)
(повторы), [`tnt-external`](https://github.com/tnt-skein/tnt-external)
(подмена сети, часов и случайного в проверках),
[`tnt-storage`](https://github.com/tnt-skein/tnt-storage) (срок, отказ
с родом и тип BSON значения) и [`tnt-tls`](https://github.com/tnt-skein/tnt-tls)
(шифрование).

## Зачем пакет

Готового неблокирующего клиента MongoDB у Tarantool нет: ни модуля ядра,
ни рока среди официальных (`tt rocks search mongo` пуст). Обёртка над
клиентской библиотекой MongoDB на C ждала бы сети в потоке событий
и останавливала узел целиком, а не один запрос. Поэтому протокол свой —
OP_MSG и BSON поверх встроенного сокета, неблокирующего и живущего
с файберами, вход SCRAM-SHA-256, — а всё остальное взято готовым:

- пул — [`tnt-pool`](https://github.com/tnt-skein/tnt-pool/blob/main/docs/pool.md),
  который драйвер заводит сам, с проверкой живости без сети;
- отказ, срок и кодирование значений —
  [`tnt-storage`](https://github.com/tnt-skein/tnt-storage/blob/main/docs/storage.md):
  отказ `TntStorageFailure` с родом по коду MongoDB, один миг срока
  на вызов, диалект `mongo` у `value.wire` — какой тип BSON у `int64`,
  времени и точного числа;
- повторы — [`tnt-retry`](https://github.com/tnt-skein/tnt-retry/blob/main/docs/retry.md)
  по полю `retriable` отказа;
- шифрование — [`tnt-tls`](https://github.com/tnt-skein/tnt-tls/blob/main/docs/tls.md);
- HMAC и SHA-256 входа — [`tnt-hash`](https://github.com/tnt-skein/tnt-hash/blob/main/docs/hash.md).

| Слой | Модуль | Что делает |
|---|---|---|
| значения | `tnt.mongo.types`, `tnt.mongo.decimal128` | `ObjectId`, документ с порядком полей, отметка оплога, образец, двоичное с видом, крайние ключи; `decimal` в `decimal128` и обратно |
| BSON | `tnt.mongo.bson.encode`, `tnt.mongo.bson.decode` | документ Lua в байты и обратно, каждый тип и каждая поломка записи |
| рамка | `tnt.mongo.wire` | сообщение OP_MSG и сверка рамки ответа |
| вход | `tnt.mongo.scram` | SCRAM-SHA-256: доказательство клиента, подпись сервера, растягивание пароля |
| команда | `tnt.mongo.request` | команда списком, поля драйвера, запреты — до сети |
| связь | `tnt.mongo.link` | сокет и TLS, `hello`, вход, обмен в срок, живость без сети |
| операция | `tnt.mongo.operation` | команда и выборка курсором на взятом соединении, отказ сервера по коду |
| драйвер | `tnt.mongo.settings`, `tnt.mongo.transaction`, `tnt.mongo` | настройки, транзакция на одном соединении, пул, срок и повторы |

Чего здесь нет:

- **Топологии** — драйвер ходит к одному узлу. Набор реплик — адресом
  ведущего; смена ведущего — отказ `busy` и выброс соединения, но нового
  ведущего драйвер не ищет. Чтения с реплик (`readPreference`) нет.
- **Повторяемых записей** (`retryWrites`) и **причинной согласованности**
  (`$clusterTime`, `afterClusterTime`).
- **Сжатия** (OP_COMPRESSED) — о нём драйвер не договаривается.
- **Адреса строкой** (`mongodb://…`, `mongodb+srv://…`) — только `host`
  и `port`.
- **Входа, кроме SCRAM-SHA-256**: ни SCRAM-SHA-1, ни x.509, ни LDAP,
  ни Kerberos. SASLprep пароля нет: пароль уходит байтами как есть.
- **Сервера старше 5.0**: вход начинается командой `hello`.

## Как пользоваться

Примеры в этом документе прогнаны на MongoDB 7 стенда (`make mongo-up`,
`test/stand/mongo.sh`); вывод — как напечатал прогон.

### Драйвер: `mongo.new`

```lua
local mongo = require('tnt.mongo')

local db = mongo.new({
    host = '127.0.0.1',
    port = 37017,
    username = 'app',
    password = 'app-secret',
    db = 'tnt_live',           -- база команд по умолчанию
    replica_set = 'rs0',       -- набор реплик: сверяется при входе, даёт транзакции
    timeout = 2,               -- срок вызова по умолчанию
    pool = { size = 4 },
})

db:command({ 'insert', 'users', documents = { { _id = 7, name = 'Анна', age = 34 }, { _id = 8, name = 'Борис', age = 29 } } }).n
--> 2
local users = db:query({ 'find', 'users', filter = { age = { ['$gt'] = 30 } } })
--> #users == 1, users[1].name == 'Анна'
db:query({ 'find', 'users', filter = {}, sort = mongo.ordered('age', -1, 'name', 1), projection = { name = 1 } })
--> Анна, затем Борис
db:command({ 'update', 'users', updates = { { q = { _id = 8 }, u = { ['$set'] = { age = 30 } } } } })
--> { n = 1, nModified = 1, ok = 1, … }
db:query({ 'aggregate', 'users', pipeline = { { ['$group'] = { _id = box.NULL, total = { ['$sum'] = '$age' } } } }, cursor = {} })
--> { { _id = box.NULL, total = 64 } }
db:command({ 'insert', 'users', documents = { { _id = 7, name = 'Вера' } } })
--> nil, запись 0 отвергнута: E11000 duplicate key error collection: tnt_live.users index: _id_ dup key: { _id: 7 }
--      (kind = rejected, sent = true, retriable = false, server_code = 11000)

db:close()
--> true
```

Соединение открывается первым вызовом, а не в `mongo.new`: драйвер заводят
при подъёме узла, когда ходить к чужой службе рано.

- `db:command(command, opts)` — команда; ответ — документ сервера как есть
  (`ok`, `n`, `nModified`, `cursor` и прочее). Отказ — `nil, err`.
- `db:query(command, opts)` — выборка: команда, отдающая курсор (`find`,
  `aggregate`, `listCollections`, `listIndexes`), и её документы до конца
  курсора, массивом. Иная команда — исключение.
- `opts` у обоих — `{ timeout, idempotent, db }`, у `query` ещё
  `max_rows`: срок вызова, согласие на повтор после отправки (ниже,
  «Повторы»), база вместо `db` драйвера, предел документов.
- `db:transaction(fn, opts)` — транзакция; есть только у набора реплик
  (ниже, «Транзакции»).
- `db:close()` — закрыть драйвер; `db:stats()` — показатели пула без
  учётных данных; `db.features.transaction` — есть ли транзакции;
  `db.name` — имя драйвера.

### Команда

Команда MongoDB — документ, у которого первым стоит имя команды, а таблица
Lua порядка ключей не держит. Поэтому команда пишется списком с полями:
первый элемент — имя, второй — его значение (коллекция, `1`), прочее —
поля; их порядок серверу безразличен. База (`$db`) — `opts.db`, иначе `db`
драйвера.

```lua
{ 'find', 'users', filter = { age = { ['$gt'] = 30 } }, limit = 10 }
{ 'createIndexes', 'users', indexes = { { key = mongo.ordered('age', 1, 'name', 1), name = 'age_name' } } }
{ 'ping', 1 }
```

Порядок внутри поля, где он важен, — сортировка и ключ индекса, —
даёт `mongo.ordered(имя, значение, имя, значение…)`: `{ age = -1, name = 1 }`
у таблицы Lua порядка не имеет, и индекс вышел бы не тем.

Команда проверяется и кодируется до сети: негодная — исключение на строке
вызывающего. Поля, которые ставит драйвер (`$db`, `lsid`, `txnNumber`,
`autocommit`, `startTransaction`), и команды, меняющие соединение в пуле
либо транзакцию драйвера (`saslStart`, `saslContinue`, `authenticate`,
`logout`, `commitTransaction`, `abortTransaction`, `endSessions`), — тоже
исключение: соединение после вызова достаётся другому.

```lua
db:query({ 'count', 'users' })
--> исключение: query ходит с командами курсора (find, aggregate, listCollections, listIndexes), а не count
db:command({ 'commitTransaction', 1 })
--> исключение: команду commitTransaction драйвер не отправит: транзакцию ведёт transaction
db:command({ 'find', 'users', lsid = {} })
--> исключение: поле lsid ставит драйвер, а не команда
```

### Выборка

`query` читает курсор до конца: первая пачка — в ответе на команду,
следующие — `getMore` на том же соединении и в тот же срок. Документов
больше `max_rows` (умолчание 10 000 — то же, что у драйвера SQL над роком
из `tnt-storage`) — отказ `overflow`, и курсор закрывается на сервере
сразу (`killCursors`), а не по сроку простоя. Выборка — массив и тогда,
когда пуста: `json.encode` пишет её `[]`.

```lua
db:query({ 'find', 'users', filter = {}, batchSize = 1 }, { max_rows = 1 })
--> nil, документов больше max_rows 1    (kind = overflow, sent = true, retriable = false)
```

Большие выборки читают постранично по ключу
(`filter = { _id = { ['$gt'] = last } }`, `limit`): каждая страница —
свой вызов со своим пределом, и курсор не живёт между вызовами. Курсор,
открытый `command({ 'find', … })`, драйвер не читает: номер курсора —
в ответе, и `getMore` к нему пишет тот, кто его открыл.

### Настройки

| Ключ | Что | По умолчанию |
|---|---|---|
| `host`, `port` | узел | `127.0.0.1`, `27017` |
| `username`, `password` | вход SCRAM-SHA-256; только вместе | без входа |
| `auth_source` | база учётной записи | `admin` |
| `db` | база команд; обязательна | — |
| `replica_set` | имя набора реплик: узел обязан назвать его в `hello`; открывает транзакции | одиночный узел |
| `tls` | `true` либо `{ verify, ca_file, ca_path, sni }` для `tnt-tls` | открытый текст |
| `timeout`, `max_timeout` | срок вызова и его потолок, секунд | `5`, `60` |
| `max_bytes` | предел байтов на один ответ | 48 000 000 (`maxMessageSizeBytes` сервера) |
| `max_rows` | предел документов выборки | 10 000 |
| `pool` | `size`, `wait_timeout`, `idle_timeout`, `max_lifetime`, `open_cooldown`, `leak_timeout`, `sweep_interval` — как у `tnt-pool` | умолчания `tnt-pool` |
| `retry` | `attempts`, `base`, `factor`, `jitter`, `max` — как у `tnt-retry` | умолчания `tnt-retry` |
| `name` | имя в журнале, пуле, ведре повторов и в описании клиента на сервере | `mongo` |

Проверяется всё сразу в `mongo.new`, и негодное — исключение на строке
того, кто завёл драйвер: опечатка `pasword` иначе молча оставила бы драйвер
без входа.

```lua
mongo.new({ db = 'x', pasword = 'x' })
--> app.lua:1: настройки mongo: ключа «pasword» нет, есть auth_source, db, host, max_bytes,
--  max_rows, max_timeout, name, password, pool, port, replica_set, retry, timeout, tls, username
mongo.new({ db = 'x', username = 'app' })
--> app.lua:1: настройки mongo: username и password задаются только вместе
db:command({ 'ping', 1 }, { timout = 1 })
--> настройки вызова: ключа «timout» нет, есть db, idempotent, timeout
```

### Значения

Значение уходит тем типом BSON, который назвал `tnt-storage`
(`value.wire('mongo', v)`): правило «чем передать `int64`, время и точное
число» одно на все драйверы, что стоят на `tnt-storage`.

| Lua | BSON | Обратно |
|---|---|---|
| строка | `string` | строка |
| логика | `bool` | логика |
| целое до ±2³¹ | `int32` | число |
| целое до ±2⁵³ | `int64` | число |
| дробное | `double` | число |
| целое за ±2⁵³, NaN, бесконечность | исключение | — |
| `int64`, `uint64` до 2⁶³−1 | `int64` | число, пока оно не дальше ±2⁵³; дальше — `int64` |
| `uint64` выше 2⁶³−1 | исключение: беззнакового целого в BSON нет | — |
| `decimal` | `decimal128`, масштаб сохраняется (`1.10` — не `1.1`) | `decimal`; длиннее 34 знаков — исключение |
| `uuid` | `binary` вида 4 | `uuid` |
| `datetime` | `date`: миллисекунды в UTC, остаток отбрасывается вниз | `datetime` в UTC |
| `storage.binary(s)`, `varbinary` | `binary` вида 0 | `varbinary` |
| `storage.json(v)` | `string` с текстом JSON | строка |
| `box.NULL` | `null` | `box.NULL` |
| таблица с ключами `1..n` либо `__serialize = 'seq'` | `array` | таблица с `__serialize = 'seq'` |
| прочая таблица | документ: ключи — строки без нулевого байта | таблица с `__serialize = 'map'` |
| `mongo.object_id()` | `objectId` | он же |
| `mongo.ordered(…)` | документ с порядком полей | таблица без порядка |
| `mongo.timestamp(t, i)`, `mongo.regex(p, f)`, `mongo.binary(s, вид)`, `mongo.MIN_KEY`, `mongo.MAX_KEY` | свои типы | они же |
| функция, иной cdata, таблица с чужой метатаблицей без `__serialize` | исключение | — |

```lua
local id = mongo.object_id()
db:command({ 'insert', 'orders', documents = { {
    _id = id,
    price = decimal.new('1.10'),
    wide = 9007199254740993LL,
    at = datetime.new({ year = 2026, month = 9, day = 19, hour = 12, min = 34, sec = 56, nsec = 789123456 }),
    doc = storage.json({ a = 1 }),
    bytes = storage.binary('\0\255'),
    empty = box.NULL,
    tags = setmetatable({}, { __serialize = 'seq' }),
} } })
local order = db:query({ 'find', 'orders', filter = { _id = id } })[1]
--> order._id == id, tostring(order.price) == '1.10', order.wide == 9007199254740993LL,
--  tostring(order.at) == '2026-09-19T12:34:56.789Z', order.doc == '{"a":1}',
--  varbinary.is(order.bytes), rawequal(order.empty, box.NULL), пустой order.tags — 'seq'
```

- **Пустая таблица — документ**: пустой фильтр `{}` MongoDB понимает как
  «всё». Пустой массив пишут `setmetatable({}, { __serialize = 'seq' })`,
  как для `json.encode`: `args = {}` у `$function` ушёл бы документом,
  и сервер отказал бы.
- **`nil` посреди массива — исключение**, пустое пишут `box.NULL`. Таблица
  и с номерами, и с именами — тоже исключение: BSON её не выразит.
- **`null` и отсутствие — разное**: `box.NULL` в документе остаётся полем,
  и `$exists` его находит. `box.NULL == nil` в Lua верно, а в `if` — нет.
- **Опознаватель — `ObjectId`, а не строка**: строка `'650f…'` в фильтре
  по `_id` не нашла бы ничего. Прочитанный опознаватель уходит обратно тем
  же типом; `tostring` отдаёт шестнадцатеричную запись, а
  `mongo.object_id(hex)` собирает опознаватель из неё.
- **Время — миллисекунды**: у типа `date` точность такая, и микросекунды
  отбрасываются, как отбрасывает их сервер у всякого клиента.
- **Целое `int64` из базы — число**, пока точно: как у msgpack самого
  Tarantool. Записанное обратно оно уйдёт `int32`, если помещается, —
  поиск по значению это не меняет, `$type` — меняет.
- **Флаги образца** `mongo.regex` хранятся по алфавиту: так их хранит
  и сравнивает сервер.
- **Чтение не выражает старых типов** — код JavaScript, символ, DBPointer —
  и `decimal128` NaN или бесконечность: отказ `rejected` всего ответа,
  соединение цело. Дата за пределами `datetime` — тоже.

### Отказ

Отказ — пара `nil, err`, где `err` — `TntStorageFailure`
([`tnt-storage`](https://github.com/tnt-skein/tnt-storage/blob/main/docs/storage.md),
«Отказ»): строкой, в JSON и в журнале — текст, а поля говорят, что делать.

| Где | Род | `sent` | `retriable` | Соединение |
|---|---|---|---|---|
| соединение не открылось, вход не уложился в срок, TLS не прошёл, `hello` отвергнут | `unreachable` | нет | да | не открыто |
| вход отвергнут: пароль (18), нет учётки (11), нет прав (13), способа входа нет (334); узел не из `replica_set`; подпись сервера не сошлась либо её нет | `denied` | нет | нет | закрыто |
| соединения из пула за срок не досталось | `busy` | нет | да | — |
| узел не ведущий: `NotWritablePrimary` (10107), 13435, 13436 | `busy` | нет | да | выброшено |
| нет прав на команду: `Unauthorized` (13) | `denied` | нет | нет | в пул |
| конфликт записи (112), блокировка (24), транзакция снята (251), метка `TransientTransactionError` | `conflict` | да | нет | в пул |
| срок сервера: `maxTimeMS` (50), 262; подтверждение реплик не дождались (64) | `timeout` | да | с `idempotent` | в пул |
| сервер останавливается или сменил ведущего посреди операции (91, 189, 11600, 11602), сеть между узлами (6, 7, 89, 9001) | `broken` | да | с `idempotent` | в пул |
| прочий отказ сервера: дубликат ключа (11000), негодное значение, нет коллекции | `rejected` | да | нет | в пул |
| ответа нет за срок вызова | `timeout` | да | с `idempotent` | выброшено |
| связь оборвалась посреди ответа, ответ не по протоколу, BSON противоречит себе | `broken` | да | с `idempotent` | выброшено |
| команда не записалась целиком | `broken` | нет | да | выброшено |
| ответ длиннее `max_bytes` | `overflow` | да | нет | выброшено |
| документов больше `max_rows` | `overflow` | да | нет | в пул, курсор закрыт |
| тип BSON, которого Tarantool не выразит | `rejected` | да | нет | в пул |
| драйвер закрыт | `closed` | нет | нет | — |

Отказ сервера бывает трёх видов, и все три — отказ вызова: `ok: 0`;
`writeErrors` при `ok: 1` — часть записей отвергнута, а прочие, может быть,
записаны (отказ называет первую); `writeConcernError` — записано на
ведущем, но подтверждения реплик не дождались. Род решает число кода
(`server_code`): имени кода у отказа записи внутри ответа нет. Перечень
кодов — в `tnt-storage` (`codes.mongo`), один на все драйверы; числа у
MongoDB свои, и таблица у них своя, а не общая с errno.

В журнальную причину (`reason`) идут имя и код, а не текст: у дубликата
ключа текст несёт само значение ключа, а значения в журнал не пишутся.

```lua
mongo.new({ port = 37017, db = 'tnt_live', username = 'app', password = 'wrong' }):command({ 'ping', 1 })
--> nil, mongo 127.0.0.1:37017: вход не удался: Authentication failed.
--      (kind = denied, sent = false, retriable = false, server_code = 18)
mongo.new({ port = 37017, db = 'tnt_live', username = 'reader', password = 'reader-secret' })
    :command({ 'insert', 'users', documents = { {} } })
--> nil, not authorized on tnt_live to execute command { insert: "users", documents: [ {} ], $db: "tnt_live" }
--      (kind = denied, sent = false, retriable = false, server_code = 13)
--      reason = 'сервер отказал: Unauthorized, код 13'
mongo.new({ port = 1, db = 'x', timeout = 0.3, pool = { wait_timeout = 0.1 } }):command({ 'ping', 1 })
--> nil, mongo 127.0.0.1:1: соединение не получено за 0.1 с: открыть соединение не удалось:
--      mongo 127.0.0.1:1: соединение не открылось: Connection refused
--      (kind = unreachable, sent = false, retriable = true, server_code = nil)
db:query({ 'find', 'users', filter = slow }, { timeout = 0.2 })
--> nil, mongo 127.0.0.1:37017: ответа нет за срок вызова    (kind = timeout, sent = true, retriable = false)
db:query({ 'find', 'users', filter = slow, maxTimeMS = 100 })
--> nil, Executor error during find command :: caused by :: operation exceeded time limit
--      (kind = timeout, sent = true, retriable = false, server_code = 50)
db:close()
db:close()
--> false, mongo: драйвер уже закрыт    (kind = closed)
db:command({ 'ping', 1 })
--> nil, mongo: драйвер закрыт    (kind = closed)
```

Здесь `slow` — фильтр `$expr` с `$function`, спящим секунду на документ.
Первый `$function` свежий сервер заводит движком JavaScript, и срок,
вышедший посреди заводки, он называет не `MaxTimeMSExpired` (50),
а `Interrupted` (11601) — отказ `rejected`: тем же кодом сервер отвечает
на `killOp`, и повторять такое драйвер не берётся.

Исключение — только ошибка программиста: негодная команда или значение,
незнакомый ключ настроек, срок ноль, бесконечность или длиннее потолка,
команды и поля, которые ставит драйвер.

В HTTP отказ сам не переходит: у него нет `status`, и код ответа выбирает
тот, кто отказ отдаёт наружу. Род подсказывает: `unreachable`, `busy`,
`timeout` и `broken` — служба недоступна сейчас, остальное — нет.

### Срок

Один миг на вызов — `clock.monotonic() + timeout` на входе, — и перед
каждым ожиданием остаток считается заново от времени планировщика:
ожидание пула (не дольше `pool.wait_timeout`), вход, запись, ответ,
каждая пачка курсора, пауза повтора. Срок вызова — `opts.timeout`,
иначе `timeout` драйвера.

Встроенный сокет срок принимает сам, поэтому работник в отдельном файбере
не нужен: чтение, не дождавшееся ответа, возвращает управление,
и соединение выбрасывается — в нём остался недочитанный ответ. Срок,
вышедший в ожидании пула, — `timeout` с `sent = false`, и соединение
возвращается: команда не ушла, сокет чист.

**Брошенная операция дорабатывает на сервере**: закрытие сокета её не
останавливает. Потолок ставит сама команда — `maxTimeMS` в её полях
(`{ 'find', 'users', filter = …, maxTimeMS = 1500 }`); драйвер его не
дописывает — `getMore` обычного курсора, например, его не принимает.

### Повторы

Весь вызов идёт под `tnt-retry` со своим экземпляром на драйвер
(`scope` — имя драйвера), и повторяет он по полю `retriable` отказа:

- **до отправки — всегда**: соединение не открылось, пул занят, узел
  не ведущий, команда не записалась целиком;
- **после отправки — только с `idempotent = true`**: `timeout` и `broken`.
  Вставка, оборванная после записи, могла пройти, и повтор вставил бы
  дважды — или отказал бы дубликатом `_id`;
- **никогда**: `rejected`, `denied`, `conflict` оператора, `overflow`,
  `closed`.

`find` тоже не повторяется без согласия: драйвер не разбирает, пишет ли
команда, — `aggregate` с `$out` или `$merge` пишет, — и правило одно для
всех. Кто знает, что команда только читает, ставит `idempotent = true`.
Срок, вышедший до очередной попытки, отдаёт отказ прошлой попытки без
повтора. Повтор пишется в журнал `debug` самим `tnt-retry`.

Повторяемых записей MongoDB (`retryWrites` с номером транзакции у каждой
записи) драйвер не ведёт: без них запись, оборванная после отправки,
повторяется, только если вызывающий сказал, что повтор безопасен.

### Транзакции: `transaction`

Транзакции у MongoDB есть только у набора реплик и у mongos. Драйвер
заводит метод `transaction`, только когда задан `replica_set`: имя набора
сверяется при входе с тем, что назвал узел в `hello`, и узел не из набора —
отказ входа `denied`. Без `replica_set` метода нет, а
`features.transaction = false`: транзакция, которая ничего
не откатывает, хуже её отсутствия.

```lua
db:transaction(function(tx)
    tx:command({ 'insert', 'orders', documents = { { _id = 1, user = 7 } } })
    tx:command({ 'update', 'users', updates = { { q = { _id = 7 }, u = { ['$inc'] = { orders = 1 } } } } })
end)
--> true
db:transaction(function(tx)
    tx:command({ 'insert', 'orders', documents = { { _id = 2, user = 8 } } })

    return nil, 'передумали'
end)
--> nil, передумали          — заказа 2 нет
mongo.new({ db = 'x' }).transaction
--> nil
```

Договор тот же, что у транзакции драйвера SQL над роком из `tnt-storage`,
а устройство — MongoDB:

- транзакция берёт одно соединение; `BEGIN` нет — транзакцию открывает
  первая команда с `startTransaction`, и каждая команда несёт сеанс
  соединения (`lsid`), номер транзакции (`txnNumber`, растёт в сеансе)
  и `autocommit: false`. `tx:command` и `tx:query` — те же, что у драйвера,
  с настройками `db` и `max_rows`; срока и повтора у них нет — срок один
  на транзакцию, и `timeout` или `idempotent` у них — исключение;
- тело ничего не вернуло — фиксация (`commitTransaction` на базе `admin`)
  и `true`; `nil` или `false` — отмена (`abortTransaction`) и пара
  `nil, err`, где `err` тела отдаётся как есть; иное — фиксация и это
  значение. Тело без единой команды фиксировать нечего: сервер о такой
  транзакции не знает;
- **первый отказ команды помечает транзакцию**: следующие команды `tx`
  отдают тот же отказ без отправки, фиксации не будет;
- исключение в теле — отмена, соединение выбрасывается, исключение идёт
  дальше. **Закрытие сокета транзакцию MongoDB не отменяет**: она живёт
  в сеансе, а не в соединении, поэтому отмена шлётся явно;
- `retry = true` повторяет всю транзакцию с телом, если она кончилась
  конфликтом (`TransientTransactionError`, конфликт записи): сервер снял её
  целиком. Тело обязано быть безопасным для повтора;
- `tx` годен только внутри тела; вложенная транзакция и транзакция внутри
  транзакции box — исключение.

```lua
db:transaction(function(tx)
    tx:command({ 'ping', 1 }, { timeout = 1 })
end)
--> исключение: у команды транзакции нет своего срока и повтора: их задаёт transaction
```

### Соединения

- **Пул — `tnt-pool`**, заведённый драйвером; соединения открываются
  лениво. Одно соединение — одна команда за раз: ответ сверяется с номером
  запроса, и чужой ответ — поломка протокола.
- **Вход — `hello` и SCRAM-SHA-256.** `hello` несёт описание клиента: имя
  драйвера (`application.name` — настройка `name`), `tnt-mongo`, ОС,
  выпуск Tarantool; его видно в журнале сервера и в `currentOp`. Подпись
  сервера в конце SCRAM сверяется: без сверки вход к подставному серверу,
  который пароля не знает, прошёл бы молча. Сервер, объявивший вход
  законченным, не прислав подписи, — тот же отказ `denied`.
- **Растянутый пароль считается один раз на драйвер** и запоминается по
  соли: PBKDF2 на 15 000 проходов (умолчание MongoDB) — десятки
  миллисекунд, и растягивание уступает управление через каждую тысячу
  проходов. Считается оно из HMAC `tnt-hash`, а не `digest.pbkdf2`: соль
  приходит от сервера, и нулевой байт в ней бывает, а `digest.pbkdf2`
  режет соль по нему ([`tnt-hash`](https://github.com/tnt-skein/tnt-hash/blob/main/docs/hash.md),
  «Нулевой байт»).
- **Живость — без сети**: у открытого сокета — неблокирующий `sysread`.
  Свободному соединению сервер не шлёт ничего, и если читать есть что,
  соединение негодно.
- **Узел не ведущий — выброс соединения**: новое соединение по тому же
  имени узла может прийти уже к новому ведущему.
- **Закрытие** закрывает пул: свободные соединения — сразу, занятые — когда
  их вернут. Повторное закрытие и вызов после — пара `closed`.
- **Отмена вызывающего** выбрасывает соединение и уходит дальше тем же
  исключением отмены, а не парой.

### Журнал

| Событие | Уровень | Поля | Кто пишет |
|---|---|---|---|
| соединение выброшено | `warn` | `driver`, `kind`, `reason` | драйвер |
| соединение не открылось | `warn` | `pool`, `err`, `streak` | `tnt-pool` |
| повтор | `debug` | `attempt`, `delay`, `err` | `tnt-retry` |

Ни команды, ни фильтра, ни документа в журнале нет. Пароль не уходит
в сеть вовсе и нигде не показывается: ни в `stats()`, ни в тексте отказа.

```lua
local sessions = mongo.new({ port = 37017, db = 'tnt_live', username = 'app', password = 'app-secret', name = 'sessions' })

sessions:command({ 'ping', 1 })
sessions:stats()
--> { name = 'sessions', size = 8, busy = 0, idle = 1, total = 1, opened = 1, takes = 1,
--    gives = 1, drops = 0, discarded = 0, open_failures = 0, waiting = 0, waits = 0,
--    wait_timeouts = 0, leaks = 0, closed = false }
```

### Шифрование

`tls = true` — TLS с проверкой сертификата по системным корням;
таблица — настройки `tnt-tls`: `verify`, `ca_file`, `ca_path`, `sni`.
Имя, по которому сверяется сертификат, — `host`. Рукопожатие идёт
в остаток срока входа.

```lua
local secured = mongo.new({
    port = 37017,
    db = 'tnt_live',
    username = 'app',
    password = 'app-secret',
    tls = { ca_file = 'test/stand/run/mongo-tls/ca.pem' },
})

secured:command({ 'ping', 1 }).ok
--> 1
```

Сертификата клиента драйвер не предъявляет — настройка `tls` не передаёт
его в `tnt-tls`, — поэтому сервер с TLS держат
с `--tlsAllowConnectionsWithoutCertificates`, как стенд.

### Подмена в проверках

Всё, чем пакет ходит в мир, объявлено внешними зависимостями
`tnt-external` и подменяется в проверках по одной, без двойника всего
мира:

| Модуль | Зависимости | Что это |
|---|---|---|
| `tnt.mongo.link` | `connect`, `tls` | открытие сокета и пакет шифрования |
| `tnt.mongo.scram` | `nonce`, `yield` | случайное клиента во входе и уступка растягивания |
| `tnt.mongo.types` | `now`, `random` | секунды и случайное процесса у нового `ObjectId` |
| `tnt.mongo.transaction` | `box_txn` | идёт ли транзакция box |

Часы срока — у `tnt-storage` (`storage.within._set_source`).
`_set_source(nil)` возвращает настоящие; незнакомое имя — исключение,
а не подмена мимо.

```lua
local link = require('tnt.mongo.link')

link._set_source({
    connect = function()
        error('сети нет', 0)
    end,
})
local _, err = mongo.new({ db = 'shop', timeout = 0.2 }):command({ 'ping', 1 })
--> err.kind == 'unreachable', текст кончается «соединение не открылось: сети нет»
link._set_source(nil)

local types = require('tnt.mongo.types')

types._reset()           -- случайное процесса заведётся заново, из подмены
types._set_source({
    now = function()
        return 1758284096
    end,
    random = function(size)
        return ('\1'):rep(size)
    end,
})
tostring(mongo.object_id())
--> '68cd49400101010101010101'   — секунды, случайное процесса, счётчик
types._set_source(nil)
types._reset()
```

## Чем пришлось поступиться

- **Протокол свой.** Готового неблокирующего клиента нет, а обёртка над
  клиентской библиотекой на C остановила бы весь узел. Цена — OP_MSG, BSON
  и SCRAM и их проверка на нас.
- **Команда — массив, а не документ**: имя первым, прочее — полями. Порядок
  полей, где он важен, — только `mongo.ordered`; прочитанный документ
  порядка не держит.
- **Пустая таблица — документ**: пустой массив пишут явно, `__serialize =
  'seq'`.
- **Время — до миллисекунды**, целое `int64` из базы — число, пока точно:
  записанное обратно оно может сменить тип на `int32`.
- **Брошенная операция дорабатывает на сервере**: потолок — только
  `maxTimeMS` в команде.
- **Транзакция, чьё соединение выброшено посреди тела** (срок, обрыв),
  не отменяется: в сокете недочитанный ответ. Её снимает сервер по
  `transactionLifetimeLimitSeconds` (60 с), а до того она держит свои
  документы, и чужие записи в них получают конфликт.
- **Отказ записи внутри ответа — отказ всего вызова**, хотя часть записей
  может быть сделана: кому важна каждая, шлёт их по одной либо с
  `ordered = false` и читает ответ `command` сам.
- **Живость видна только у открытого сокета**: под TLS соединение, умершее
  в простое, узнаётся первым запросом, и без `idempotent` он не
  повторяется.
- **SASLprep нет**: пароль, который он поменял бы (не в NFKC, с особыми
  пробелами), не войдёт — `denied`, а не вход с другим паролем.
- **Предел `max_bytes` — на один ответ, и сверх него соединение
  выбрасывается**: дочитывать лишнее ради соединения — значит всё-таки
  принять то, от чего предел защищает.

## Проверки

Проверки лежат в `test/` и идут на luatest: `.rocks/bin/luatest test/`.

- `types_test.lua`, `decimal128_test.lua`, `bson_test.lua`, `wire_test.lua`,
  `scram_test.lua`, `request_test.lua`, `settings_test.lua` — без сети:
  значения без пары в Lua, векторы `decimal128` из спецификации BSON,
  каждый тип BSON байт в байт в обе стороны и каждая поломка записи, рамка
  OP_MSG, вектор SCRAM из RFC 7677 и PBKDF2 из RFC 7914, сборка команды.
- `link_test.lua`, `operation_test.lua`, `mongo_test.lua`,
  `transaction_test.lua` — на двойнике сервера с настоящим сокетом
  на петле, который говорит OP_MSG и входит по SCRAM сам: вход, набор
  реплик, подпись сервера, TLS через внешнюю зависимость, сроки, обрыв,
  отмена файбера, курсор пачками и его предел, повторы по роду, транзакции.
- `transaction_node_test.lua` — на временном узле с настоящим `box`:
  транзакция внутри транзакции box — исключение. Вне узла этого не видно:
  без `box.cfg` транзакций box не бывает.
- `mongo_live_test.lua` — 8 проверок против MongoDB 7 в докере: значения
  туда и обратно, дубликат ключа, курсор пачками, вход (неверный пароль,
  имя с запятой и знаком равенства, учётка только для чтения, чужой набор
  реплик), TLS с корнем стенда, `maxTimeMS` и срок вызова, транзакция
  и конфликт записи с повтором.

```sh
make mongo-up                                # MongoDB 7: порт 37017, набор rs0, TLS на том же порту
.rocks/bin/luatest test/mongo_live_test.lua
make mongo-down
```

Без поднятого сервера живые проверки пропускаются: гейты не зависят
от докера. Без сети — 157 проверок за шесть секунд; покрытие строк —
100 %, убитых мутантов — 100 %.
