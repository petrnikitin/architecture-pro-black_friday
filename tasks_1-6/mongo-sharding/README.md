# MongoDB Sharding Setup

Этот проект реализует шардирование MongoDB с 2 шардами для повышения производительности и масштабируемости.

> **⚠️ ВАЖНО:** После запуска контейнеров необходимо выполнить инициализацию (шаги 2-6). Без инициализации mongos не запустится и приложение не сможет подключиться к БД.

## Архитектура

- **3 Config Servers** (configSrv1, configSrv2, configSrv3) - хранение метаданных кластера
- **2 Shards** (shard1-1, shard2-1) - распределённое хранение данных
- **1 Mongos Router** - маршрутизация запросов к шардам
- **1 API приложение** (pymongo_api) - FastAPI приложение для работы с БД

## Установка и запуск

### Быстрый старт (автоматическая инициализация)

**Для Windows (PowerShell):**
```powershell
# 1. Запуск контейнеров
cd mongo-sharding
docker compose up -d

# 2. Автоматическая инициализация (выполняет все шаги 2-8)
.\scripts\init-sharding.ps1
```

**Для Linux/macOS (Bash):**
```bash
# 1. Запуск контейнеров
cd mongo-sharding
docker compose up -d

# 2. Автоматическая инициализация (выполняет все шаги 2-8)
chmod +x scripts/init-sharding.sh
./scripts/init-sharding.sh
```

### Ручная инициализация (пошагово)

#### 1. Запуск контейнеров

```bash
docker compose up -d
```

Дождитесь запуска всех контейнеров (~30 секунд).

#####2. Инициализация Config Server Replica Set

Подключаемся к одному из config серверов и инициализируем replica set:

```bash
docker compose exec sharding-configSrv1 mongosh --port 27017
```

В mongosh выполняем:

```javascript
rs.initiate({
  _id: "configReplSet",
  configsvr: true,
  members: [
    { _id: 0, host: "configSrv1:27017" },
    { _id: 1, host: "configSrv2:27017" },
    { _id: 2, host: "configSrv3:27017" }
  ]
})
```

Выход: `exit`

####3. Инициализация Shard 1 Replica Set

```bash
docker compose exec sharding-shard1-1 mongosh --port 27017
```

В mongosh выполняем:

```javascript
rs.initiate({
  _id: "shard1ReplSet",
  members: [
    { _id: 0, host: "shard1-1:27017" }
  ]
})
```

Выход: `exit`

####4. Инициализация Shard 2 Replica Set

```bash
docker compose exec sharding-shard2-1 mongosh --port 27017
```

В mongosh выполняем:

```javascript
rs.initiate({
  _id: "shard2ReplSet",
  members: [
    { _id: 0, host: "shard2-1:27017" }
  ]
})
```

Выход: `exit`

####5. Добавление шардов в кластер

Подключаемся к mongos:

```bash
docker compose exec sharding-mongos mongosh --port 27017
```

В mongosh выполняем:

```javascript
sh.addShard("shard1ReplSet/shard1-1:27017")
sh.addShard("shard2ReplSet/shard2-1:27017")
```

Проверяем статус шардирования:

```javascript
sh.status()
```

Выход: `exit`

####6. Включение шардирования для БД и коллекции

Подключаемся к mongos:

```bash
docker compose exec sharding-mongos mongosh --port 27017
```

В mongosh выполняем:

```javascript
// Включаем шардирование для БД
sh.enableSharding("somedb")

// Выбираем БД
use somedb

// Создаём индекс по ключу шардирования
db.helloDoc.createIndex({ age: 1 })

// Включаем шардирование для коллекции
sh.shardCollection("somedb.helloDoc", { age: 1 })
```

Выход: `exit`

####7. Заполнение данными

```bash
docker compose exec sharding-mongos mongosh --port 27017 --eval '
use somedb
for(var i = 0; i < 1000; i++) {
  db.helloDoc.insertOne({age: i, name: "ly" + i})
}
'
```

####8. Проверка распределения данных по шардам

```bash
docker compose exec sharding-mongos mongosh --port 27017 --eval 'sh.status()'
```

Или через API:

```bash
curl http://localhost:8080
```

## Проверка работы

Откройте в браузере: http://localhost:8080

API должен показать:
- `mongo_topology_type`: "Sharded"
- `shards`: информация о двух шардах
- `collections.helloDoc.documents_count`: >= 1000

Swagger документация: http://localhost:8080/docs

## Полезные команды

Просмотр статуса кластера:
```bash
docker compose exec sharding-mongos mongosh --eval "sh.status()"
```

Просмотр распределения данных:
```bash
docker compose exec sharding-mongos mongosh somedb --eval "db.helloDoc.getShardDistribution()"
```

Остановка кластера:
```bash
docker compose down
```

Полная очистка (включая volumes):
```bash
docker compose down -v
```
