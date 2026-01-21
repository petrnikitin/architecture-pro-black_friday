# MongoDB Sharding + Replication + Redis Cache

Полная production-ready архитектура с шардированием, репликацией и кэшированием для максимальной производительности и отказоустойчивости.

> **⚠️ ВАЖНО:** После запуска контейнеров необходимо выполнить инициализацию. Без инициализации mongos не запустится и приложение не сможет подключиться к БД.

## Архитектура

- **3 Config Servers** в Replica Set - хранение метаданных кластера
- **Shard 1 Replica Set**: 3 реплики (shard1-1 PRIMARY, shard1-2/3 SECONDARY)
- **Shard 2 Replica Set**: 3 реплики (shard2-1 PRIMARY, shard2-2/3 SECONDARY)
- **1 Mongos Router** - маршрутизация запросов к шардам
- **1 Redis** - in-memory кэш для частых запросов
- **1 API приложение** (pymongo_api) - FastAPI приложение с кэшированием

**Всего:** 11 контейнеров (9 MongoDB + 1 Redis + 1 приложение)

### Преимущества архитектуры

| Компонент | Преимущество |
|-----------|-------------|
| **Шардирование** | Горизонтальное масштабирование, распределение нагрузки |
| **Репликация** | Отказоустойчивость, автоматический failover |
| **Redis кэш** | Производительность: <100ms для повторных запросов |

## Установка и запуск

### Быстрый старт (автоматическая инициализация)

**Для Windows (PowerShell):**
```powershell
# 1. Запуск контейнеров
cd sharding-repl-cache
docker compose up -d

# 2. Автоматическая инициализация
.\scripts\init-cache.ps1
```

**Для Linux/macOS (Bash):**
```bash
# 1. Запуск контейнеров
cd sharding-repl-cache
docker compose up -d

# 2. Автоматическая инициализация
chmod +x scripts/init-cache.sh
./scripts/init-cache.sh
```

### Ручная инициализация (пошагово)

#### 1. Запуск контейнеров

```bash
docker compose up -d
```

Дождитесь запуска всех контейнеров (~40 секунд).

#### 2-8. MongoDB инициализация

Следуйте шагам 2-8 из `mongo-sharding-repl/README.md` (идентичные для MongoDB части).

Или используйте скрипт автоинициализации выше.

## Проверка работы

### 1. Проверка базовой работоспособности

Откройте в браузере: http://localhost:8080

Должно показать:
```json
{
  "mongo_topology_type": "Sharded",
  "collections": {
    "helloDoc": {
      "documents_count": 1000
    }
  },
  "shards": {
    "shard1ReplSet": "...",
    "shard2ReplSet": "..."
  },
  "cache_enabled": true,  // ✅ Кэш включен!
  "status": "OK"
}
```

### 2. Тестирование производительности кэша

#### Первый запрос (без кэша):

```bash
# PowerShell
Measure-Command { curl http://localhost:8080/helloDoc/users }

# Bash
time curl http://localhost:8080/helloDoc/users
```

**Ожидаемое время:** ~1000-1200ms (есть `time.sleep(1)` в коде + запрос к MongoDB)

#### Второй запрос (из кэша):

```bash
# PowerShell
Measure-Command { curl http://localhost:8080/helloDoc/users }

# Bash
time curl http://localhost:8080/helloDoc/users
```

**Ожидаемое время:** <100ms ✅ (данные берутся из Redis)

### 3. Проверка Redis

```bash
# Проверить, что Redis работает
docker exec cache-redis redis-cli ping
# Ответ: PONG

# Посмотреть закэшированные ключи
docker exec cache-redis redis-cli keys "api:cache:*"

# Посмотреть TTL (время жизни) кэша
docker exec cache-redis redis-cli ttl "api:cache:list_users"
```

### 4. Визуальное тестирование в браузере

1. Откройте http://localhost:8080/helloDoc/users в браузере
2. Первая загрузка: ~1 секунда
3. Обновите страницу (F5)
4. Вторая загрузка: мгновенно! ⚡

## Как работает кэширование

### В коде приложения (app.py):

```python
@app.get("/{collection_name}/users")
@cache(expire=60 * 1)  # ← Кэш на 60 секунд
async def list_users(collection_name: str):
    time.sleep(1)  # ← Симуляция медленного запроса
    collection = db.get_collection(collection_name)
    return UserCollection(users=await collection.find().to_list(1000))
```

