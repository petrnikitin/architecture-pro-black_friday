# PowerShell script for MongoDB Sharding initialization

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "MongoDB Sharding Initialization" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# Navigate to project directory
Set-Location -Path "$PSScriptRoot\.."

# Function to wait for MongoDB
function Wait-ForMongo {
    param($containerName)

    $maxAttempts = 30
    $attempt = 1

    Write-Host "Waiting for $containerName..." -ForegroundColor Yellow
    while ($attempt -le $maxAttempts) {
        $null = docker exec $containerName mongosh --port 27017 --eval "db.adminCommand('ping')" 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK] $containerName is ready" -ForegroundColor Green
            return $true
        }
        Write-Host "  Attempt $attempt/$maxAttempts..."
        Start-Sleep -Seconds 2
        $attempt++
    }

    Write-Host "[ERROR] Failed to wait for $containerName" -ForegroundColor Red
    return $false
}

Write-Host ""
Write-Host "Step 1: Waiting for containers..." -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Wait-ForMongo "sharding-configSrv1"
Wait-ForMongo "sharding-configSrv2"
Wait-ForMongo "sharding-configSrv3"
Wait-ForMongo "sharding-shard1-1"
Wait-ForMongo "sharding-shard2-1"

Write-Host ""
Write-Host "Step 2: Initialize Config Server Replica Set..." -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
@"
rs.initiate({
  _id: "configReplSet",
  configsvr: true,
  members: [
    { _id: 0, host: "configSrv1:27017" },
    { _id: 1, host: "configSrv2:27017" },
    { _id: 2, host: "configSrv3:27017" }
  ]
})
"@ | docker exec -i sharding-configSrv1 mongosh --port 27017 --quiet
Write-Host "[OK] Config Server Replica Set initialized" -ForegroundColor Green
Write-Host "Waiting for PRIMARY election..." -ForegroundColor Yellow
Start-Sleep -Seconds 10

Write-Host ""
Write-Host "Step 3: Initialize Shard 1 Replica Set..." -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
@"
rs.initiate({
  _id: "shard1ReplSet",
  members: [
    { _id: 0, host: "shard1-1:27017" }
  ]
})
"@ | docker exec -i sharding-shard1-1 mongosh --port 27017 --quiet
Write-Host "[OK] Shard 1 Replica Set initialized" -ForegroundColor Green
Start-Sleep -Seconds 5

Write-Host ""
Write-Host "Step 4: Initialize Shard 2 Replica Set..." -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
@"
rs.initiate({
  _id: "shard2ReplSet",
  members: [
    { _id: 0, host: "shard2-1:27017" }
  ]
})
"@ | docker exec -i sharding-shard2-1 mongosh --port 27017 --quiet
Write-Host "[OK] Shard 2 Replica Set initialized" -ForegroundColor Green
Start-Sleep -Seconds 5

Write-Host ""
Write-Host "Step 5: Restart mongos..." -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
docker restart sharding-mongos | Out-Null
Write-Host "Waiting for mongos to start..." -ForegroundColor Yellow
Start-Sleep -Seconds 10

Write-Host ""
Write-Host "Step 6: Add shards to cluster..." -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
@"
sh.addShard("shard1ReplSet/shard1-1:27017")
sh.addShard("shard2ReplSet/shard2-1:27017")
sh.status()
"@ | docker exec -i sharding-mongos mongosh --port 27017 --quiet
Write-Host "[OK] Shards added to cluster" -ForegroundColor Green

Write-Host ""
Write-Host "Step 7: Enable sharding for DB and collection..." -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
@"
sh.enableSharding("somedb")
use somedb
db.helloDoc.createIndex({ age: 1 })
sh.shardCollection("somedb.helloDoc", { age: 1 })
"@ | docker exec -i sharding-mongos mongosh --port 27017 --quiet
Write-Host "[OK] Sharding enabled for somedb.helloDoc" -ForegroundColor Green

Write-Host ""
Write-Host "Step 8: Insert test data..." -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
@"
use somedb
for(var i = 0; i < 1000; i++) {
  db.helloDoc.insertOne({age: i, name: "ly" + i})
}
print("Documents inserted: " + db.helloDoc.countDocuments())
"@ | docker exec -i sharding-mongos mongosh --port 27017 --quiet
Write-Host "[OK] Test data inserted" -ForegroundColor Green

Write-Host ""
Write-Host "Step 9: Restart application..." -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
docker restart sharding-pymongo_api | Out-Null
Start-Sleep -Seconds 3

Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "[SUCCESS] Initialization completed!" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Check application:" -ForegroundColor Yellow
Write-Host "  http://localhost:8080" -ForegroundColor Cyan
Write-Host ""
Write-Host "View shard distribution:" -ForegroundColor Yellow
Write-Host "  docker exec sharding-mongos mongosh somedb --eval `"db.helloDoc.getShardDistribution()`"" -ForegroundColor Cyan
Write-Host ""
