# `prg_machine`: семантика ошибок, HG vs FF, где не сошлось

Документ фиксирует **как было** (machinery), **что поменяли** в Hellgate и Fistful при унификации на `{error, failed}`, **где сломалось** и **какой контракт считать целевым**. Чтобы не разбирать заново при каждом CT-прогоне.

См. также: `docs/prg-machine-migration-context.md` (общая архитектура), `docs/prg-machine-remaining-debt.md` (техдолг collapse).

*Обновлено: 2026-06-10*

---

## 1. Три слоя ошибок (не путать)

| Слой | Откуда | Пример | Кто обрабатывает |
|------|--------|--------|------------------|
| **A. Progressor API** | `progressor:call/init/repair/get` вернул `{error, Reason}` | `<<"process not found">>`, `<<"process is waiting">>`, `{exception, ...}` | `prg_machine:start/call/repair/get` |
| **B. Processor response** | Вызов progressor **успешен**, в теле ответа `{error, ...}` или `{exception, ...}` | `{ok, {error, invalid_callback}}` из `hg_invoice:process_call` | Домен (`hg_invoice`, FF handlers) |
| **C. Доменный throw** | Woody handler / callback host | `erlang:throw(#payproc_InvoiceNotFound{})` | `hg_*_handler`, `ff_*_handler` |

Путаница между **A** и **B** — главный источник регрессий после миграции.

---

## 2. Как было: `machinery_prg_backend`

Файл: `_build/default/lib/machinery/src/machinery_prg_backend.erl` (в prod HG/FF уже не используется, но контракт оттуда «въелся» в тесты и ожидания).

### 2.1. `call/5` — маппинг ошибок progressor

```erlang
{error, <<"process not found">>}       -> {error, notfound};
{error, <<"process is init">>}        -> {error, notfound};
{error, {exception, _, _}}            -> erlang:error({failed, NS, ID});  % raise
{error, <<"process is error">>}       -> erlang:error({failed, NS, ID});  % raise
{error, _Reason} = Error              -> {ok, Error};   %% <-- важно
```

**Следствие:** любая «неизвестная» ошибка progressor (в т.ч. `<<"process is waiting">>`, `<<"process is running">>`) превращалась в **успешный** вызов machinery с телом `{error, Reason}`.

Дальше HG Thrift-слой (`hg_invoice_handler:call/3`):

```erlang
{ok, Reply} -> Reply;          % Reply может быть {error, <<"process is waiting">>}
{error, Error} -> erlang:error(Error);
```

То есть при статусе процесса `waiting` (таймер, фоновая обработка) внешний `call` **не падал на уровне API**, а возвращал `{error, Reason}` как обычный ответ домена.

### 2.2. `repair/5`

Явные ветки: `notfound`, `working` (`<<"process is running">>`), `failed` (exception / `process is error`), остальное — `{error, {failed, DecodedReason}}`.

### 2.3. Actions / таймеры

Machinery маршалил actions из списка `mg_stateproc` в `#{set_timer => ...}` **в микросекундах** (`system_time(microsecond)`).

Сейчас домены отдают `progressor_action` напрямую (`set_deadline`, `set_timer`, `set_timeout`) — progressor сам нормализует единицы через `prg_utils:to_microseconds/1`. Это **не** причина HG-fail (таймеры в progressor работают с секундами/deadline корректно).

---

## 3. Как стало: `prg_machine` (прямой client)

Файл: `apps/prg_machine/src/prg_machine.erl`

### 3.1. Целевой контракт `prg_machine` (client API)

**Не затирать** причину ошибки. Атом `failed` — только для «битого» процесса в storage progressor, не для exception из домена.

| Progressor | `prg_machine:call` / `start` |
|------------|------------------------------|
| `<<"process not found">>` / `<<"process is init">>` | `{error, notfound}` |
| `<<"process is error">>` | `{error, failed}` |
| `{exception, Class, Reason}` (и 4-tuple со stacktrace) | **`{error, {exception, ...}}` pass-through** |
| `<<"process is waiting">>` и прочие guard-ошибки | **`{error, Reason}` pass-through** |
| `<<"process already exists">>` (`start`) | `{error, exists}` |

`repair`: те же явные ветки + `working` для `<<"process is running">>`; прочие ошибки (включая `{exception, ...}`) → `{error, {repair, {failed, Reason}}}` — **Reason сохраняется**.

На внешней границе (woody adapter) exception по-прежнему можно сворачивать в `failed` для контракта провайдера — см. `ff_withdrawal_adapter_host`.

### 3.2. Регрессия (июнь 2026)

Временно в `call/6` стояло:

```erlang
{error, _} -> {error, failed}   % catch-all — ПЛОХО
```

Вместо:

```erlang
{error, _} = Error -> Error     % pass-through прочих ошибок progressor
```

**Эффект:** `<<"process is waiting">>`, `<<"process is running">>` (на call) и прочие guard-ошибки progressor превращались в атом `failed`. Внешние вызовы и callback-пути вели себя иначе, чем при machinery `{ok, {error, Reason}}` или pass-through.

