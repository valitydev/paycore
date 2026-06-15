# План правок по ревью `add_prg_layer`

Статус: согласован по итогам ревью (2026-06-12). База диффа — `e035d3c1` (epic/monorepo).

## Главный вывод: миграция данных НЕ нужна

Все найденные несовместимости живут в нашем промежуточном слое (`prg_machine`,
`ff_machine_codec`, `hg_invoice`), а не в thrift-схемах и не в progressor:

| Данные | Старый формат в БД | Что сломали | Лечится в слое |
|---|---|---|---|
| HG события | payload `t2b(msgpack {bin, Thrift})`, metadata `format_version` | читаем только ключ `format` | да: payload и так бинарно совместим, чинится только ключ метаданных |
| FF события | payload `t2b({bin, Thrift})`, metadata `format` | новый код ждёт сырой thrift | да: compat-чтение + запись в старом конверте |
| FF aux_state | `t2b(map)` | новый код ждёт msgpack-thrift | да: try-чтение обоих |
| HG aux_state | `t2b(#mg_stateproc_Content{})` | живёт на двух catch-ловушках | да: явная клауза |
| HG call-args задач | `{thrift_call, Service, FunRef, EncodedArgs}` в старой обёртке | новая форма `{FunRef, Args}` | да: compat-клауза чтения |

Принцип этапа 1: **писать в старом формате, читать оба**. Тогда и rollback
безопасен (старый код читает всё, что записал новый). Унификация конверта
HG+FF («дальше одинаково для обоих») — отдельный финальный этап с bump'ом
версии формата, когда reader уже повсеместно выкачен.

---

## Этап 1. Совместимость данных (блокер)

### 1.1 Метаданные событий: оба ключа
`apps/prg_machine/src/prg_machine.erl`

Важно: «рабочий» ключ у стеков разный. Старый HG (`hg_progressor`) писал
`<<"format_version">>`, старый FF (`machinery_prg_backend`) — `<<"format">>`
(и читает только его, с дефолтом 0). Возврат к одному из них ломает rollback
второго стека, поэтому:

- Запись: `event_metadata/1` → `#{<<"format_version">> => V, <<"format">> => V}`
  — оба старых ключа. Это разом чинит чтение старых HG-событий, event sink
  (`prg_notifier` читает `format_version`) и rollback обоих стеков
  (старый HG-reader найдёт `format_version`, старый FF-reader — `format`).
- Чтение: `unmarshal_event/2` — порядок `<<"format_version">>` → `<<"format">>`
  → `format` → `undefined`.

### 1.2 FF события: старый конверт на запись, sniff на чтение
`apps/ff_transfer/src/ff_machine_codec.erl`

- `payload_to_binary`: вернуть старый конверт — `term_to_binary({bin, ThriftBin})`
  (как писал `machinery_prg_backend` через `machinery_utils:encode(term, ...)`).
- `unmarshal_thrift_event` → принимать оба варианта:
  - первый байт `131` → `binary_to_term` → `{bin, Bin}` → thrift из `Bin`;
    любое другое msgpack-значение → понятная ошибка `{legacy_msgpack_event, ...}`
    (по данным таких быть не должно — проверить на стейдже);
  - иначе → сырой thrift (события, записанные текущей веткой в dev/test).
- То же чтение используется `ff_machine_trace` — автоматически чинится.

Примечание: sniff по первому байту безопасен только в эту сторону
(thrift-струkt не начинается с `131`); для msgpack наоборот — fixmap(3) тоже
`0x83`, поэтому порядок проверки именно такой.

### 1.3 FF aux_state: запись t2b, чтение try-оба
`apps/ff_transfer/src/ff_machine_codec.erl`

- `marshal_aux_state` → `term_to_binary(AuxSt)` (старое поведение).
- `unmarshal_aux_state` → `try binary_to_term` (старый формат), на ошибке —
  msgpack-путь (`binary_to_payload` + `ff_machine_schema:unmarshal`) для
  записанного веткой.

### 1.4 HG aux_state: явная клауза вместо catch-ловушек
`apps/hellgate/src/hg_invoice.erl` (`unmarshal_aux_state/1`)

- Явно матчить `#mg_stateproc_Content{format_version = _, data = Data}` →
  `mg_msgpack_marshalling:unmarshal(Data)`; убрать слепые `catch _:_`.
- Проверить ветку `dispatch(call, remove)` в `prg_machine`: туда уходит уже
  размаршалленный aux_state — `marshal_aux_state` должен его переживать.

### 1.5 Pending-задачи: compat-чтение args (решение — доработать, не откатывать)