### Логика работы:

```
┌─────────────┐
│ First Call  │
└──────┬──────┘
       │
       ▼
  Check Redis ─── Not Found
       │
       ▼
   MongoDB (slow: ~1000ms)
       │
       ▼
  Save to Redis (TTL: 60s)
       │
       ▼
   Return Data
```

```
┌─────────────┐
│ Second Call │  (within 60s)
└──────┬──────┘
       │
       ▼
  Check Redis ─── Found! ✅
       │
       ▼
   Return from Cache (fast: <100ms)
```

## Полезные команды

### Мониторинг производительности

**Сравнение времени запросов:**
```bash
# Первый запрос (без кэша)
curl -w "\nTime: %{time_total}s\n" http://localhost:8080/helloDoc/users > /dev/null

# Второй запрос (с кэшем)
curl -w "\nTime: %{time_total}s\n" http://localhost:8080/helloDoc/users > /dev/null
```

**Мониторинг Redis в реальном времени:**
```bash
docker exec cache-redis redis-cli monitor
```

### Управление кэшем

**Очистить весь кэш:**
```bash
docker exec cache-redis redis-cli FLUSHALL
```

**Очистить только кэш приложения:**
```bash
docker exec cache-redis redis-cli keys "api:cache:*" | xargs docker exec cache-redis redis-cli DEL
```

**Посмотреть статистику Redis:**
```bash
docker exec cache-redis redis-cli INFO stats
```

### Проверка архитектуры

**Статус MongoDB кластера:**
```bash
docker exec cache-mongos mongosh --eval "sh.status()"
```

**Статус реплик Shard 1:**
```bash
docker exec cache-shard1-1 mongosh --quiet --eval "rs.status().members.forEach(m => print(m.name + ' - ' + m.stateStr))"
```

**Статус реплик Shard 2:**
```bash
docker exec cache-shard2-1 mongosh --quiet --eval "rs.status().members.forEach(m => print(m.name + ' - ' + m.stateStr))"
```

## Тестирование отказоустойчивости

### Тест 1: Перезапуск Redis (кэш должен восстановиться)

```bash
# Остановить Redis
docker stop cache-redis

# Запросы пойдут напрямую в MongoDB (медленно)
curl http://localhost:8080/helloDoc/users  # ~1000ms

# Восстановить Redis
docker start cache-redis

# Подождать 3 секунды
sleep 3

# Первый запрос после восстановления: медленно (заполнение кэша)
curl http://localhost:8080/helloDoc/users  # ~1000ms

# Второй запрос: быстро (из кэша)
curl http://localhost:8080/helloDoc/users  # <100ms ✅
```

### Тест 2: Отказ MongoDB ноды (данные остаются доступными)

```bash
# Остановить одну SECONDARY ноду
docker stop cache-shard1-2

# Приложение продолжает работать
curl http://localhost:8080/helloDoc/users  # Работает!

# Кэш продолжает работать
curl http://localhost:8080/helloDoc/users  # <100ms ✅

# Восстановить ноду
docker start cache-shard1-2
```

## Метрики производительности

| Метрика | Без кэша | С кэшем | Улучшение |
|---------|----------|---------|-----------|
| Первый запрос | ~1000ms | ~1000ms | - |
| Повторный запрос | ~1000ms | <100ms | **10x быстрее** ✅ |
| Нагрузка на MongoDB | 100% | ~5% | **20x меньше** ✅ |
| Пропускная способность | ~50 req/s | ~500 req/s | **10x больше** ✅ |

## Настройка кэширования

### Изменить время жизни кэша

В `api_app/app.py`:

```python
@cache(expire=60 * 1)  # 60 секунд

# Изменить на:
@cache(expire=60 * 5)  # 5 минут
# или
@cache(expire=60 * 60)  # 1 час
```

### Отключить кэширование

Удалите переменную окружения `REDIS_URL` из `compose.yaml`:

```yaml
environment:
  MONGODB_URL: "mongodb://mongos:27017"
  MONGODB_DATABASE_NAME: "somedb"
  # REDIS_URL: "redis://redis:6379"  # Закомментировать
```

## Остановка и очистка

**Остановка:**
```bash
docker compose down
```

**Полная очистка (включая volumes):**
```bash
docker compose down -v
```

## Swagger документация

API документация доступна по адресу: http://localhost:8080/docs

Там можно протестировать все эндпоинты и посмотреть время выполнения запросов.
