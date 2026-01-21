# MongoDB Sharding with Replication

Этот проект реализует шардирование MongoDB с репликацией для повышения производительности и отказоустойчивости.

> **⚠️ ВАЖНО:** После запуска контейнеров необходимо выполнить инициализацию. Без инициализации mongos не запустится и приложение не сможет подключиться к БД.

## Архитектура

- **3 Config Servers** в Replica Set (configSrv1-3) - хранение метаданных кластера
- **Shard 1 Replica Set**: 3 реплики (shard1-1, shard1-2, shard1-3) - PRIMARY + 2 SECONDARY
- **Shard 2 Replica Set**: 3 реплики (shard2-1, shard2-2, shard2-3) - PRIMARY + 2 SECONDARY
- **1 Mongos Router** - маршрутизация запросов к шардам
- **1 API приложение** (pymongo_api) - FastAPI приложение для работы с БД

**Всего:** 10 контейнеров (9 MongoDB нод + 1 приложение)

## Установка и запуск

### Быстрый старт (автоматическая инициализация)

**Для Windows (PowerShell):**
```powershell
# 1. Запуск контейнеров
cd mongo-sharding-repl
docker compose up -d

# 2. Автоматическая инициализация (выполняет все шаги 2-10)
.\scripts\init-replication.ps1
```

**Для Linux/macOS (Bash):**
```bash
# 1. Запуск контейнеров
cd mongo-sharding-repl
docker compose up -d

# 2. Автоматическая инициализация (выполняет все шаги 2-10)
chmod +x scripts/init-replication.sh
./scripts/init-replication.sh
```

### Ручная инициализация (пошагово)

#### 1. Запуск контейнеров

```bash
docker compose up -d
```

Дождитесь запуска всех контейнеров (~30-40 секунд).

#### 2. Инициализация Config Server Replica Set

Подключаемся к первой ноде config servers:

```bash
docker exec -it repl-configSrv1 mongosh --port 27017
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

Проверяем статус:
```javascript
rs.status()
```

Выход: `exit`

#### 3. Инициализация Shard 1 Replica Set

```bash
docker exec -it repl-shard1-1 mongosh --port 27017
```

В mongosh выполняем:

```javascript
rs.initiate({
  _id: "shard1ReplSet",
  members: [
    { _id: 0, host: "shard1-1:27017" },
    { _id: 1, host: "shard1-2:27017" },
    { _id: 2, host: "shard1-3:27017" }
  ]
})
```

Проверяем статус:
```javascript
rs.status()
```

Дождитесь выбора PRIMARY (статусы: PRIMARY, SECONDARY, SECONDARY).

Выход: `exit`

#### 4. Инициализация Shard 2 Replica Set

```bash
docker exec -it repl-shard2-1 mongosh --port 27017
```

В mongosh выполняем:

```javascript
rs.initiate({
  _id: "shard2ReplSet",
  members: [
    { _id: 0, host: "shard2-1:27017" },
    { _id: 1, host: "shard2-2:27017" },
    { _id: 2, host: "shard2-3:27017" }
  ]
})
```

Проверяем статус:
```javascript
rs.status()
```

Дождитесь выбора PRIMARY.

Выход: `exit`

#### 5. Перезапуск mongos

```bash
docker restart repl-mongos
```

Подождите ~10 секунд для запуска mongos.

#### 6. Добавление шардов в кластер

Подключаемся к mongos:

```bash
docker exec -it repl-mongos mongosh --port 27017
```

В mongosh выполняем:

```javascript
// Добавляем шарды с указанием всех реплик
sh.addShard("shard1ReplSet/shard1-1:27017,shard1-2:27017,shard1-3:27017")
sh.addShard("shard2ReplSet/shard2-1:27017,shard2-2:27017,shard2-3:27017")
```

Проверяем статус шардирования:

```javascript
sh.status()
```

Выход: `exit`

#### 7. Включение шардирования для БД и коллекции

Подключаемся к mongos:

```bash
docker exec -it repl-mongos mongosh --port 27017
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

