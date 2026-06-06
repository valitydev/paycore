# Строгое ревью ветки `add_prg_layer` vs `epic/monorepo` — план доработки

Ревью кода (независимое, без CT-прогона — только `rebar3 compile`). Сборка проходит.
Diff: 95 файлов, +3604 / −3987. Суть ветки — перевод HG/FF машин с `machinery`/`hg_machine`/`ff_machine`
на единый слой `prg_machine` (progressor): 7 prod namespace, новые app'ы `prg_machine` и `operation_context`,
удаление старого machinery/hg_progressor glue.

> **Контекст подхода (уточнено автором).** Ветка — про *смену способа интеграции* с progressor, поэтому
> изменения **намеренно** заходят и в сам progressor (модуль `progressor_action`, правки `progressor.hrl`),
> а не размазываются обёртками по прикладному коду. Это осознанное правило, а не «срез угла». Единственное
> требование к такому подходу — **воспроизводимость сборки** (см. P0-1).

Легенда приоритетов: **P0** — блокер merge, **P1** — корректность/риск регрессии, **P2** — качество/техдолг.

---

## Итог по «срезанным углам»

- **elvis** — НЕ ослаблен: из `elvis.config` только удалены исключения для удалённых `*_machinery_schema`, новых нет.
- **dialyzer (`rebar.config`)** — НЕ ослаблен: `warnings` (`unmatched_returns`, `error_handling`, `unknown`) + `plt_apps => all_deps` без изменений.
- **`erl_opts`** (`warnings_as_errors`, `warn_missing_spec`, …) — без изменений, сборка чистая.
- Подавления, добавленные веткой, — 3: `nowarn` на мёртвую `map_action/1` (P2-1) и `nowarn_unused_function` на два тест-модуля (P2-6). `-dialyzer(nowarn_function,…)` в `ff_ct_*`/`hg_invoice_tests_SUITE` — доветочные.

**Вывод:** линтер/диалайзер как механизм не обойдён. Реальный риск — воспроизводимость сборки (P0-1) и точечный техдолг (P2).

---

## P0 — блокеры перед merge

### P0-1. Воспроизводимость сборки: правки `progressor` не закоммичены/не выпущены
Подход (дорабатывать сам progressor) — ок. Проблема в том, что **на текущий момент сборка собирается только на этой машине**:
- `_checkouts/progressor` — git-link `160000` на ref `90f4657`, **без записи в `.gitmodules`** → при клоне контент не подтянется.
- Рабочее дерево чекаута **грязное**: незакоммиченный `include/progressor.hrl` + **untracked `src/progressor_action.erl`**.
- Прод-код ветки (`prg_machine.erl:35,343`, `hg_invoice.erl`, `ff_*_machine.erl`) уже зависит от `progressor_action` — модуля, которого **нет ни в одном теге/коммите** upstream.
- `rebar.config` всё ещё указывает `{progressor, {git, …, {tag, "v1.0.24"}}}` (там нет `progressor_action`), а из `rebar.lock` пиннинг `progressor` удалён → источник версии противоречив.

Шаги:
1. Закоммитить и запушить правки в `valitydev/progressor` (`progressor_action`, `progressor.hrl`), смержить, **выпустить тег**.
2. `rebar.config` → `{progressor, {git, …, {tag, "<new>"}}}`; убрать дубль (`progressor` git + `prg_machine` path + `_checkouts`), оставить один источник истины.
3. Удалить `_checkouts/progressor` из индекса; вернуть `progressor` в `rebar.lock` (`rebar3 lock`).
4. Проверка: на чистом клоне `rm -rf _checkouts && rebar3 compile` — собирается без локального чекаута.

### P0-2. Нет коммита/PR
- Содержательно готово, но не оформлено PR на `epic/monorepo` (история — 7 коммитов с авто-сообщениями).
- Шаги: после P0-1 закоммитить, оформить PR, прогнать CI.

### P0-3. CT не прогонялись
- Ни один CT-suite не запускался. Для платёжного процессинга — обязательный гейт.
- Минимум suites (docker: postgres, party-management, dmt):
  - `apps/ff_server/test/{ff_deposit_handler_SUITE, ff_withdrawal_handler_SUITE, ff_withdrawal_session_repair_SUITE}`
  - `apps/hellgate/test/{hg_invoice_lite_tests_SUITE, hg_invoice_tests_SUITE, hg_invoice_template_tests_SUITE, hg_direct_recurrent_tests_SUITE}`
