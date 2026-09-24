#!/usr/bin/env bash
# Поднимает MongoDB для живых проверок драйвера tnt-mongo.
#
# Настоящий сервер, а не двойник: двойник показывает, что мы правильно
# разговариваем сами с собой, а чужой сервер — что нас понимает кто-то
# ещё. Разница вылезает на первом же отказе: код и метки ошибки, отказ
# записи внутри ответа ok: 1, подпись сервера в конце входа SCRAM.
#
# Один узел, но набором реплик `rs0`: транзакции MongoDB есть только
# у набора реплик и у mongos, а без них проверять `transaction` не на чем.
# Вход обязателен (`--auth`), поэтому набору нужен ключ узлов — он
# выпускается внутри контейнера и наружу не выходит. Учётки:
#
#   * `root` — всё, ей стенд заводит остальных;
#   * `app` — чтение и запись в базе `tnt_live`, только SCRAM-SHA-256;
#   * `reader` — только чтение там же: отказ Unauthorized настоящий;
#   * `we,ird=name` — запятая и равенство в имени: SCRAM заменяет их
#     на `=2C` и `=3D`, и ошибка в замене — это отказ входа.
#
# TLS на том же порту (`--tlsMode allowTLS`): сервер принимает и открытый
# текст, и TLS. Сертификат выпускается здесь же на сутки корнем из того
# же каталога; клиентский сертификат не требуется — tnt-tls его
# не предъявляет.
#
# Каталог сертификатов — `MONGO_TLS_DIR`, по умолчанию
# `test/stand/run/mongo-tls`; живая проверка читает ту же переменную.
#
#   test/stand/mongo.sh          # поднять
#   test/stand/mongo.sh stop     # погасить
set -euo pipefail

cd "$(dirname "$0")"

IMAGE='mongo:7'
CONTAINER='tnt-stand-mongo'
PORT="${STAND_MONGO_PORT:-37017}"
DIR="${MONGO_TLS_DIR:-run/mongo-tls}"

# Пароли стенда: локальный сервер для проверок, а не развёртывание.
ROOT_PASSWORD='stand-secret'

if ! command -v docker > /dev/null 2>&1; then
    echo 'docker не найден: MongoDB поднять нечем' >&2
    exit 1
fi

if [ "${1:-up}" = 'stop' ]; then
    docker rm -f "${CONTAINER}" > /dev/null 2>&1 || true
    echo 'MongoDB остановлен'
    exit 0
fi

if ! command -v openssl > /dev/null 2>&1; then
    echo 'openssl не найден: сертификаты выпустить нечем' >&2
    exit 1
fi

mkdir -p "${DIR}"
DIR="$(cd "${DIR}" && pwd)"

# Сертификаты выпускаются заново на каждый подъём: срок у них сутки,
# и вчерашний каталог дал бы отказ рукопожатия, неотличимый от того,
# ради которого проверка написана.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=tnt-mongo-live-ca' \
    -keyout "${DIR}/ca.key" -out "${DIR}/ca.pem" 2> /dev/null
printf 'subjectAltName=IP:127.0.0.1,DNS:localhost\nextendedKeyUsage=serverAuth\n' > "${DIR}/server.ext"
openssl req -newkey rsa:2048 -nodes -subj '/CN=localhost' \
    -keyout "${DIR}/server.key" -out "${DIR}/server.csr" 2> /dev/null
openssl x509 -req -in "${DIR}/server.csr" -days 1 \
    -CA "${DIR}/ca.pem" -CAkey "${DIR}/ca.key" -CAcreateserial \
    -extfile "${DIR}/server.ext" -out "${DIR}/server.crt" 2> /dev/null

# mongod берёт ключ и сертификат одним файлом.
cat "${DIR}/server.key" "${DIR}/server.crt" > "${DIR}/server.pem"

# MongoDB в образе запускается не от root: файлы должны читаться всеми.
chmod 644 "${DIR}"/*.key "${DIR}/server.pem"

# Повторный запуск безвреден: контейнер с тем же именем сносится
# и поднимается заново. Данные живут в контейнере и уходят вместе с ним.
docker rm -f "${CONTAINER}" > /dev/null 2>&1 || true

# Ключ узлов набора: без него mongod с --auth и --replSet не стартует.
# Выпускается внутри контейнера, владельцу mongodb и с правами 400 —
# на смонтированном с macOS файле ни владельца, ни прав не поменять.
# shellcheck disable=SC2016
docker run -d \
    --name "${CONTAINER}" \
    -p "127.0.0.1:${PORT}:27017" \
    -v "${DIR}:/certs:ro" \
    --entrypoint bash \
    "${IMAGE}" \
    -c 'head -c 756 /dev/urandom | base64 > /tmp/keyfile \
        && chmod 400 /tmp/keyfile && chown mongodb:mongodb /tmp/keyfile \
        && exec gosu mongodb mongod --replSet rs0 --bind_ip_all --auth \
            --keyFile /tmp/keyfile --dbpath /data/db \
            --tlsMode allowTLS \
            --tlsCertificateKeyFile /certs/server.pem \
            --tlsCAFile /certs/ca.pem \
            --tlsAllowConnectionsWithoutCertificates' > /dev/null

# Команда mongosh внутри контейнера. До первой учётки сервер пускает
# с петли без входа (исключение localhost), после — только root.
shell() {
    docker exec "${CONTAINER}" mongosh --quiet "$@"
}

as_root() {
    shell -u root -p "${ROOT_PASSWORD}" --authenticationDatabase admin "$@"
}

# Готовности ждём: проверки, запущенные сразу после подъёма, иначе
# пропустятся — и это выглядит как «всё хорошо», хотя ничего
# не проверено.
ready=''

for _ in $(seq 1 100); do
    if shell --eval 'db.runCommand({ ping: 1 }).ok' 2> /dev/null | grep -q 1; then
        ready='yes'
        break
    fi

    sleep 0.2
done

if [ -z "${ready}" ]; then
    echo "MongoDB не ответил за 20 секунд: смотрите docker logs ${CONTAINER}" >&2
    exit 1
fi

# Набор из одного узла под тем именем, по которому узел знает себя сам.
shell --eval 'rs.initiate({ _id: "rs0", members: [{ _id: 0, host: "127.0.0.1:27017" }] })' > /dev/null

primary=''

for _ in $(seq 1 100); do
    if shell --eval 'db.hello().isWritablePrimary' 2> /dev/null | grep -q true; then
        primary='yes'
        break
    fi

    sleep 0.2
done

if [ -z "${primary}" ]; then
    echo "MongoDB не стал ведущим за 20 секунд: смотрите docker logs ${CONTAINER}" >&2
    exit 1
fi

shell --eval "db.getSiblingDB('admin').createUser({ user: 'root', pwd: '${ROOT_PASSWORD}', roles: ['root'] })" > /dev/null

as_root --eval '
    const live = db.getSiblingDB("admin");
    live.createUser({ user: "app", pwd: "app-secret", mechanisms: ["SCRAM-SHA-256"],
        roles: [{ role: "readWrite", db: "tnt_live" }] });
    live.createUser({ user: "reader", pwd: "reader-secret", mechanisms: ["SCRAM-SHA-256"],
        roles: [{ role: "read", db: "tnt_live" }] });
    live.createUser({ user: "we,ird=name", pwd: "weird-secret", mechanisms: ["SCRAM-SHA-256"],
        roles: [{ role: "read", db: "tnt_live" }] });
' > /dev/null

echo "MongoDB поднят: 127.0.0.1:${PORT}, набор rs0, TLS на том же порту, сертификаты в ${DIR}"