#### 8. Заполнение данными

```bash
docker exec -it repl-mongos mongosh --port 27017
```

```javascript
use somedb
for(var i = 0; i < 1000; i++) {
  db.helloDoc.insertOne({age: i, name: "ly" + i})
}
print("Добавлено документов: " + db.helloDoc.countDocuments())
```

Выход: `exit`

#### 9. Проверка репликации

**Shard 1 Replica Set:**
```bash
docker exec repl-shard1-1 mongosh --port 27017 --eval "rs.status().members"
```

**Shard 2 Replica Set:**
```bash
docker exec repl-shard2-1 mongosh --port 27017 --eval "rs.status().members"
```

#### 10. Перезапуск приложения

```bash
docker restart repl-pymongo_api
```

## Проверка работы

Откройте в браузере: http://localhost:8080

API должен показать:
- `mongo_topology_type`: "Sharded"
- `shards`: информация о двух шардах с репликами
- `collections.helloDoc.documents_count`: >= 1000

Swagger документация: http://localhost:8080/docs

## Полезные команды

**Просмотр статуса кластера:**
```bash
docker exec repl-mongos mongosh --eval "sh.status()"
```

**Просмотр распределения данных:**
```bash
docker exec repl-mongos mongosh somedb --eval "db.helloDoc.getShardDistribution()"
```

**Проверка статуса Shard 1 Replica Set:**
```bash
docker exec repl-shard1-1 mongosh --eval "rs.status()" | grep -A 5 "members"
```

**Проверка статуса Shard 2 Replica Set:**
```bash
docker exec repl-shard2-1 mongosh --eval "rs.status()" | grep -A 5 "members"
```

**Просмотр PRIMARY и SECONDARY нод:**
```bash
# Shard 1
docker exec repl-shard1-1 mongosh --quiet --eval "rs.status().members.forEach(m => print(m.name + ' - ' + m.stateStr))"

# Shard 2
docker exec repl-shard2-1 mongosh --quiet --eval "rs.status().members.forEach(m => print(m.name + ' - ' + m.stateStr))"
```

**Остановка кластера:**
```bash
docker compose down
```

**Полная очистка (включая volumes):**
```bash
docker compose down -v
```

## Тестирование отказоустойчивости

### Симуляция отказа SECONDARY ноды

```bash
# Остановить одну из SECONDARY нод Shard 1
docker stop repl-shard1-2

# Проверить, что кластер продолжает работать
curl http://localhost:8080

# Проверить статус replica set
docker exec repl-shard1-1 mongosh --quiet --eval "rs.status().members.forEach(m => print(m.name + ' - ' + m.stateStr))"

# Восстановить ноду
docker start repl-shard1-2
```

### Симуляция отказа PRIMARY ноды

```bash
# Найти PRIMARY ноду Shard 1
docker exec repl-shard1-1 mongosh --quiet --eval "rs.status().members.filter(m => m.stateStr === 'PRIMARY').forEach(m => print(m.name))"

# Остановить PRIMARY (например, shard1-1)
docker stop repl-shard1-1

# Подождать 10-15 секунд для выбора нового PRIMARY
sleep 15

# Проверить, что выбран новый PRIMARY
docker exec repl-shard1-2 mongosh --quiet --eval "rs.status().members.forEach(m => print(m.name + ' - ' + m.stateStr))"

# Приложение должно продолжать работать
curl http://localhost:8080

# Восстановить ноду (станет SECONDARY)
docker start repl-shard1-1
```

## Преимущества репликации

1. **Отказоустойчивость**: При выходе из строя одной ноды данные остаются доступными
2. **Автоматический failover**: При падении PRIMARY автоматически выбирается новый PRIMARY
3. **Распределение чтения**: Можно читать с SECONDARY нод для снижения нагрузки
4. **Резервное копирование**: Можно делать бэкапы с SECONDARY без остановки сервиса
5. **Zero downtime maintenance**: Можно обновлять ноды по одной без остановки кластера