Заключение: формат менялся **только у HG** (FF всегда писал plain
`term_to_binary(Args)` — там регрессии нет). Новая форма `{FunRef, Args}`
проще и не тянет thrift-сериализацию в слой `prg_machine` — откатывать на
`{thrift_call, Service, FunRef, EncodedArgs}` не стоит. Достаточно
compat-чтения, окно риска — только незавершённые call/init задачи в момент
деплоя (timeout-задачи с пустыми args не затронуты):

- `prg_machine:decode_term/1`: результат `{bin, Bin}` → `binary_to_term(Bin)`
  (старая двойная обёртка).
- `apps/hellgate/src/hg_invoice.erl` (`process_call`): клауза для старой формы
  `{thrift_call, Service, FunRef, EncodedArgs}` → `hg_proto_utils`-десериализация
  args → дальше обычный путь `{FunRef, Args}`. Перед реализацией сверить точную
  старую форму по `e035d3c1:apps/hellgate/src/hg_machine.erl` (строки ~137–143)
  и старому клиентскому пути `hg_progressor:call`.

### 1.6 Golden-тесты на старые форматы (критерий приёмки этапа)

- Снять реальные бинари (payload/aux_state/metadata/args), сгенерированные кодом
  базового коммита (или со стейджа), положить фикстурами.
- CT/eunit: чтение старого события, старого aux_state, старого call-арга — для
  hg_invoice и каждого из 5 ff-неймспейсов; плюс симметричный тест «новая запись
  читается старым форматом конверта» (rollback-инвариант).

---

## Этап 2. Таймстемпы событий — вернуть микросекунды (мажор)

PG-бэкенд progressor хранит `timestamptz` с микросекундами и сам детектит
юниты (`prg_utils:split_timestamp/to_microseconds`) — секунды сейчас режет
только `prg_machine`.

- `prg_machine:marshal_new_events`: писать `timestamp => erlang:system_time(microsecond)`
  (без `div 1000000`), один таймстемп на весь батч (как старый `emit_events`).
- Чтение: `event_timestamp_to_datetime` → возвращать `{calendar:datetime(), Micro}`
  (machinery-формат); обновить тип `machine_event()` и спеки.
- HG: `hg_invoice:event_timestamp_to_binary` — форматировать с микро
  (`hg_datetime`, как старый MG RFC3339).
- FF: `marshal_event_body` — в `{ev, {Dt, USec}, Body}` класть реальные микро
  вместо захардкоженного `0`; «недостижимая» клауза `codec_timestamp({Dt, USec})`
  в 5 `*_machine` модулях становится рабочей; `events/2` (GetEvents) наружу
  отдаёт микро.
- В progressor при его ревью: поправить спеку `event() :: timestamp := timestamp_sec()`
  → допускать `timestamp_us()` (фактически уже работает).

---

## Этап 3. Ошибки и устойчивость (мажоры)

### 3.1 `notify` / `remove`
- `prg_machine:notify/3`, `remove/2`: обработать все исходы
  (`{error, failed}`, `{error, {exception, _, _}}`, прочие guard-ошибки) —
  без `case_clause`.
- `ff_withdrawal_session:process_session`: восстановить старую семантику —
  notify в сломанный withdrawal глотается с warning-логом (`{error, failed}` →
  `ok`), сессия не заражается. Остальные ошибки — как сейчас, в error.

### 3.2 `env_enter`/`env_leave`
- `prg_machine:process/3`: флаг «enter выполнен»; `after` зовёт Leave только
  если был Enter. Ошибки до Enter возвращаются progressor'у как `{error, _}`
  без маскировки исключением из `after`.

### 3.3 Дефолтный woody deadline
- В `process/3` после восстановления контекста — `ensure_deadline_set`
  (дефолт 30 с, конфигурируемо через опции неймспейса), как делал старый
  `hg_progressor` через `hg_woody_service_wrapper:ensure_woody_deadline_set/2`.

### 3.4 Repair-путь
- `prg_action:marshal_timer`: клауза `{deadline, {{_,_}=Dt, USec}}` (machinery-формат
  из `ff_codec:unmarshal(timer, ...)`) — срезать USec, как в
  `ff_adapter_withdrawal_codec:unmarshal_provider_timer/1`. Тест на deadline-таймер
  в `ff_withdrawal_codec` (сейчас покрыт только `{timeout, 0}`).
- `prg_machine:repair/3`: декодировать `Reason` (`decode_term`) в ветке
  `{error, {repair, {failed, Reason}}}` — наружу term, а не t2b-бинарь.
- Выправить спеки `ff_*_machine:repair/2` и хендлеры (`ff_withdrawal_repair`
  и др.) под фактическую форму ошибки; убрать недостижимую ветку
  `{error, failed} -> {failed, {invalid_result, unexpected_failure}}`.

### 3.5 `hg_invoice_handler`
- `get_state/1`: `throw(#payproc_InvoiceNotFound{})` — голый рекорд, как в
  `map_history_error`.
