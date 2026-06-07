# `add_prg_layer`: что осталось и техдолг

Актуально для ветки `add_prg_layer` → merge target `epic/monorepo`.

## Закрыто

| # | Пункт | Что сделано |
|---|-------|-------------|
| 1 | Зависимость `machinery` в FF prod | `ff_msgpack` + `ff_machine_schema` в `ff_core`; `machinery`/`machinery_extra` убраны из `ff_transfer.app.src`; app `machinery_extra` удалён |
| 2 | Мёртвый код в `machinery_extra` | `machinery_gensrv_backend*` удалены вместе с app |
| 3 | FF `marshal_event_body` — разные timestamp | Все FF-домены: `{prg_machine:timestamp(), 0}` |
| 4 | FF `process_notification` — пустые `#{}` | Явный noop: `#{events => [], action => progressor_action:instant()}` |
| 7 | `binary_to_term` без `[safe]` | Было закрыто ранее |
| — | Elvis / docs мусор | Убраны ignore для несуществующих модулей; review-plan и migration-context синхронизированы |

`{machinery, …}` в корневом `rebar.config` **остаётся** — только для docker-sidecar тестов (`test/bender`, `test/party-management` → `machinery_prg_backend`).

---

## Открытый техдолг (низкий приоритет)

### 5. HG invoice — двойной collapse

- `prg_machine:collapse` → `apply_event/4` → `collapse_changes`
- `handle_call` → `validate_changes` → снова `collapse_changes` по in-memory state

Работает, но дублирование. Целевой паттерн — один путь через `prg_machine:collapse` (отдельный goal).

### 6. Registry без ETS `heir`

`prg_machine_registry` при падении пересоздаёт таблицу и перерегистрирует handlers из child_spec. Краткое окно без таблицы теоретически возможно.

**Действие:** `heir` на supervisor — только если понадобится zero-downtime.

### L1 (косметика). Фиктивная обёртка `{ev, Ts, Body}` в payload

Progressor ставит timestamp в storage; в thrift-payload ts по-прежнему фиктивный, но единообразный. Полный отказ от обёртки потребует смены wire-формата `TimestampedChange`.

---

## Grep-инварианты (prod FF/HG)

```bash
rg 'machinery_msgpack|machinery_extra|machinery_time' apps/fistful apps/ff_transfer apps/ff_server --glob '*.erl'  # 0
rg 'machinery' apps/ff_transfer/src/ff_transfer.app.src                                                  # 0
rg 'machinery_prg_backend|ff_machine:' apps/fistful apps/ff_transfer apps/ff_server --glob '*.erl'       # 0
rg "client => machinery_prg_backend" config/sys.config                                                   # 0
```
