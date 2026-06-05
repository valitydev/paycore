# Trace API: переход с JSON на Thrift

Документ описывает текущую реализацию ручек получения трейсов из progressor в FF и HG, различия между ними и план перехода на Thrift как формат ответа.

**Ограничения и допущения:**

- Формат **Jaeger выпиливается полностью** (маршруты, unmarshaling, тесты).
- **Dual format / deprecation JSON не нужны** — функциональность не запущена и не используется в проде; можно сразу заменить JSON на Thrift.
- **Единый raw pipeline** (HG через machinery schema, как FF) — за скобками, отдельная задача.

---

## 1. Общая цепочка данных

Оба сервиса читают трейс из **progressor** (`progressor:trace/1` → `prg_storage:process_trace/3`).

Сырой ответ — список **task unit**’ов (агрегация по `task_id` внутри progressor), у каждого unit примерно:

| Поле | Смысл |
|------|--------|
| `task_id`, `task_type`, `task_status` | Идентификация и тип задачи (`init`, `call`, `repair`, `timeout`, …) |
| `scheduled`, `running`, `finished` | Тайминги (микросекунды) |
| `retry_attempts`, `retry_interval`, `task_metadata` | Ретраи и метаданные |
| `args`, `context`, `response` | Бинарные blob’ы (Erlang term / thrift на storage) |
| `events` | Список `{event_id, event_timestamp, event_payload, …}` |

Дальше FF и HG расходятся в **декодировании** и **сериализации на HTTP**.

---

## 2. FF (ff_server)

### 2.1. Текущая схема

| Слой | Модуль / путь |
|------|----------------|
| HTTP | Cowboy (не Woody): `GET /traces/internal/{entity}/{process_id}` |
| Handler | `apps/ff_server/src/ff_machine_handler.erl` |
| Домен | `ff_machine:trace/2` → `machinery:trace/3` → `machinery_prg_backend:trace/3` |
| Декодирование | `ff_*_machinery_schema` + codec (`ff_deposit_codec`, …) |
| Ответ | `json:encode/1` после `ff_machine:json_compatible_value/1` |

Маршруты (`ff_machine_handler:get_routes/0`):

```
/traces/internal/source_v1/:process_id          → ff/source_v1
/traces/internal/destination_v2/:process_id     → ff/destination_v2
/traces/internal/deposit_v1/:process_id         → ff/deposit_v1
/traces/internal/withdrawal_v2/:process_id      → ff/withdrawal_v2
/traces/internal/withdrawal_session_v2/:process_id → ff/withdrawal/session_v2
```

Подключение: `apps/ff_server/src/ff_server.erl` → `additional_routes` ++ `ff_machine_handler:get_routes()`.

### 2.2. Особенности

- На **storage** события уже в Thrift (`machinery_mg_schema` + `ff_proto_utils:serialize/2`).
- На **выдаче в trace** типизация теряется: `json_compatible_value/1` превращает Erlang-термы в произвольные JSON-map’ы (base64 для бинарников, `~p` для неизвестного).
- Паттерн «нормального» API в FF — **Woody + Thrift** (`Management`, `Repairer` на `/v1/...`); trace — исключение.

### 2.3. Пример контракта (из тестов)

`apps/ff_server/test/ff_deposit_handler_SUITE.erl` — массив span’ов с `task_type`, `task_status`, `args`, `events` (`event_id`, `event_payload`, `event_timestamp`).

---

## 3. HG (hellgate)

### 3.1. Текущая схема

| Слой | Модуль / путь |
|------|----------------|
| HTTP | Cowboy: `GET /traces/{format}/{entity}/{process_id}` |
| Handler | `apps/hg_progressor/src/hg_progressor_handler.erl` |
| Домен | Напрямую `progressor:trace/1` (**без** machinery schema) |
| Декодирование | Ручное в handler: `binary_to_term`, `hg_proto_utils:deserialize`, `term_to_object` |
| Ответ | `json:encode/1` |

Маршруты:

```
/traces/{format}/invoice/:process_id
/traces/{format}/invoice_template/:process_id
```

`format`: `internal` | `jaeger` (валидация в `init/2`).

