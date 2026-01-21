# Архитектурный документ: Масштабирование интернет-магазина "Мобильный мир"

## Оглавление
1. [Задание 7: Проектирование схем коллекций для шардирования](#задание-7-проектирование-схем-коллекций-для-шардирования)
2. [Задание 8: Выявление и устранение горячих шардов](#задание-8-выявление-и-устранение-горячих-шардов)
3. [Задание 9: Настройка чтения с реплик и консистентность](#задание-9-настройка-чтения-с-реплик-и-консистентность)
4. [Задание 10: Миграция на Cassandra](#задание-10-миграция-на-cassandra)

---

# Задание 7: Проектирование схем коллекций для шардирования

## Обзор архитектуры

Интернет-магазин "Мобильный мир" хранит данные в трех коллекциях MongoDB:
- **products** - товары с остатками по геозонам
- **orders** - заказы клиентов с историей
- **carts** - активные корзины (гостевые и пользовательские)

## 1. Коллекция products

### Схема документа

```javascript
{
  "_id": ObjectId("..."),
  "product_id": "PROD-12345",
  "name": "Смартфон X",
  "category": "Электроника",
  "price": 45000,
  "stock_by_zone": {
    "moscow": 100,
    "ekaterinburg": 50,
    "kaliningrad": 30
  },
  "attributes": {
    "color": "черный",
    "size": "6.5 дюймов"
  },
  "created_at": ISODate("2025-01-15T10:00:00Z"),
  "updated_at": ISODate("2025-01-20T14:30:00Z")
}
```

### Шард-ключ: `{category: 1, product_id: 1}`

**Тип шардирования**: Range-based

**Обоснование выбора:**

| Критерий | Оценка | Пояснение |
|----------|--------|-----------|
| Кардинальность | ✅ Высокая | Комбинация категории и ID обеспечивает уникальность |
| Изоляция запросов | ✅ Да | Поиск по категории выполняется на подмножестве шардов |
| Равномерность | ✅ Хорошая | Товары разных категорий распределяются равномерно |
| Монотонность | ✅ Не монотонна | Новые категории не создают "горячую точку" |

**Преимущества:**
- Запросы вида `db.products.find({category: "Электроника"})` изолированы на конкретных шардах
- Обновления остатков локализованы (не требуют broadcast)
- Новые товары добавляются в разные категории → нагрузка распределена

**Риски:**
- Популярная категория (70% запросов) может создать "горячий" шард
- Требуется разделение больших категорий на чанки

### Команды настройки

```javascript
// 1. Создать индекс для шард-ключа
db.products.createIndex({category: 1, product_id: 1});

// 2. Дополнительные индексы
db.products.createIndex({category: 1, price: 1});
db.products.createIndex({product_id: 1});

// 3. Настроить шардирование
sh.enableSharding("mobile_world");
sh.shardCollection("mobile_world.products", {category: 1, product_id: 1});

// 4. Проверить распределение
db.products.getShardDistribution();
```

---

## 2. Коллекция orders

### Схема документа

```javascript
{
  "_id": ObjectId("..."),
  "order_id": "ORD-2025-001234",
  "customer_id": "CUST-987654",
  "geo_zone": "moscow",
  "items": [
    {
      "product_id": "PROD-12345",
      "name": "Смартфон X",
      "category": "Электроника",
      "price": 45000,
      "quantity": 1
    }
  ],
  "total_amount": 48000,
  "status": "processing",
  "created_at": ISODate("2025-01-20T15:30:00Z"),
  "updated_at": ISODate("2025-01-20T15:45:00Z")
}
```

### Шард-ключ: `{customer_id: 1, created_at: 1}`

**Тип шардирования**: Range-based

**Обоснование выбора:**

| Критерий | Оценка | Пояснение |
|----------|--------|-----------|
| Кардинальность | ✅ Высокая | ID клиента + время = уникальная комбинация |
| Изоляция запросов | ✅ Да | История заказов клиента на одном шарде |
| Равномерность | ✅ Хорошая | Новые клиенты распределяются случайно |
| Монотонность | ⚠️ Частично | created_at монотонна, но customer_id случаен |

**Преимущества:**
- Запрос истории клиента: `db.orders.find({customer_id: "CUST-123"})` → 1 шард
- Сортировка по времени встроена в ключ
- Новые заказы распределяются равномерно (разные клиенты)

**Риски:**
- VIP-клиенты с большим количеством заказов могут создать большую партицию
- Запросы по `geo_zone` без `customer_id` требуют broadcast

### Команды настройки

```javascript
// 1. Создать индекс
db.orders.createIndex({customer_id: 1, created_at: 1});

// 2. Дополнительные индексы
db.orders.createIndex({order_id: 1});
db.orders.createIndex({customer_id: 1, status: 1});
db.orders.createIndex({geo_zone: 1, created_at: -1});

// 3. Настроить шардирование
sh.shardCollection("mobile_world.orders", {customer_id: 1, created_at: 1});

// 4. Проверить распределение
db.orders.getShardDistribution();
```

---

## 3. Коллекция carts

### Схема документа

```javascript
{
  "_id": ObjectId("..."),
  "user_id": "CUST-987654",       // null для гостей
  "session_id": "sess_abc123xyz",
  "items": [
    {
      "product_id": "PROD-12345",
      "quantity": 1
    }
  ],
  "status": "active",              // "active" | "ordered" | "abandoned"
  "created_at": ISODate("2025-01-20T10:00:00Z"),
  "updated_at": ISODate("2025-01-20T14:30:00Z"),
  "expires_at": ISODate("2025-01-27T10:00:00Z")  // TTL
}
```

### Шард-ключ: `{session_id: "hashed"}`

**Тип шардирования**: Hashed

**Обоснование выбора:**

| Критерий | Оценка | Пояснение |
|----------|--------|-----------|
| Кардинальность | ✅ Высокая | session_id уникален для каждой сессии |
| Изоляция запросов | ✅ Да | Точечный доступ по session_id |
| Равномерность | ✅ Идеальная | Хеширование обеспечивает равномерное распределение |
| Монотонность | ✅ Не монотонна | Хеш случаен |

**Преимущества:**
- Идеальное распределение нагрузки (критично для Black Friday)
- Нет "горячих" шардов даже при 100K активных корзин
- Поддержка гостевых корзин (session_id всегда есть, user_id может быть null)

**Риски:**
- Диапазонные запросы невозможны (например, "все активные корзины")
- Запросы без session_id требуют broadcast

### Команды настройки

```javascript
// 1. Создать хешированный индекс
db.carts.createIndex({session_id: "hashed"});

// 2. TTL индекс для автоматической очистки
db.carts.createIndex({expires_at: 1}, {expireAfterSeconds: 0});

// 3. Дополнительные индексы
db.carts.createIndex({user_id: 1, status: 1});

// 4. Настроить шардирование
sh.shardCollection("mobile_world.carts", {session_id: "hashed"});

// 5. Проверить распределение
db.carts.getShardDistribution();
```

---

## Итоговая таблица стратегий

| Коллекция | Шард-ключ | Тип | Преимущества | Риски |
|-----------|-----------|-----|--------------|-------|
| **products** | `{category, product_id}` | Range | Изоляция по категориям | Популярная категория = горячий шард |
| **orders** | `{customer_id, created_at}` | Range | История клиента на 1 шарде | VIP клиенты = большие партиции |
| **carts** | `{session_id: hashed}` | Hashed | Идеальное распределение | Нет range queries |

---

# Задание 8: Выявление и устранение горячих шардов

## Проблема

**Ситуация**: Категория "Электроника" получает 70% всех запросов → перегрузка одного шарда.

```
Shard 1 (ПЕРЕГРУЖЕН 🔥):
├── category: "Электроника" (70% запросов)
│   ├── 10000 запросов/сек
│   └── CPU: 95%, Memory: 90%

Shard 2 (Недогружен):
├── Остальные категории (30% запросов)
│   ├── 3000 запросов/сек
│   └── CPU: 30%, Memory: 40%
```

---

## Метрики мониторинга

### Ключевые метрики

| Метрика | Норма | Внимание | Критично |
|---------|-------|----------|----------|
| CPU utilization | < 70% | 70-85% | > 85% |
| Memory usage | < 75% | 75-90% | > 90% |
| Query latency (p95) | < 200ms | 200-500ms | > 500ms |
| Chunk imbalance | < 20% | 20-40% | > 40% |
| Ops per second (дисбаланс) | < 30% | 30-50% | > 50% |

### Команды мониторинга

```javascript
// 1. Общий статус шардов
sh.status();
db.products.getShardDistribution();

// 2. Активные операции по шардам
db.getSiblingDB("admin").aggregate([
  {$currentOp: {allUsers: true}},
  {$group: {
    _id: "$shard",
    activeOps: {$sum: 1},
    readOps: {$sum: {$cond: [{$eq: ["$op", "query"]}, 1, 0]}}
  }}
]);

// 3. Анализ популярных категорий
db.setProfilingLevel(1, {slowms: 100});
db.system.profile.aggregate([
  {$match: {ns: "mobile_world.products"}},
  {$group: {
    _id: "$command.filter.category",
    count: {$sum: 1},
    avgMs: {$avg: "$millis"}
  }},
  {$sort: {count: -1}}
]);

// 4. Поиск jumbo chunks
db.getSiblingDB("config").chunks.find({
  ns: "mobile_world.products",
  jumbo: true
});
```

---

## Решения для устранения горячих шардов

### Решение 1: Разделение jumbo chunks (быстрое)

**Время**: 10-20 минут | **Эффект**: 40-50% снижение нагрузки

```javascript
// Разделить категорию "Электроника" на 4 части
sh.splitAt("mobile_world.products", {
  category: "Электроника",
  product_id: "PROD-5000"
});

sh.splitAt("mobile_world.products", {
  category: "Электроника",
  product_id: "PROD-10000"
});

sh.splitAt("mobile_world.products", {
  category: "Электроника",
  product_id: "PROD-15000"
});

// Переместить чанки на другие шарды
sh.moveChunk("mobile_world.products",
  {category: "Электроника", product_id: "PROD-5000"},
  "shard02"
);

sh.moveChunk("mobile_world.products",
  {category: "Электроника", product_id: "PROD-10000"},
  "shard03"
);
```

### Решение 2: Zone Sharding (средняя сложность)

**Время**: 1-2 часа | **Эффект**: 50% снижение нагрузки

```javascript
// Выделить 2 шарда для популярной категории
sh.addShardToZone("shard01", "electronics");
sh.addShardToZone("shard02", "electronics");
sh.addShardToZone("shard03", "other");

// Привязать диапазоны к зонам
sh.updateZoneKeyRange(
  "mobile_world.products",
  {category: "Электроника", product_id: MinKey},
  {category: "Электроника", product_id: MaxKey},
  "electronics"
);

sh.updateZoneKeyRange(
  "mobile_world.products",
  {category: "Аудио", product_id: MinKey},
  {category: "Книги", product_id: MaxKey},
  "other"
);

sh.startBalancer();
```

### Решение 3: Read Preference (быстрое)

**Время**: 5 минут | **Эффект**: 30-50% снижение нагрузки на PRIMARY

```javascript
// В коде приложения
const { ReadPreference } = require('mongodb');

db.products.find({category: "Электроника"})
  .readPref(ReadPreference.SECONDARY_PREFERRED)
  .toArray();
```

---

## Превентивные меры

### 1. Автоматический балансировщик

```javascript
// Включить балансировщик 24/7
db.getSiblingDB("config").settings.updateOne(
  {_id: "balancer"},
  {$set: {activeWindow: {start: "00:00", stop: "23:59"}}},
  {upsert: true}
);

// Уменьшить размер чанка
db.getSiblingDB("config").settings.updateOne(
  {_id: "chunksize"},
  {$set: {value: 32}},  // 32MB вместо 64MB
  {upsert: true}
);

sh.startBalancer();
```

### 2. Pre-splitting для новых категорий

```javascript
function presplitCategory(category, numSplits = 10) {
  for (let i = 1; i < numSplits; i++) {
    const productId = `PROD-${(i * 1000).toString().padStart(6, '0')}`;
    sh.splitAt("mobile_world.products", {
      category: category,
      product_id: productId
    });
  }
}

presplitCategory("Смартфоны", 10);
```

---

## Итоговая таблица решений

| Решение | Сложность | Время | Эффект | Когда использовать |
|---------|-----------|-------|--------|-------------------|
| **Read Preference** | Низкая | 5 мин | 30% | Проблема с чтением |
| **Split + Move** | Средняя | 20 мин | 40% | Jumbo chunks |
| **Zone Sharding** | Высокая | 2 часа | 50% | Постоянная популярная категория |

---

# Задание 9: Настройка чтения с реплик и консистентность

## Стратегия Read Preference по коллекциям

### 1. Коллекция products

| Операция | Read Preference | Макс. lag | Обоснование |
|----------|----------------|-----------|-------------|
| Поиск товаров | `secondaryPreferred` | 10 сек | Некритично показать цену с задержкой |
| Карточка товара | `secondaryPreferred` | 10 сек | Допустимо устаревшее описание |
| **Проверка остатка** | `primary` | 0 сек | Риск продажи несуществующего товара |
| Обновление остатка | `primary` | 0 сек | Запись всегда на PRIMARY |

**Распределение**: 80% SECONDARY, 20% PRIMARY

```javascript
// Поиск товаров - SECONDARY
async function searchProducts(category) {
  return await db.collection('products')
    .find({category: category})
    .readPref(ReadPreference.SECONDARY_PREFERRED)
    .toArray();
}

// Проверка остатка - PRIMARY
async function checkStock(productId, quantity) {
  return await db.collection('products')
    .findOne(
      {product_id: productId, 'stock_by_zone.moscow': {$gte: quantity}},
      {readPreference: ReadPreference.PRIMARY}
    );
}
```

---

### 2. Коллекция orders

| Операция | Read Preference | Макс. lag | Обоснование |
|----------|----------------|-----------|-------------|
| История заказов | `secondary` | 30 сек | Некритично, если заказ появится с задержкой |
| Просмотр статуса | `secondary` | 30 сек | Статус меняется редко |
| **Создание заказа** | `primary` | 0 сек | Немедленное подтверждение после оплаты |
| Аналитика | `secondary` | 60+ сек | Разгрузка PRIMARY |

**Распределение**: 70% SECONDARY, 30% PRIMARY

```javascript
// История заказов - SECONDARY
async function getOrderHistory(customerId) {
  return await db.collection('orders')
    .find({customer_id: customerId})
    .sort({created_at: -1})
    .readPref(ReadPreference.SECONDARY)
    .toArray();
}

// Создание заказа - PRIMARY
async function createOrder(orderData) {
  return await db.collection('orders')
    .insertOne(orderData, {
      writeConcern: {w: 'majority', wtimeout: 5000}
    });
}
```

---

### 3. Коллекция carts

| Операция | Read Preference | Макс. lag | Обоснование |
|----------|----------------|-----------|-------------|
| **Все операции** | `primary` | 0 сек | Критично для UX, любая задержка недопустима |

**Распределение**: 100% PRIMARY

```javascript
// ВСЕ операции с корзиной - PRIMARY
async function getActiveCart(userId) {
  return await db.collection('carts')
    .findOne(
      {user_id: userId, status: 'active'},
      {readPreference: ReadPreference.PRIMARY}
    );
}
```

**Риск при использовании SECONDARY**:
- Пользователь добавил товар → не видит в корзине → добавляет снова
- 1 секунда lag × 100K пользователей = 1000+ дубликатов

---

## Настройка maxStalenessSeconds

```javascript
const client = new MongoClient(uri, {
  readPreference: {
    mode: 'secondaryPreferred',
    maxStalenessSeconds: 10  // Не использовать реплику с lag > 10 сек
  }
});

// Для products (допустимо 10 сек)
db.collection('products').find({category: 'Электроника'})
  .readPref(ReadPreference.SECONDARY_PREFERRED, [
    {maxStalenessSeconds: 10}
  ]);

// Для orders (допустимо 30 сек)
db.collection('orders').find({customer_id: 'CUST-123'})
  .readPref(ReadPreference.SECONDARY_PREFERRED, [
    {maxStalenessSeconds: 30}
  ]);
```

---

## Мониторинг replication lag

```javascript
function checkReplicationLag() {
  const rsStatus = db.adminCommand({replSetGetStatus: 1});

  rsStatus.members.forEach(member => {
    if (member.stateStr === 'SECONDARY') {
      const lag = rsStatus.members[0].optimeDate - member.optimeDate;
      const lagSeconds = Math.round(lag / 1000);

      console.log(`${member.name}: ${lagSeconds}s lag`);

      if (lagSeconds > 30) {
        console.warn(`⚠️ High lag: ${lagSeconds}s`);
        // Переключить все на PRIMARY
      }
    }
  });
}
```

---

## Сводная таблица

| Коллекция | % PRIMARY | % SECONDARY | Макс. lag | Критичность |
|-----------|-----------|-------------|-----------|-------------|
| **products** | 20% | 80% | 10 сек | Средняя (проверка остатков) |
| **orders** | 30% | 70% | 30 сек | Низкая (история) |
| **carts** | 100% | 0% | N/A | Высокая (UX) |

**Итог**: Разгрузка PRIMARY на 60-70% без потери критичной консистентности.

---

# Задание 10: Миграция на Cassandra

## Проблема MongoDB при 50K req/sec

**Black Friday нагрузка**:
- Добавление новых шардов → полная миграция данных (balancer)
- Просадка latency в пик нагрузки
- Range-based sharding → "горячие" категории

**Решение**: Гибридная архитектура MongoDB + Cassandra

---

## Какие данные мигрировать

| Данные | БД | Причина |
|--------|-----|---------|
| **Сессии пользователей** | Cassandra | Write-heavy, TTL, короткоживущие |
| **История заказов** | Cassandra | Time-series, append-only |
| **Логи активности** | Cassandra | Огромный объем, некритичные |
| Товары | MongoDB | Сложные запросы, фильтры |
| Корзины | MongoDB | Строгая консистентность |
| Активные заказы | MongoDB | Транзакции |

---

## Модели данных Cassandra

### 1. Сессии пользователей

```sql
CREATE TABLE user_sessions (
    user_id TEXT,              -- Partition key
    session_id TIMEUUID,       -- Clustering key
    created_at TIMESTAMP,
    last_activity TIMESTAMP,
    ip_address TEXT,
    user_agent TEXT,
    PRIMARY KEY (user_id, session_id)
) WITH CLUSTERING ORDER BY (session_id DESC)
  AND default_time_to_live = 86400;  -- 24 часа TTL
```

**Обоснование**:
- **Partition key = user_id**: Все сессии пользователя в одной партиции
- **Clustering = session_id (TIMEUUID)**: Автосортировка по времени
- **TTL 24ч**: Автоматическая очистка старых сессий
- **Нет горячих партиций**: user_id распределены случайно

**Запросы**:
```sql
-- Получить последнюю активную сессию
SELECT * FROM user_sessions
WHERE user_id = 'CUST-123'
LIMIT 1;
```

---

### 2. История заказов (Time-series)

```sql
CREATE TABLE order_history (
    customer_id TEXT,           -- Partition key (часть 1)
    order_month TEXT,           -- Partition key (часть 2) - "2025-01"
    created_at TIMESTAMP,       -- Clustering key 1
    order_id TEXT,              -- Clustering key 2
    total_amount DECIMAL,
    status TEXT,
    items LIST<FROZEN<order_item>>,
    PRIMARY KEY ((customer_id, order_month), created_at, order_id)
) WITH CLUSTERING ORDER BY (created_at DESC);

CREATE TYPE order_item (
    product_id TEXT,
    name TEXT,
    price DECIMAL,
    quantity INT
);
```

**Обоснование**:
- **Composite partition = (customer_id, order_month)**:
  - Избегаем огромных партиций (все заказы клиента за все время)
  - 1 партиция = заказы за 1 месяц (~10-20 заказов, ~1-2MB)
- **Clustering = (created_at DESC)**: Новые заказы первыми
- **TimeWindowCompactionStrategy**: Оптимизация для time-series

**Почему не просто customer_id?**
```
❌ Плохо: PRIMARY KEY (customer_id, created_at)
   1000 заказов за 5 лет = огромная партиция >100MB

✅ Хорошо: PRIMARY KEY ((customer_id, order_month), created_at)
   1000 заказов / 60 месяцев = ~17 заказов/партиция ~1-2MB
```

**Запросы**:
```sql
-- История за текущий месяц
SELECT * FROM order_history
WHERE customer_id = 'CUST-123'
  AND order_month = '2025-01'
LIMIT 10;
```

---

### 3. Логи активности

```sql
CREATE TABLE activity_logs (
    date TEXT,                  -- Partition key - "2025-01-20"
    hour INT,                   -- Clustering key 1 (0-23)
    event_time TIMEUUID,        -- Clustering key 2
    user_id TEXT,
    event_type TEXT,            -- "page_view", "add_to_cart"
    page_url TEXT,
    product_id TEXT,
    PRIMARY KEY ((date), hour, event_time)
) WITH default_time_to_live = 7776000;  -- 90 дней
```

**Обоснование**:
- **Partition key = date**: Все события дня в одной партиции
- **Clustering = (hour, event_time)**: Эффективные range queries
- **TTL 90 дней**: Автоудаление старых логов
- **Write-optimized**: Append-only, 50K+ writes/sec

---

## Стратегии целостности данных

### Consistency Levels

| Уровень | Формула | Консистентность | Latency |
|---------|---------|-----------------|---------|
| **ONE** | 1 нода | Слабая | Низкая |
| **QUORUM** | (RF/2)+1 | Сильная | Средняя |
| **ALL** | Все ноды | Максимальная | Высокая |

### Настройки по сущностям

| Сущность | Write CL | Read CL | Hinted Handoff | Read Repair | Anti-Entropy | Обоснование |
|----------|----------|---------|----------------|-------------|--------------|-------------|
| **user_sessions** | ONE | ONE | ✅ ON | 10% | ❌ OFF | Скорость > консистентность, TTL 24ч |
| **order_history** | QUORUM | ONE | ✅ ON | 100% | ✅ Weekly | Критичные данные, нельзя потерять |
| **activity_logs** | ONE | ONE | ✅ ON | ❌ OFF | ❌ OFF | Некритичные, огромный объем |

### Примеры запросов

```sql
-- Сессии: быстрая запись (ONE)
INSERT INTO user_sessions (user_id, session_id, created_at)
VALUES ('CUST-123', now(), '2025-01-20 10:00:00')
USING TTL 86400
WITH CONSISTENCY ONE;

-- История заказов: надежная запись (QUORUM)
INSERT INTO order_history (customer_id, order_month, created_at, order_id, total_amount)
VALUES ('CUST-123', '2025-01', '2025-01-20 10:00:00', 'ORD-001', 1500.00)
WITH CONSISTENCY QUORUM;

-- Логи: максимальная скорость (ONE)
INSERT INTO activity_logs (date, hour, event_time, user_id, event_type)
VALUES ('2025-01-20', 14, now(), 'CUST-123', 'page_view')
WITH CONSISTENCY ONE;
```

---

## Топология кластера Cassandra

### Конфигурация для 3 датацентров

```yaml
# cassandra.yaml
cluster_name: 'mobile_world_cluster'

# Replication Factor = 3 в каждом DC
# Total replicas = 9 (3 DC × 3 RF)

keyspace_definition: |
  CREATE KEYSPACE mobile_world
  WITH replication = {
    'class': 'NetworkTopologyStrategy',
    'DC_Moscow': 3,
    'DC_Ekaterinburg': 3,
    'DC_Kaliningrad': 3
  };

hinted_handoff_enabled: true
max_hint_window_in_ms: 10800000  # 3 часа
```

### Anti-Entropy Repair

```bash
# Repair конкретной таблицы (раз в неделю)
nodetool repair mobile_world order_history

# Full repair всего keyspace
nodetool repair mobile_world

# Incremental repair (быстрее)
nodetool repair -inc mobile_world
```

---

## Преимущества Cassandra в Black Friday

### Сравнение MongoDB vs Cassandra

| Характеристика | MongoDB | Cassandra |
|----------------|---------|-----------|
| **Масштабирование** | Полная миграция данных | Только 1/N данных перераспределяется |
| **Availability** | PRIMARY election (10-30 сек) | Leaderless (0 сек downtime) |
| **Write throughput** | Ограничен PRIMARY | Линейный рост |
| **Latency при добавлении нод** | Просадка | Стабильна |

### Ожидаемые результаты

**До (MongoDB only):**
- Write throughput: 15K writes/sec (bottleneck на PRIMARY)
- Latency при масштабировании: Просадка на 50-100ms
- Availability: 99.9% (риск PRIMARY failure)

**После (MongoDB + Cassandra):**
- Write throughput: 50K+ writes/sec (сессии, логи в Cassandra)
- Latency при масштабировании: Стабильна (consistent hashing)
- Availability: 99.99% (leaderless Cassandra)
- Geo-replication: Пользователи читают из ближайшего DC

---

## Диаграмма гибридной архитектуры

```
┌─────────────────────────────────────────┐
│         Application Layer               │
│    (Load Balancer + API Gateway)        │
└─────────────────┬───────────────────────┘
                  │
        ┌─────────┴─────────┐
        │                   │
        ▼                   ▼
┌───────────────────┐   ┌──────────────────┐
│    Cassandra      │   │     MongoDB      │
│   (3 DC × 3 RF)   │   │  (3 shards × 3)  │
├───────────────────┤   ├──────────────────┤
│ • Сессии          │   │ • Товары         │
│   (15K writes/s)  │   │   (category key) │
│                   │   │                  │
│ • История заказов │   │ • Корзины        │
│   (time-series)   │   │   (hashed key)   │
│                   │   │                  │
│ • Логи            │   │ • Активные       │
│   (50K writes/s)  │   │   заказы         │
│                   │   │   (transactions) │
├───────────────────┤   ├──────────────────┤
│ Consistency:      │   │ Consistency:     │
│ • ONE/QUORUM      │   │ • Majority       │
│ • Eventual        │   │ • Strong         │
│                   │   │                  │
│ Advantages:       │   │ Advantages:      │
│ • Write-heavy     │   │ • ACID           │
│ • Leaderless      │   │ • Complex        │
│ • TTL             │   │   queries        │
│ • Geo-repl        │   │ • Aggregations   │
└───────────────────┘   └──────────────────┘
```

---

## Итоговая таблица: распределение нагрузки

| Метрика | MongoDB only | MongoDB + Cassandra |
|---------|--------------|---------------------|
| **Write throughput** | 15K/sec | 65K/sec (15K MongoDB + 50K Cassandra) |
| **Сессии (writes)** | 15K/sec → PRIMARY bottleneck | 15K/sec → Cassandra (распределено) |
| **История заказов** | 2K/sec → PRIMARY | 2K/sec → Cassandra (append-only) |
| **Логи активности** | Не хранятся | 50K/sec → Cassandra |
| **Latency p95** | 150ms (PRIMARY перегружен) | 50ms (нагрузка распределена) |
| **Availability** | 99.9% (риск PRIMARY failure) | 99.99% (leaderless) |
| **Масштабирование** | Просадка latency при добавлении шардов | Без просадок (consistent hashing) |

---

## Метрики мониторинга (общие для заданий 7-10)

### Критические метрики

| Метрика | MongoDB | Cassandra | Критичный порог |
|---------|---------|-----------|-----------------|
| **CPU** | PRIMARY & SECONDARY | Все ноды | > 85% |
| **Memory** | PRIMARY & SECONDARY | Все ноды | > 90% |
| **Disk I/O** | Все узлы | Все ноды | > 80% |
| **Replication lag** | SECONDARY lag | N/A | > 30 сек |
| **Write latency (p95)** | PRIMARY | Все ноды | > 100ms |
| **Read latency (p95)** | PRIMARY & SECONDARY | Все ноды | > 200ms |
| **Chunk imbalance** | Shards | N/A | > 40% |
| **Failed writes** | PRIMARY | Все ноды | > 1% |
| **Node availability** | Replica set | Ring | < 99.9% |
| **Compaction pending** | N/A | Все ноды | > 10 tasks |

### Действия при проблемах

| Проблема | Признаки | Действия |
|----------|----------|----------|
| **Горячий шард (MongoDB)** | CPU > 85%, chunk imbalance > 40% | 1. Split jumbo chunks<br>2. Zone sharding<br>3. Read preference → SECONDARY |
| **High replication lag** | Lag > 30 сек | 1. Переключить reads на PRIMARY<br>2. Проверить сеть<br>3. Добавить ресурсы SECONDARY |
| **Cassandra node down** | Node unreachable | 1. Автоматический failover (leaderless)<br>2. Запустить hinted handoff<br>3. Repair после восстановления |
| **Write bottleneck (MongoDB)** | PRIMARY CPU > 90% | 1. Проверить индексы<br>2. Write concern → {w: 1}<br>3. Migrate write-heavy to Cassandra |
| **Compaction lag (Cassandra)** | Pending > 10 | 1. Увеличить compaction throughput<br>2. Добавить ноды<br>3. Проверить disk I/O |

---
