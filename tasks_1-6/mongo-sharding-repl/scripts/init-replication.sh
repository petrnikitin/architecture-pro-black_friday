#!/bin/bash

###
# Script for MongoDB Sharding with Replication initialization
###

set -e

echo "=========================================="
echo "MongoDB Sharding + Replication Init"
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

echo ""
echo "Step 1: Waiting for containers..."
echo "=========================================="
wait_for_mongo repl-configSrv1
wait_for_mongo repl-configSrv2
wait_for_mongo repl-configSrv3
wait_for_mongo repl-shard1-1
wait_for_mongo repl-shard1-2
wait_for_mongo repl-shard1-3
wait_for_mongo repl-shard2-1
wait_for_mongo repl-shard2-2
wait_for_mongo repl-shard2-3

echo ""
echo "Step 2: Initialize Config Server Replica Set..."
echo "=========================================="
docker exec -i repl-configSrv1 mongosh --port 27017 --quiet <<EOF
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
docker exec -i repl-shard1-1 mongosh --port 27017 --quiet <<EOF
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
docker exec -i repl-shard2-1 mongosh --port 27017 --quiet <<EOF
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
docker restart repl-mongos
echo "Waiting for mongos to start..."
sleep 10

echo ""
echo "Step 6: Add shards to cluster..."
echo "=========================================="
docker exec -i repl-mongos mongosh --port 27017 --quiet <<EOF
sh.addShard("shard1ReplSet/shard1-1:27017,shard1-2:27017,shard1-3:27017")
sh.addShard("shard2ReplSet/shard2-1:27017,shard2-2:27017,shard2-3:27017")
sh.status()
EOF

echo "[OK] Shards with replicas added to cluster"

echo ""
echo "Step 7: Enable sharding for DB and collection..."
echo "=========================================="
docker exec -i repl-mongos mongosh --port 27017 --quiet <<EOF
sh.enableSharding("somedb")
use somedb
db.helloDoc.createIndex({ age: 1 })
sh.shardCollection("somedb.helloDoc", { age: 1 })
EOF

echo "[OK] Sharding enabled for somedb.helloDoc"

echo ""
echo "Step 8: Insert test data..."
echo "=========================================="
docker exec -i repl-mongos mongosh --port 27017 --quiet <<EOF
use somedb
for(var i = 0; i < 1000; i++) {
  db.helloDoc.insertOne({age: i, name: "ly" + i})
}
print("Documents inserted: " + db.helloDoc.countDocuments())
EOF

echo "[OK] Test data inserted (1000 documents)"

echo ""
echo "Step 9: Check replica sets status..."
echo "=========================================="
echo "Shard 1 Replica Set:"
docker exec repl-shard1-1 mongosh --port 27017 --quiet --eval "rs.status().members.forEach(m => print(m.name + ' - ' + m.stateStr))"
echo ""
echo "Shard 2 Replica Set:"
docker exec repl-shard2-1 mongosh --port 27017 --quiet --eval "rs.status().members.forEach(m => print(m.name + ' - ' + m.stateStr))"

echo ""
echo "Step 10: Restart application..."
echo "=========================================="
docker restart repl-pymongo_api
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
echo "  - Total: 9 MongoDB nodes + 1 mongos"
echo ""
echo "Check application:"
echo "  http://localhost:8080"
echo ""
echo "View shard distribution:"
echo "  docker exec repl-mongos mongosh somedb --eval \"db.helloDoc.getShardDistribution()\""
echo ""