- `ensure_started/2`: вернуть ветку `{error, Reason} -> erlang:error(Reason)`.

### 3.6 Контракт исключений процессора (решение)
- Форму `{error, {exception, Class, Reason}}` оставляем как есть — и на проводе
  к progressor (его контракт: `is_retryable/5` по 3-tuple решает «не ретраить»),
  и в клиентском API как pass-through. Переименование маркера (`failed` и т.п.)
  — косметика, не делаем.
- Чиним только реальные баги:
  - `prg_machine:get/3`: убрать `raise_exception` — возвращать
    `{error, {exception, Class, Reason}}` как обычную ошибку, а не
    re-raise с пустым stacktrace;
  - убедиться, что потребители (`hg_invoicing_machine_client`, `ff_*_machine`,
    repair-хендлеры) матчат эту форму: детали — в лог / маппинг в
    thrift-ошибки, без `case_clause`.
- Голый `{error, failed}` остаётся для статусной ошибки
  `<<"process is error">>` (процесс уже в error; деталей в ответе progressor
  нет — при необходимости их даёт отдельный `get` с `detail` процесса).
- `docs/prg-machine.md`: убрать упоминание 4-tuple со stacktrace, описать
  фактический контракт.

---

## Этап 4. Контекст и конфиг

### 4.1 Убрать глобальный `woody_context_loader`
- Удалить `application:set_env(prg_machine, woody_context_loader, fun ...)` из
  `hellgate.erl` и `ff_server.erl` (анонимный fun в app env + общий ключ —
  ломается на hot upgrade и при совместном старте в одном узле).
- `prg_machine:encode_rpc_context/0` → `op_context:current_woody_context()`:
  пробует hg-binding, затем ff-binding (gproc-ключи текущего процесса различны,
  коллизий нет), fallback `woody_context:new()` с warning-логом.
- Добавить `op_context` в `applications` у `prg_machine.app.src`
  (зависимость уже фактическая — `resolve_env_enter`).

### 4.2 `binary_to_term` без `[safe]`
- Старый стек (`machinery_utils:decode`, `hg_progressor`) работал без `[safe]` —
  возвращаем как было: убрать `[safe]` во всех decode собственных данных
  (`prg_machine:decode_term`, `unmarshal_event_body` fallback,
  `unmarshal_aux_state`, `ff_machine_trace:decode_term`, `hg_invoice`).

---

## Этап 5. Гигиена HG/FF

- `hg_invoice`: `log_changes` для signal/repair (как старый `handle_result`);
  убрать двойной `validate_changes` в `process_call` (заодно закрывает пункт
  «двойной collapse» из техдолга в `docs/prg-machine.md`).
- FF копипаста ×5: вынести `to_repair_machine/1`, `from_repair_result/2`,
  `repair_events_to_domain/1`, `event_body_from_timestamped/1`,
  `history_times/1`, `history_to_events/1`, `codec_timestamp/1` в общий модуль
  (`ff_machine_codec` или новый `ff_machine_lib`); удалить мёртвое поле `times`
  из `st()` пяти `*_machine`, либо начать использовать.
- FF: вернуть no-op `process_notification` (`#{}`) у session/source/destination
  вместо принудительного `action => timeout`; убрать лишний `action => timeout`
  из `ff_destination:init`.
- FF `machine_to_st`: явная ветка для `aux_state = undefined` (сейчас дефолт
  `maps:get(ctx, AuxState, #{})` мёртвый, падает `badmap`).
- `docs/prg-machine.md`: обновить разделы про ошибки/форматы по итогам этапов 1–4.

Вне скоупа (решено): `hg_hybrid` не возвращаем; trace (`ff_machine_trace`,
дефолт формата, `<<>>`-args) — отдельный ПР с переездом на thrift; тег
progressor в `rebar.config` — после ревью progressor.

---

## Этап 6 (опционально, отдельный ПР). Единый конверт HG+FF

После выкатки этапов 1–5 и стабилизации:

- format 2 = сырой thrift-binary payload для **обоих** стеков (HG уходит от
  `t2b(msgpack)`, FF — от `t2b({bin, ...})`).
- Reader к этому моменту уже умеет оба формата (этап 1), поэтому включение
  записи format 2 — отдельный маленький коммит; rollback-политика: откат только
  на версии, содержащие reader этапа 1.
- Сюда же — переезд trace на thrift (`docs/trace-api-thrift.md`).

## Порядок и критерии

1 → 2 → 3 → 4 → 5 — каждый этап самостоятелен и мержибелен отдельно; 1 и 2
трогают одни и те же функции маршалинга, их удобно делать подряд. Критерий
этапа 1 — golden-тесты (1.6) зелёные; критерий общий — CT + dialyzer + compose
зелёные, grep-инварианты из `docs/prg-machine.md` соблюдены.