**Симптомы в CT** (`lib.hellgate`, прогон 2026-06-09): 11 FAIL в `hg_invoice_tests_SUITE`, паттерн:

- `{badmatch, timeout}` в `next_change` / `next_changes` (таймаут ожидания события 12s)
- в списке ожидаемых payment events появлялся атом `timeout` вместо `payment_rollback_started` и т.п.
- `consistent_account_balances` — побочный эффект незавершённых платежей

Типичные кейсы: `payment_hold_cancellation`, `payment_hold_auto_cancellation`, каскады (`payment_cascade_*`), `deadline_doesnt_affect_payment_refund`.

FF transfer после правок `ff_ct_machine`: **88 OK / 0 FAIL** (тот же прогон).

### 3.3. Текущее состояние ветки

`prg_machine:call`:

```erlang
{error, <<"process is error">>} -> {error, failed};
{error, _} = Error              -> Error.
```

`start`: `exists` + pass-through. `repair`: `notfound` / `working` / `failed` + `{repair, {failed, Reason}}` с исходным `Reason`.

**Антипаттерн** (убран): `{error, {exception, _, _}} -> {error, failed}` — теряет class/reason для интроспекции и логов.

---

## 4. Что правили в Hellgate

| Модуль | Изменение | Зачем |
|--------|-----------|-------|
| `hg_invoicing_machine_client` | `{error, failed}` + **`{error, _} = Error -> Error`** | Проброс pass-through с `prg_machine:call` в Thrift |
| `hg_invoice_handler:call/3` | `{error, Error} -> erlang:error(Error)` | Без изменений по смыслу; `failed` — один из возможных `Error` |
| `hg_invoice` | `fail/1`: `{error, failed}` и `{error, {exception,...}}` → `ok` (тестовый хелпер, намеренный crash) | Согласовано с pass-through exception |
| `hg_invoice` | `process_callback` / `process_session_change_by_tag`: ветка `{ok, {error,_}} -> {error, failed}` (processor response, слой B) | Ответ процессора с ошибкой в теле |
| `hg_invoice_handler:repair/2` | `{error, working}`, `{error, Reason}` | Без `failed` catch-all |

**Не трогали (и не надо без отдельного goal):**

- `handle_payment_result` → `set_invoice_timer` при `?cancelled()` / `?failed()` — логика таймера invoice due после платежа
- двойной collapse (`validate_changes` + `to_prg_result`) — см. `prg-machine-remaining-debt.md`

### 4.1. HG: обработка `failed` на границах

```erlang
%% hg_invoice_handler:call/3
{error, Error} -> erlang:error(Error)   % в т.ч. failed, <<"process is waiting">>

%% hg_proxy_host_provider:handle_callback_result/1
{error, Reason} -> error(Reason)        % failed уходит наружу как exception
```

---

## 5. Что правили в Fistful (FF)

| Модуль | Изменение | Зачем |
|--------|-----------|-------|
| `ff_withdrawal_machine:call/2` | `notfound`, `failed`, **`{error,_}=Error`** | Симметрия с HG client |
| `ff_withdrawal_session_machine:call/2` | то же | |
| `ff_withdrawal_session_machine:process_callback/1` | spec: `failed` в union | Явная ветка `{error, failed}` |
| `ff_withdrawal_adapter_host` | `{error, failed} -> erlang:error(failed)` | Как HG provider callback |
| `ff_deposit_machine:repair/2` | `{error, failed}` → domain error tuple | Repair-контракт |

### 5.1. FF CT: `ff_ct_machine` (meck `prg_machine:process/3`)

Отдельная история — **не влияет на HG suites**, но ломала FF transfer.

Проблемы:

1. `meck:passthrough([prg_machine, process, [...]])` — неверная сигнатура, `function_clause` на `init`
2. `meck:passthrough` из mock `process/3` — `{badmatch, undefined}` в `get_current_call()`
3. `?MODULE:process(...)` — не exported

**Рабочее решение:**

```erlang
meck:new(prg_machine, [no_link, passthrough]),
meck:expect(prg_machine, process, fun process/3).

%% внутри mock:
'prg_machine_meck_original':process(Call, Opts, BinCtx).
```

Плюс: идемпотентный `load/unload`, hook до `create`, `maybe_unload` в `after`, `await_withdrawal_activity` с `linear(50, 200)`.

### 5.2. FF тесты на processor exception

`ff_withdrawal_SUITE:session_repair_test`:

```erlang
?assertMatch({error, {exception, _, _}}, call_process_callback(Callback))
```

`failed` (атом) — только если progressor вернул `<<"process is error">>` (битый процесс), не crash домена.

---

## 6. Матрица «кто что ожидает» (где не сошлось)

