#!/bin/bash

###
# Скрипт для автоматической инициализации MongoDB Sharding
###

set -e

echo "=========================================="
echo "Инициализация MongoDB Sharding"
echo "=========================================="

# Функция для ожидания доступности MongoDB
wait_for_mongo() {
    local container=$1
    local max_attempts=30
    local attempt=1

    echo "Ожидание запуска $container..."
    while [ $attempt -le $max_attempts ]; do
        if docker compose exec -T $container mongosh --port 27017 --eval "db.adminCommand('ping')" > /dev/null 2>&1; then
            echo "✓ $container готов"
            return 0
        fi
        echo "  Попытка $attempt/$max_attempts..."
        sleep 2
        attempt=$((attempt + 1))
    done

    echo "✗ Не удалось дождаться запуска $container"
    return 1
}

echo ""
echo "Шаг 1: Ожидание запуска контейнеров..."
echo "=========================================="
wait_for_mongo sharding-configSrv1
wait_for_mongo sharding-configSrv2
wait_for_mongo sharding-configSrv3
wait_for_mongo sharding-shard1-1
wait_for_mongo sharding-shard2-1

echo ""
echo "Шаг 2: Инициализация Config Server Replica Set..."
echo "=========================================="
docker compose exec -T sharding-configSrv1 mongosh --port 27017 <<EOF
rs.initiate({
  _id: "configReplSet",
  configsvr: true,
  members: [
    { _id: 0, host: "configSrv1:27017" },
    { _id: 1, host: "configSrv2:27017" },
    { _id: 2, host: "configSrv3:27017" }
  ]
})
EOF

echo "✓ Config Server Replica Set инициализирован"
echo "Ожидание выбора PRIMARY..."
sleep 10

echo ""
echo "Шаг 3: Инициализация Shard 1 Replica Set..."
echo "=========================================="
docker compose exec -T sharding-shard1-1 mongosh --port 27017 <<EOF
rs.initiate({
  _id: "shard1ReplSet",
  members: [
    { _id: 0, host: "shard1-1:27017" }
  ]
})
EOF

echo "✓ Shard 1 Replica Set инициализирован"
sleep 5

echo ""
echo "Шаг 4: Инициализация Shard 2 Replica Set..."
echo "=========================================="
docker compose exec -T sharding-shard2-1 mongosh --port 27017 <<EOF
rs.initiate({
  _id: "shard2ReplSet",
  members: [
    { _id: 0, host: "shard2-1:27017" }
  ]
})
EOF

echo "✓ Shard 2 Replica Set инициализирован"
sleep 5

echo ""
echo "Шаг 5: Перезапуск mongos..."
echo "=========================================="
docker compose restart sharding-mongos
echo "Ожидание запуска mongos..."
sleep 10

echo ""
echo "Шаг 6: Добавление шардов в кластер..."
echo "=========================================="
docker compose exec -T sharding-mongos mongosh --port 27017 <<EOF
sh.addShard("shard1ReplSet/shard1-1:27017")
sh.addShard("shard2ReplSet/shard2-1:27017")
sh.status()
EOF

echo "✓ Шарды добавлены в кластер"

echo ""
echo "Шаг 7: Включение шардирования для БД и коллекции..."
echo "=========================================="
docker compose exec -T sharding-mongos mongosh --port 27017 <<EOF
sh.enableSharding("somedb")
use somedb
db.helloDoc.createIndex({ age: 1 })
sh.shardCollection("somedb.helloDoc", { age: 1 })
EOF

echo "✓ Шардирование включено для somedb.helloDoc"

echo ""
echo "Шаг 8: Заполнение данными..."
echo "=========================================="
docker compose exec -T sharding-mongos mongosh --port 27017 <<EOF
use somedb
for(var i = 0; i < 1000; i++) {
  db.helloDoc.insertOne({age: i, name: "ly" + i})
}
print("Добавлено документов: " + db.helloDoc.countDocuments())
EOF

echo "✓ Данные добавлены"

echo ""
echo "Шаг 9: Перезапуск приложения..."
echo "=========================================="
docker compose restart sharding-pymongo_api

echo ""
echo "=========================================="
echo "✓ Инициализация завершена успешно!"
echo "=========================================="
echo ""
echo "Проверьте работу приложения:"
echo "  http://localhost:8080"
echo ""
echo "Просмотр распределения данных:"
echo "  docker compose exec sharding-mongos mongosh somedb --eval \"db.helloDoc.getShardDistribution()\""
echo ""