- Шаги: поднять окружение, прогнать suites, зафиксировать в PR.

---

## P1 — корректность и риск регрессий

### P1-1. `hg_invoicing_machine_client:thrift_call` — двойная сериализация + мёртвые ветки (подтверждено, фиксить)
`apps/hellgate/src/hg_invoicing_machine_client.erl:33-45`, `:59-76`.
- Args сериализуются (`marshal_thrift_args`) и тут же десериализуются (`unmarshal_thrift_args`), а в `prg_machine:call` уходит **десериализованный** терм (далее ещё раз `term_to_binary`). Сериализация — лишняя работа.
- `unmarshal_thrift_response`: ветки `is_binary(...)` недостижимы (транспорт — `term_to_binary`, не thrift-байты).
- Шаги: выбрать единый контракт транспорта call-args (скорее всего — слать готовый терм без thrift round-trip) и убрать мёртвые ветки декода. Сверить с `hg_invoice:handle_call/2` (ожидает `{FunRef, Args}`).

### P1-2. Удалён CT-тест `payment_success_trace` без замены (подтверждено, ошибка)
`apps/hellgate/test/hg_invoice_lite_tests_SUITE.erl` — убран `payment_success_trace/1` (проверка trace-API), trace переехал на FF internal HTTP JSON, но нового теста нет.
- Шаги: восстановить покрытие trace (тест на актуальный эндпоинт) либо завести явную задачу под отдельный goal (`docs/trace-api-thrift.md`) и сослаться на неё в PR.

### ~~P1-x. Паритет prod по выпавшим NS~~ — снято
`customer`, `recurrent_paytools`, `ff/identity`, `ff/wallet_v2` выпали корректно (подтверждено автором): доменных модулей нет, на `epic/monorepo` в `hellgate.erl` регистрировались только `hg_invoice`/`hg_invoice_template`. **Не регрессия, действий не требуется.**

---

## P1→P2 (понижено после расследования). `prg_machine:process/3` ловит все исключения

`apps/prg_machine/src/prg_machine.erl:264-281`, `:570-572`.

**Вывод расследования: «оно работает», это не блокер.** Цепочка проверена:
- `hg_invoice:process_call/2` (`:402-413`) сам оборачивает `handle_call` в `try ... catch throw:Exception -> {{exception, Exception}, #{}}`. То есть бизнес-`throw` превращается в **успешный** ответ-исключение (`{Response, Result}`), а не в `{error,…}`. Машина при бизнес-ошибке **не ломается**.
- В progressor (`prg_worker:do_process_task/4` → `handle_result_error/5`): `{error,…}` для `call`/`init`/`repair` → `error_and_stop` (машина в `error`), для `timeout`/`remove` → `error_and_retry`. До catch-all в `process/3` доходят только **непредвиденные** падения — а они и в старом MG ломали/фейлили машину. Поведение эквивалентно.

**Остаточные (P2) хвосты этого места:**
1. **Теряется stacktrace.** `?PROCESSOR_EXCEPTION` кладёт только `{exception, Class, Reason}`, а `raise_exception/1` делает `erlang:raise(Class, Reason, [])`. Для диагностики непредвиденных падений стектрейс нужно логировать (хотя бы `logger:error` со `Stacktrace`).
2. **Транзиентные woody-ошибки на `init`/`call`.** Для этих task progressor делает `error_and_stop` (нет retry). Транзиентная недоступность зависимости во время `call`/`init` → машина в перманентном `error` (нужен repair). Проверить, ожидаемо ли это (в т.ч. retry-policy неймспейса), и при необходимости классифицировать `?WOODY_ERROR(resource_unavailable|result_unknown)`.
3. **`process_signal/2` без `try/catch`** в `hg_invoice` (`:347-358`) — `throw` из `handle_signal` уйдёт в catch-all и для `timeout` уйдёт в retry. Подтвердить, что это намеренно (а не «проглатывание» бизнес-ошибки).

---

## P2 — техдолг (кандидаты на детальное расследование)