| Ситуация | Machinery | `prg_machine` (правильно) | `prg_machine` (catch-all bug) |
|----------|-----------|---------------------------|-------------------------------|
| Processor crash (exception) | `raise {failed,NS,ID}` | `{error, {exception,...}}` | `{error, failed}` ✗ (потеря деталей) |
| `process is error` | `raise {failed,NS,ID}` | `{error, failed}` | `{error, failed}` ✓ |
| `process is waiting` на **call** | `{ok, {error, <<"process is waiting">>}}` | `{error, <<"process is waiting">>}` | `{error, failed}` ✗ |
| `process is running` на **call** | `{ok, {error, <<"process is running">>}}` | `{error, <<"process is running">>}` | `{error, failed}` ✗ |
| `process is running` на **repair** | `{error, working}` | `{error, working}` | `{error, working}` ✓ |
| Ответ процессора `{error, X}` в теле | `{ok, {error, X}}` (через machinery decode) | `{ok, {error, X}}` через `decode_term` | без изменений ✓ |

**Важно:** полная эмуляция machinery `{ok, Error}` для слоя A **не** реализована в `prg_machine` — вместо этого HG handler принимает `{error, Reason}` на client API. Поведение **близко**, но не идентично: при `{error, <<"process is waiting">>}` handler делает `erlang:error(Reason)`, а не возвращает tuple клиенту. Тесты проходили с pass-through; с `failed` — нет.

Если понадобится **бит-в-бит** как machinery для call:

```erlang
%% гипотетически в prg_machine:call, только для «мягких» guard-ошибок:
{error, <<"process is ", _/binary>> = Reason} ->
    {ok, {error, Reason}};
```

Пока **не делали** — достаточно pass-through + обработка в `hg_invoicing_machine_client`.

---

## 7. Статус CT (на момент документа)

| Suite | Результат | Примечание |
|-------|-----------|------------|
| `lib.ff_transfer` | 88 OK / 0 FAIL | после `ff_ct_machine` + codec/timer fixes |
| `lib.hellgate` | 231 OK / **11 FAIL** | до fix pass-through в `prg_machine:call` |
| `lib.ff_server` | 41 OK / **4 FAIL** | отдельно не разбирали |

Прогон: `_build/test/logs/index.html`, hellgate run `2026-06-09_22.10.35`.

**11 FAIL (hellgate):**

`payment_hold_cancellation`, `payment_hold_auto_cancellation`, `payment_cascade_fail_wo_route_candidates`, `payment_cascade_limit_overflow`, `payment_cascade_fail_wo_available_attempt_limit`, `payment_cascade_failures`, `payment_cascade_deadline_failures`, `payment_cascade_fail_provider_error`, `deadline_doesnt_affect_payment_refund`, `accept_payment_chargeback_exceeded`, `consistent_account_balances`.

Перепрогон после fix pass-through — **нужен вручную** (`make wdeps-common-test` / docker).

Локально `rebar3` может падать с `corrupt atom table` — использовать docker testrunner из Makefile.

---

## 8. Чеклист при правках `prg_machine:call`

1. **`failed` только для `<<"process is error">>`** — не для `{exception, ...}` и не catch-all `{error, _}`.
2. Client-обёртки: `{error, _} = Error -> Error` (HG/FF `*_machine`, `hg_invoicing_machine_client`).
3. Woody-граница: при необходимости сворачивать `{error, {exception,...}}` в `erlang:error(failed)` локально (`ff_withdrawal_adapter_host`).
4. Processor response (слой B) — в домене (`{ok, {error,_}}`), не в `prg_machine`.
5. CT: `session_repair_test` ожидает `{error, {exception, _, _}}`, не `{error, failed}`.
6. FF meck: только `'prg_machine_meck_original':process/3`.

---

## 9. Ключевые файлы (быстрые ссылки)

| Путь | Содержание |
|------|------------|
| `apps/prg_machine/src/prg_machine.erl` | `start/call/repair`, маппинг ошибок |
| `_build/.../machinery_prg_backend.erl` | эталон старого поведения call |
| `apps/hellgate/src/hg_invoicing_machine_client.erl` | Thrift → prg_machine |
| `apps/hellgate/src/hg_invoice_handler.erl` | `call/3`, `repair/2`, `ensure_started` |
| `apps/hellgate/src/hg_invoice.erl` | callbacks, `set_invoice_timer`, session/callback |
| `apps/hellgate/src/hg_proxy_host_provider.erl` | provider → `process_session_change_by_tag` |
| `apps/hellgate/test/hg_invoice_helper.erl` | `next_change`, timeout 12s |
| `apps/ff_transfer/test/ff_ct_machine.erl` | meck timeout hooks |
| `apps/ff_transfer/src/ff_withdrawal_machine.erl` | FF call wrapper |
| `apps/ff_server/src/ff_withdrawal_adapter_host.erl` | adapter `failed` |
| `_checkouts/progressor/src/progressor.erl` | `check_process_status`, call требует `<<"running">>` |
| `_checkouts/progressor/src/progressor_action.erl` | таймеры/deadline |

---

## 10. Открытые вопросы

1. **Нужна ли эмуляция `{ok, {error, Reason}}`** для guard-ошибок progressor на call (как machinery) — или pass-through достаточен при текущих тестах.
2. **`lib.ff_server` 4 FAIL** — отдельное расследование.
3. **Полный зелёный `lib.hellgate`** после pass-through fix — подтвердить прогоном.
