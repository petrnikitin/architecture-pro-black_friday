#!/bin/bash

###
# Script for MongoDB Sharding + Replication + Cache initialization
###

set -e

echo "=========================================="
echo "MongoDB Sharding + Replication + Cache"
echo "=========================================="

# Function to wait for MongoDB
wait_for_mongo() {
    local container=$1
    local max_attempts=30
    local attempt=1

    echo "Waiting for $container..."
    while [ $attempt -le $max_attempts ]; do
        if docker exec $container mongosh --port 27017 --eval "db.adminCommand('ping')" > /dev/null 2>&1; then
            echo "[OK] $container is ready"
            return 0
        fi
        echo "  Attempt $attempt/$max_attempts..."
        sleep 2
        attempt=$((attempt + 1))
    done

    echo "[ERROR] Failed to wait for $container"
    return 1
}

# Function to wait for Redis
wait_for_redis() {
    local max_attempts=15
    local attempt=1

    echo "Waiting for Redis..."
    while [ $attempt -le $max_attempts ]; do
        if docker exec cache-redis redis-cli ping > /dev/null 2>&1; then
            echo "[OK] Redis is ready"
            return 0
        fi
        echo "  Attempt $attempt/$max_attempts..."
        sleep 1
        attempt=$((attempt + 1))
    done

    echo "[ERROR] Failed to wait for Redis"
    return 1
}

echo ""
echo "Step 1: Waiting for containers..."
echo "=========================================="
wait_for_redis
wait_for_mongo cache-configSrv1
wait_for_mongo cache-configSrv2
wait_for_mongo cache-configSrv3
wait_for_mongo cache-shard1-1
wait_for_mongo cache-shard1-2
wait_for_mongo cache-shard1-3
wait_for_mongo cache-shard2-1
wait_for_mongo cache-shard2-2
wait_for_mongo cache-shard2-3

echo ""
echo "Step 2: Initialize Config Server Replica Set..."
echo "=========================================="
docker exec -i cache-configSrv1 mongosh --port 27017 --quiet <<EOF
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

echo "[OK] Config Server Replica Set initialized (3 replicas)"
echo "Waiting for PRIMARY election..."
sleep 10

echo ""
echo "Step 3: Initialize Shard 1 Replica Set (3 replicas)..."
echo "=========================================="
docker exec -i cache-shard1-1 mongosh --port 27017 --quiet <<EOF
rs.initiate({
  _id: "shard1ReplSet",
  members: [
    { _id: 0, host: "shard1-1:27017" },
    { _id: 1, host: "shard1-2:27017" },
    { _id: 2, host: "shard1-3:27017" }
  ]
})
EOF

echo "[OK] Shard 1 Replica Set initialized (3 replicas)"
sleep 10

echo ""
echo "Step 4: Initialize Shard 2 Replica Set (3 replicas)..."
echo "=========================================="
docker exec -i cache-shard2-1 mongosh --port 27017 --quiet <<EOF
rs.initiate({
  _id: "shard2ReplSet",
  members: [
    { _id: 0, host: "shard2-1:27017" },
    { _id: 1, host: "shard2-2:27017" },
    { _id: 2, host: "shard2-3:27017" }
  ]
})
EOF

echo "[OK] Shard 2 Replica Set initialized (3 replicas)"
sleep 10

echo ""
echo "Step 5: Restart mongos..."
echo "=========================================="
docker restart cache-mongos
echo "Waiting for mongos to start..."
sleep 10

echo ""
echo "Step 6: Add shards to cluster..."
echo "=========================================="
docker exec -i cache-mongos mongosh --port 27017 --quiet <<EOF
sh.addShard("shard1ReplSet/shard1-1:27017,shard1-2:27017,shard1-3:27017")
sh.addShard("shard2ReplSet/shard2-1:27017,shard2-2:27017,shard2-3:27017")
sh.status()
EOF

echo "[OK] Shards with replicas added to cluster"

echo ""
echo "Step 7: Enable sharding for DB and collection..."
echo "=========================================="
docker exec -i cache-mongos mongosh --port 27017 --quiet <<EOF
sh.enableSharding("somedb")
use somedb
db.helloDoc.createIndex({ age: 1 })
sh.shardCollection("somedb.helloDoc", { age: 1 })
EOF

echo "[OK] Sharding enabled for somedb.helloDoc"

echo ""
echo "Step 8: Insert test data..."
echo "=========================================="
docker exec -i cache-mongos mongosh --port 27017 --quiet <<EOF
use somedb
for(var i = 0; i < 1000; i++) {
  db.helloDoc.insertOne({age: i, name: "ly" + i})
}
print("Documents inserted: " + db.helloDoc.countDocuments())
EOF

echo "[OK] Test data inserted (1000 documents)"

echo ""
echo "Step 9: Restart application..."
echo "=========================================="
docker restart cache-pymongo_api
sleep 3

echo ""
echo "=========================================="
echo "[SUCCESS] Initialization completed!"
echo "=========================================="
echo ""
echo "Architecture:"
echo "  - Config Servers: 3 replicas"
echo "  - Shard 1: 3 replicas"
echo "  - Shard 2: 3 replicas"
echo "  - Redis Cache: enabled"
echo "  - Total: 9 MongoDB nodes + 1 mongos + 1 Redis"
echo ""
echo "Check application:"
echo "  http://localhost:8080"
echo "  (cache_enabled should be: true)"
echo ""
echo "Test caching performance:"
echo "  curl http://localhost:8080/helloDoc/users  # First call: ~1000ms"
echo "  curl http://localhost:8080/helloDoc/users  # Cached call: <100ms"
echo ""