### P2-1. Мёртвый код `map_action/1` в `ff_deposit_machine`
`apps/ff_transfer/src/ff_deposit_machine.erl:63 (export), :143 (nowarn), :174-182`.
- Функция не используется; есть только в `ff_deposit_machine` (в остальных `ff_*_machine` её нет — реальный маппинг идёт через `action_to_prg`/`progressor_action` в домене).
- Двойная избыточность: функция **экспортирована** (`-export([map_action/1])`) → `nowarn_unused_function` для неё бессмысленен (экспортируемые не считаются unused).
- Маппинг `sleep -> progressor_action:instant()` семантически неверен (`instant() = set_timeout(0)` — немедленный таймаут, а не «сон»).
- Шаги: удалить `map_action/1`, его `-export` и `-compile(nowarn…)`; убедиться, что во всех `ff_*_machine` action-маппинг единообразен.

### P2-2. `binary_to_term` без `[safe]` в fallback-путях `prg_machine`
`apps/prg_machine/src/prg_machine.erl:437,455,554` (`decode_term`, fallback `unmarshal_event_body`/`unmarshal_aux_state`).
- HG-домены уже используют `binary_to_term(Payload, [safe])` (`hg_invoice.erl:1047,1050,1066`, `hg_invoice_template.erl`) — хорошо.
- Generic-fallback и `decode_term` (call-args/response/repair-args/rpc-context) — без `[safe]`. Риск низкий (данные формируем сами через `term_to_binary`), но как defense-in-depth: добавить `[safe]`, а fallback-кодеки сделать явной ошибкой вместо тихого `term_to_binary`/`binary_to_term`.

### P2-3. `prg_machine.app.src` не объявляет рантайм-зависимость `operation_context`
`apps/prg_machine/src/prg_machine.app.src` — в `applications` есть `progressor`, но нет `operation_context`, хотя `prg_machine.erl:526,539` вызывает `operation_context:env_enter/leave` (а `:41` использует тип `operation_context:binding()`).
- Шаги: добавить `operation_context` в `applications` (порядок старта приложений в релизе). Проверить, что `prg_utils` (используется в `prg_machine.erl:466`) приходит из `progressor`.

### P2-4. Артефакт тулинга в прод-репозитории
`.cursor/agents/generic-worker-composer.md` (+15 строк) закоммичен в hellgate.
- Шаги: удалить из ветки; при необходимости — в `.gitignore`.

### P2-5. Дубль/временное в `rebar.config`
- TODO «bump tag after progressor_trace.thrift is released in damsel» + тройное определение progressor (git tag + `prg_machine` path + `_checkouts`).
- Шаги: закрыть вместе с P0-1 (один источник истины), снять/затрекать TODO.

### P2-6. `nowarn_unused_function` на весь модуль в тестах
`apps/prg_machine/test/{prg_machine_env_tests,operation_context_tests}.erl`.
- Шаги: точечно `nowarn`/удалить неиспользуемые хелперы вместо глушения всего модуля.

### P2-7. Робастность `unmarshal_event/2`
`apps/prg_machine/src/prg_machine.erl:404-406` — событие без `payload`: вторая клауза рекурсивно вызывает себя, не добавляя `payload` → потенциальный бесконечный цикл (edge-case, на практике payload всегда есть).
- Шаги: явная клауза/гард для события без payload.

### P2-8. Прогнать статанализ на ветке
- `rebar3 dialyzer` и `rebar3 lint` локально на ветке не гонялись; конфиг не ослаблялся → «бесплатная» проверка.
- Шаги: прогнать оба до PR.

---

## Чек-лист готовности к merge

- [ ] P0-1: правки `progressor` закоммичены/затегированы; `rebar.config`/`rebar.lock` без `_checkouts`; чистый клон компилится
- [ ] P0-2: коммит + PR на `epic/monorepo`, зелёный CI
- [ ] P0-3: ключевые CT-suites зелёные
- [ ] P1-1: упрощён транспорт call-args в `hg_invoicing_machine_client`, убраны мёртвые ветки
- [ ] P1-2: trace покрыт тестом или заведена задача
- [ ] P2-1…P2-8: техдолг закрыт или вынесен в backlog (с акцентом на stacktrace в catch-all и semantics signal/transient-error)
