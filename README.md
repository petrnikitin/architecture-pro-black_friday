# pymongo-api

## Как запустить

Запускаем mongodb и приложение

```shell
docker compose up -d
```

Заполняем mongodb данными

```shell
./scripts/mongo-init.sh
```

## Как проверить

### Если вы запускаете проект на локальной машине

Откройте в браузере http://localhost:8080

### Если вы запускаете проект на предоставленной виртуальной машине

Узнать белый ip виртуальной машины

```shell
curl --silent http://ifconfig.me
```

Откройте в браузере http://<ip виртуальной машины>:8080

## Доступные эндпоинты

Список доступных эндпоинтов, swagger http://<ip виртуальной машины>:8080/docs

---

## Проектная работа 4 спринта

### Задание 1. Планирование архитектуры

Файл: `diagrams/task1-3-tabs.drawio`

Созданы 3 схемы эволюции архитектуры:

**Step 1: Sharding** - внедрение шардирования для горизонтального масштабирования
- mongos (router) для маршрутизации запросов
- 3 config servers для хранения метаданных кластера
- 2 шарда (shard1, shard2) для распределения данных

**Step 2: Replication** - добавление отказоустойчивости через репликацию
- Config servers replica set: 3 ноды (1 PRIMARY, 2 SECONDARY)
- Shard1 replica set: 3 ноды (shard1-1 PRIMARY, shard1-2/3 SECONDARY)
- Shard2 replica set: 3 ноды (shard2-1 PRIMARY, shard2-2/3 SECONDARY)

**Step 3: Caching** - снижение нагрузки на БД через кэширование
- Redis для кэширования частых запросов
- Двусторонняя связь приложения с Redis

### Задание 2. Шардирование

Директория: `mongo-sharding/`

Реализовано шардирование MongoDB (Step 1 схемы):
- compose.yaml с именем проекта `mongo-sharding`
- 3 config servers в replica set (configSrv1-3)
- 2 шарда, каждый в своём replica set (shard1-1, shard2-1)
- mongos router для маршрутизации запросов
- БД `somedb`, коллекция `helloDoc`
- Шардирование по полю `age`
- Автоматическая инициализация через PowerShell/Bash скрипты

Инструкции по запуску и инициализации в `mongo-sharding/README.md`

### Задание 3. Репликация

Директория: `mongo-sharding-repl/`

Реализовано шардирование + репликация (Step 2 схемы):
- compose.yaml с именем проекта `mongo-sharding-repl`
- 3 config servers в replica set
- **Shard 1**: 3 реплики (shard1-1 PRIMARY, shard1-2/3 SECONDARY)
- **Shard 2**: 3 реплики (shard2-1 PRIMARY, shard2-2/3 SECONDARY)
- mongos router
- Всего: 10 контейнеров (9 MongoDB нод + приложение)
- Повышенная отказоустойчивость через репликацию
- Автоматический failover при падении PRIMARY
- Автоматическая инициализация через PowerShell/Bash скрипты

Инструкции по запуску и тестированию отказоустойчивости в `mongo-sharding-repl/README.md`

### Задание 4. Кэширование

Директория: `sharding-repl-cache/`

Реализовано шардирование + репликация + кэширование (Step 3 схемы):
- compose.yaml с именем проекта `sharding-repl-cache`
- Полная архитектура из Задания 3 +
- **Redis** для in-memory кэширования
- `REDIS_URL` переменная окружения для включения кэша
- Всего: 11 контейнеров (9 MongoDB + 1 Redis + 1 app)

**Производительность:**
- Первый запрос: ~1000ms (MongoDB)
- Повторный запрос: <100ms ✅ (Redis cache)
- Кэш на 60 секунд для эндпоинта `/{collection}/users`
- 10x улучшение производительности

Инструкции по запуску и тестированию кэша в `sharding-repl-cache/README.md`