Подключение: `apps/hellgate/src/hellgate.erl` → `hg_progressor_handler:get_routes()`.

### 3.2. Особенности

- **`internal`**: список task unit’ов; args часто как `{content_type: thrift_call, content: {call, params}}` — thrift уже раскрыт, но на wire отдаётся JSON map.
- **`jaeger`**: отдельная JSON-схема под Jaeger UI — **подлежит удалению** (см. раздел 6).
- Namespace-специфичная логика в `unmarshal_args/4` (`invoice`, `invoice_template`, `call` / `repair` / `timeout`).

### 3.3. Тесты

`apps/hellgate/test/hg_invoice_lite_tests_SUITE.erl` — `payment_success_trace/1`: проверки `internal` и `jaeger` URL.

---

## 4. Сравнение FF vs HG

| Аспект | FF | HG |
|--------|----|----|
| Доступ к progressor | `machinery` + schema | напрямую `progressor:trace` |
| Типизация до HTTP | выше (codec + schema) | ad hoc в handler |
| Транспорт | Cowboy GET + JSON | Cowboy GET + JSON |
| Woody на wire | нет | нет |
| Thrift IDL для trace | нет | нет |
| Jaeger | нет | есть (удалить) |

---

## 5. Переход JSON → Thrift

### 5.1. Чего нет сейчас

- Нет thrift-типов `Trace`, `TraceUnit`, `TraceEvent` в damsel / fistful / progressor.
- Нет thrift-метода вроде `GetTrace` — только cowboy routes с JSON.

### 5.2. Главная сложность — полиморфные payload’ы

`args` и `event_payload` зависят от namespace и `task_type`.

Варианты в IDL:

1. **Union per domain** — `DepositTraceEvent`, `InvoiceTraceArgs`, … (строго, больше IDL).
2. **Opaque + typed sidecar** — `ThriftCall { service, function, params }` + `binary fallback` (близко к тому, что HG уже отдаёт в JSON как `thrift_call`).
3. **Только binary** — минимальный IDL, клиент декодирует сам (хуже для отладки).

Рекомендация: формализовать вариант 2 (как текущий `internal` JSON в HG) + domain unions для событий там, где уже есть thrift `Change` / `EventPayload`.

### 5.3. Доставка Thrift

| Путь | Плюсы | Минусы |
|------|--------|--------|
| **A. Woody service** | Как `Repairer` / `Management`, woody errors, codegen-клиенты | Новый path, не «голый» GET в браузере |
| **B. Cowboy + binary thrift body** | Можно оставить GET | Дублирование с woody, ручной Content-Type |

**Рекомендация:** Woody (путь A), единообразно с остальным FF/HG API.

Пример для FF:

```
/v1/trace/deposit      → TraceViewer для deposit_v1
/v1/trace/withdrawal   → …
```

Для HG — отдельный service или методы на sidecar-сервисе для `invoice` / `invoice_template`.

### 5.4. Переиспользование кода

**FF:** после `machinery_prg_backend:trace` данные уже в доменных Erlang-термах → **marshal** через `ff_*_codec` в новые thrift-структуры (аналог `marshal_event` в `ff_*_machinery_schema`).

**HG:** логику из `hg_progressor_handler` (`unmarshal_args`, `unmarshal_events`, `term_to_object`) перенести в **`hg_trace_codec`** с marshal в thrift вместо JSON map.

**Общий слой (в рамках задачи):** marshal общих полей `TraceUnit` (timestamps, task meta, `otel_trace_id`, `error`); domain-specific — в codec по NS.

### 5.5. Миграция

Так как API **не используется**, допустимо **сразу**:

- удалить JSON-encode и cowboy trace routes (или заменить на woody);
- не вводить `format=internal|thrift` и не держать параллельные эндпоинты;
- обновить CT под thrift-клиент.

---

## 6. Удаление Jaeger

Убрать полностью:

| Место | Что удалить |
|-------|-------------|
| `hg_progressor_handler.erl` | валидация `format=jaeger`, `unmarshal_trace/4` и clauses для `jaeger`, `unmarshal_trace_unit` для jaeger, `unmarshal_event` для jaeger, `service_name/1`, `trace_id/2`, `error_tag/1` если используются только jaeger |
| `hg_progressor_handler:get_routes/0` | сегмент `[:format]` → фиксированный internal-only path или переход на woody без format |
| `hg_invoice_lite_tests_SUITE.erl` | `UrlJaeger`, проверки jaeger body |
| Документация / compose | `compose.tracing.yaml` и образ jaeger — **не трогать**, если используются для OTEL в dev; это не HTTP trace API |

После удаления маршрут HG упрощается, например:

```
/traces/invoice/:process_id
/traces/invoice_template/:process_id
```

или полностью заменяется woody path без HTTP format.

---

## 7. Реализация (HG, invoice / invoice_template)

**IDL:** `damsel/proto/progressor_trace.thrift` — сервисы `InvoiceTrace`, `InvoiceTemplateTrace`, метод `GetTrace`.

**Woody:**

| Сервис | Path |
|--------|------|
| `InvoiceTrace` | `/v1/trace/invoice` |
| `InvoiceTemplateTrace` | `/v1/trace/invoice_template` |

**Модули:**

- `hg_progressor_trace` — `progressor:trace` + marshal
- `hg_trace_codec` — raw progressor → thrift
- `hg_progressor_trace_handler` — woody handler

**Удалено:** `hg_progressor_handler` (cowboy JSON, jaeger).

**Зависимость:** после мержа `progressor_trace.thrift` в damsel — поднять tag в `rebar.config` (сейчас `v2.2.33` + TODO).

---

## 8. План работ (остальное)

1. **IDL (FF)** — по аналогии в fistful / отдельный thrift:
   - `Trace = list<TraceUnit>`
   - `TraceUnit` — поля progressor + `TraceArgs` + `list<TraceEvent>`
   - `TraceArgs` / payload — `ThriftCall` + fallback `Content` / `binary`

2. **Codegen** — подключить в `fistful_proto` / damsel, rebar.

3. **FF**
   - `ff_trace_codec` — marshal из результата `ff_machine:trace/2` (убрать `json_compatible_*` из trace path).
   - Woody handler + `ff_services` (path + service spec).
   - Удалить `ff_machine_handler` routes или модуль целиком.
   - Обновить CT (`ff_deposit_handler_SUITE`, `ff_withdrawal_handler_SUITE`, …).

4. **HG**
   - `hg_trace_codec` — вынести логику из `hg_progressor_handler`.
   - Woody handler вместо/вместе с cowboy JSON.
   - Удалить jaeger и `term_to_object` для trace (оставить только thrift marshal).
   - Обновить `hg_invoice_lite_tests_SUITE`.

5. **Не в scope сейчас**
   - Единый pipeline HG через machinery schema.
   - Dual JSON/Thrift.
   - Jaeger HTTP format.

---

## 9. Затрагиваемые файлы

| Компонент | Сейчас | Целевое состояние |
|-----------|--------|-------------------|
| FF HTTP | `ff_machine_handler.erl` | woody trace handler |
| FF домен | `ff_machine.erl` (`json_compatible_*` в trace) | `ff_trace_codec.erl` |
| HG HTTP | `hg_progressor_handler.erl` | woody + `hg_trace_codec` (jaeger удалён) |
| HG регистрация | `hellgate.erl` | woody routes вместо cowboy trace |
| IDL | — | новый `.thrift` |
| Тесты | `ff_*_handler_SUITE`, `hg_invoice_lite_tests_SUITE` | thrift client |

---

## 10. Вывод

- Источник данных один — **progressor**; FF декодирует через **machinery schema**, HG — кастомным handler’ом в JSON.
- Переход на Thrift — это **IDL + codec + woody**, а не замена одной строки `json:encode`.
- FF проще (данные ближе к доменным thrift-типам); HG — перенос unmarshaling из handler в `hg_trace_codec` + marshal.
- **Jaeger HTTP format удаляется**; OTEL/Jaeger в compose для dev — отдельная история.
- **Обратная совместимость JSON не требуется** — можно резать сразу.
