# Ревью ветки `add_prg_layer` (vs `epic/monorepo`) и план доработки

Строгое ревью миграции HG/FF на единый `prg_machine`-runtime поверх `progressor`.
Diff `+3725 / −3979`, 91 файл, 11 коммитов. `rebar3 compile` проходит, grep-инварианты по prod-путям чистые.

Дата ревью: 2026-06-07.

---

## Осознанные решения (не блокеры)

- **`progressor_action` собирается из локального `_checkouts/progressor`** (`v1.0.24` + 1 локальный коммит), а `rebar.config` пинит `{tag, "v1.0.24"}`; `_checkouts/` в `.gitignore`, `rebar.lock` не лочит progressor. На чистом клоне сборка/xref упадут (`undefined module progressor_action`). **Решено оставить как есть на текущем этапе** — будет закрыто отдельно (апстрим-тег в `valitydev/progressor` либо вендоринг `progressor_action` в `apps/prg_machine`).
- **`ff_limit` остаётся на `-behaviour(machinery)`** + `machinery:get/call/start` → `machinery`/`machinery_extra` пока не удаляются. Отдельный goal.
- **Trace API** — сейчас FF internal HTTP JSON; перевод на Thrift (`docs/trace-api-thrift.md`) — отдельный goal.
- **Orphan NS** (`ff/identity`, `ff/wallet_v2`, HG `customer`, `recurrent_paytools`) — убраны из `sys.config`, вернутся отдельным PR при необходимости.

---

## Блокеры перед merge

| # | Проблема | Действие |
|---|----------|----------|
| B2 | CT не прогонялись (full-CT не завершена) | Поднять инфру и прогнать suites (см. Этап 2) |
| B3 | Нет PR, ветка не влита в `epic/monorepo` | Открыть PR после зелёных gate+CT (Этап 5) |

---

## Высокий приоритет (корректность рантайма)

### H1. Порча `aux_state` на exception-пути HG invoice
Подтверждено: `progressor` (`prg_worker.erl:624-630`) персистит `aux_state` из результата, если ключ присутствует.
Exception-ветка call в `hg_invoice.erl:412` возвращает голый `#{}` мимо `to_prg_result`; `prg_machine:marshal_intent/3` подставляет `auxst => undefined` → `marshal_aux_state(undefined)` даёт непустой бинарь → progressor перезаписывает `aux_state`. На следующем `collapse` `initial_model/2` делает `maps:get(model, undefined, _)` → **badmap**, машина уходит в error.
Бизнес-exception в invoice-call — штатная частая ситуация → ломает invoice после первого отклонённого вызова. Та же дыра: `dispatch_notification` без `process_notification/2` возвращает `#{}`.

### H2. `initial_model/2` не защищён от не-map `aux_state`
Любой путь, дающий `aux_state` ≠ map, валит `collapse`. Нужен guard `when is_map(...)` с fallback в `undefined`.

---

## Средний приоритет

- **M1.** `prg_machine:marshal_intent` всегда эмитит `aux_state`, даже когда домен его не возвращал. Эмитить ключ только при явном `auxst` от домена (тогда progressor сохранит прежнее значение) — системное исправление H1/H2.
- **M2.** Реестр namespace на ETS, owner — «пустой» супервизор без детей. Падение процесса = потеря таблицы = краш `ets:lookup_element` во всех `get_handler_module/1`. Сделать owner устойчивым (`heir`/gen_server) + понятная ошибка `{unknown_namespace, NS}`.
- **M3.** `process/3` заворачивает доменные ошибки в `{error, {exception, Class, Reason}}`, теряя stacktrace. Сохранять stacktrace в лог/мету.
- **M4.** Мёртвый/legacy machinery-конфиг в тест-фикстурах: `ct_payment_system.erl:86` `{machinery_backend, progressor}`; `test/bender/sys.config`, `test/party-management/sys.config` на `machinery_prg_backend`. Убрать/задокументировать.

---

## Низкий приоритет

- **L1.** FF `marshal_event_body` оборачивает тело в фиктивный `{ev, {ts,0}, Body}` (двойной timestamp, реальный — из storage). Косметика.
- **L2.** Доки: `prg-machine-migration-context.md` местами устарел (пишет про `epic/monorepo`, хотя сейчас `add_prg_layer`). Синхронизировать.
- **L3.** `rebar.config:39` TODO про bump damsel-тега после релиза `progressor_trace.thrift` — связать с Trace-API goal.

---

## Пошаговый план

### Этап 1 — корректность рантайма (H1, H2, M1) — можно делать в коде сразу
1. `prg_machine:marshal_intent/3`: эмитить ключ `aux_state` **только** когда домен вернул `auxst`; при отсутствии — не трогать сохранённый aux_state.
2. `prg_machine:initial_model/2`: guard `when is_map(AuxState)`, иначе `undefined`.
3. `hg_invoice.erl:412`: exception-ветку вернуть через `to_prg_result(#{})` (или явный `#{auxst => #{}}`).
4. Тест: invoice-call с бизнес-exception, затем `timeout`/повторный call — машина не должна уходить в error. Аналогично `notify` без `process_notification/2`.

### Этап 2 — CT (B2)
5. Поднять инфру (postgres/progressor, party-management, dmt, bender), прогнать минимум:
   - `ff_deposit_handler_SUITE`, `ff_withdrawal_handler_SUITE`, `ff_withdrawal_session_repair_SUITE`
   - `hg_invoice_lite_tests_SUITE`, `hg_invoice_tests_SUITE`, `hg_invoice_template_tests_SUITE`, `hg_direct_recurrent_tests_SUITE`
6. Зафиксировать результаты. До зелёного CT merge не делать.

### Этап 3 — устойчивость рантайма (M2, M3)
7. Упрочнить реестр namespace (устойчивый owner таблицы + понятная ошибка при отсутствии NS).
8. Сохранять stacktrace в `process/3` структурированно.

### Этап 4 — чистка хвостов (M4, L*)
9. Убрать мёртвый `{machinery_backend, progressor}` из `ct_payment_system.erl`; решить судьбу `machinery_prg_backend` в `test/bender`, `test/party-management`.
10. Обновить доки (`prg-machine-migration-context.md`), связать L3 с Trace-API goal.

### Этап 5 — PR (B3)
11. Открыть PR `add_prg_layer → epic/monorepo` после зелёных `compile`/`xref`/`lint`/`dialyzer`/CT, с описанием миграции и списком осознанных хвостов.
