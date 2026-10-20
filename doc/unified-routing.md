# Общий роутинг платежей и выплат

План доработки: одно ядро в `apps/routing`, тонкие адаптеры в hellgate и ff_transfer.
Выплаты получают балансировку и учёт hold по candidates из истории, без повторного ruleset gather при rollback нового формата.
Антифрод/FD для выплат — отдельный этап, в ядро не кладётся.

Связанное: [пины](route_pins.md). Протокол выплаты живёт в соседнем репо `fistful-proto`.

## Оценка плана

Направление верное: общий collector/filter/chooser, отдельные адаптеры terms и limiter,
балансировка через priority и weight в ruleset. Основной риск — жизненный цикл hold и восстановление исходной iteration.

При сверке с кодом обнаружены пробелы, которые нужно закрыть до реализации журнала:

- `route_changed` появляется только после успешного выбора. При all-overflow, ошибке hold
  или несовпадении quote нужен список кандидатов для cleanup без chosen. Падение до записи результата
  обрабатывается повтором routing/hold с прежними operation ids.
- При rollback нужна исходная iteration: после `p_transfer.cancelled` текущий индекс уже другой.
  Её можно восстановить при replay события маршрута; terms и контекст собираются в runtime.
- При отказе routing без выбранного маршрута candidates нужно сохранить в `rollback_started`.
  Для отказа выбранной попытки достаточно reason; завершение подтверждают существующие переходы машины.
- Старое событие без candidates не позволяет восстановить невыбранные hold.
  `[route]` годится только как снимок выбранного маршрута, а не как журнал лимитов.
- Новые поля struct и новые варианты union имеют разные требования к совместимости.
  Нужны reader-first rollout и политика для активных старых машин.
- Замена ComputeFun не отвязывает всё OTP-приложение: есть зависимости в `ctx`, explanation,
  affinity, FD, include и логировании.

Ниже эти пункты включены в целевой контракт и критерии приёмки. Имена новых событий и API —
предложение для реализации; окончательные thrift-типы фиксируются до первого PR, пишущего события.

## Цель

- Один движок: собрать кандидатов, отфильтровать, выбрать маршрут.
- Адаптер задаёт ruleset, varset, terms, limiter и сериализацию в историю машины.
- Выплата берёт candidates из истории без повторного ruleset gather; terms и limiter context восстанавливает по state, как платежи.
- `InvoicePaymentRollbackStarted` из payproc не копировать. У выплаты свой `rollback_started` с `reason`.

Имя `prg_routing` не использовать: `prg_` в репо — progressor (`prg_machine`). OTP-приложение уже называется `routing`.

## Как сейчас

```
платёж                         выплата
hg_invoice_payment             ff_withdrawal
  → hg_routing                   → ff_withdrawal_routing
    → hg_route_collector           → ff_routing_rule
balancer + choose_route        sort(priority, {prv,trm})  # weight мёртв
route_changed(candidates,      route_changed(один Route)
  scores, limits)
rollback из state              do_rollback_routing: gather заново
```

### Платежи

| Что | Где |
| --- | --- |
| Пайплайн routing | [`hg_invoice_payment.erl`](../apps/hellgate/src/hg_invoice_payment.erl) `process_routing/2` (~2060), `get_routes_/4` (~785) |
| Ядро | [`hg_routing.erl`](../apps/routing/src/hg_routing.erl) `get_routes/1`, `filter_routes/2`, `choose_route/1` |
| Кандидат | [`hg_route.erl`](../apps/routing/src/hg_route.erl) |
| Сбор ruleset + terms + prohibit | [`hg_route_collector.erl`](../apps/routing/src/hg_route_collector.erl) `get_routes/4`, `fill_accepted/4`, `fill_prohibition/4` |
| Вес | [`hg_route_balancer.erl`](../apps/routing/src/hg_route_balancer.erl) |
| Ctx / accounted candidates | [`hg_routing_ctx.erl`](../apps/routing/src/hg_routing_ctx.erl) `stash_current_candidates/1`, `accounted_candidates/1` |
| Hold/check | [`hg_invoice_payment.erl`](../apps/hellgate/src/hg_invoice_payment.erl) `filter_routes_with_limit_hold/4` (~2902), `hold_limit_routes/4` (~3022) |
| Событие маршрута | [`payment_events.hrl`](../apps/hellgate/include/payment_events.hrl) `route_changed` (~39) |
| Unused hold | `rollback_unused_payment_limits/1` (~3103): `candidate_routes -- [Route]` |
| Смерть попытки | `?payment_rollback_started` (~101) → `process_result` `routing_failure` / `processing_failure` (~2609) |
| Ruleset в домене | `PaymentInstitution.payment_routing_rules` |

Ядро **не отвязано от hellgate**: `hg_route` ссылается на `hg_invoice_payment:exchange_context()`
и `hellgate/include/domain.hrl`; collector — на `hg_inspector`, `hg_exrates`, `hg_domain`.
Кроме того, `hg_routing_ctx` / `hg_routing` используют типы `hg_limiter`, `hg_routing` читает имена
через `hg_domain`, `hg_routing_explanation` включает payment state, `hg_route_affinity` вызывает
`hg_terminal_affinity`, `hg_route_fd` — `hg_fault_detector_client` и env hellgate.
В [`routing.app.src`](../apps/routing/src/routing.app.src) эти зависимости не объявлены;
совместный запуск приложений скрывает проблему.

### Выплаты

| Что | Где |
| --- | --- |
| Пайплайн | [`ff_withdrawal.erl`](../apps/ff_transfer/src/ff_withdrawal.erl) `process_routing/1` (~851), `do_process_routing/1` (~874) |
| Фасад | [`ff_withdrawal_routing.erl`](../apps/ff_transfer/src/ff_withdrawal_routing.erl) |
| Сбор ruleset | [`ff_routing_rule.erl`](../apps/fistful/src/ff_routing_rule.erl) `gather_routes/4` |
| Выбор | `sort_routes/1` в фасаде: priority, затем `{provider_id, terminal_id}`. Поле `weight` пишется и не читается |
| Каскад | [`ff_withdrawal_route_attempt_utils.erl`](../apps/ff_transfer/src/ff_withdrawal_route_attempt_utils.erl) `next_route/3` |
| Rollback gather | `do_rollback_routing/2` (~892): exclude used terminals ± текущий, если p_transfer не `cancelled` |
| Событие | `{route_changed, route()}` — один маршрут. Codec: [`ff_withdrawal_codec.erl`](../apps/ff_server/src/ff_withdrawal_codec.erl) (~123) |
| Thrift | [`fistful-proto/proto/withdrawal.thrift`](../../fistful-proto/proto/withdrawal.thrift) `RouteChange` / `Route` (объявления около строк 253–264) |
| Ruleset | `PaymentInstitution.withdrawal_routing_rules` → [`ff_payment_institution.erl`](../apps/fistful/src/ff_payment_institution.erl) |

## Целевая нарезка

```
apps/routing                    адаптер hellgate              адаптер ff_transfer
─────────────────               ─────────────────             ─────────────────
hg_route                        payment_routing_rules         withdrawal_routing_rules
collector(Rules, Callbacks)     hg_varset + party_client      ff_varset + ff_party
filter_routes / ctx             PaymentsProvisionTerms        WithdrawalProvisionTerms
balancer / choose_route         hg_limiter, FD, inspector     ff_limiter
                                InvoicePaymentRouteChanged    RouteChange.candidates + rollback_started
```

Контракт адаптера (черновик API ядра):

1. `compute_ruleset(Ref, VS, Rev) -> {ok, Ruleset} | {error, {misconfiguration, Details}}`.
2. `resolve_terminal(TerminalRef, Rev) -> {ok, ProviderRef} | {error, Reason}`:
   иначе collector всё ещё зависит от `hg_domain`. Адаптеры используют `hg_domain` / `ff_domain_config`.
3. `fill_accepted(Route, VS, Rev) -> Route`: terms и ожидаемый reject через `set_accepted`.
   Платёжный адаптер отдельно заполняет pin/affinity/exchange; withdrawal не требует payment-tool context.
4. Набор `filter_fun` для attempted / limiter / (позже) antifraud. Очерёдность задаёт адаптер.
5. Persist: адаптер мапит результат ядра в свою историю. Результат содержит surviving routes,
   rejections и ошибку; ошибка не должна терять данные о начатых операциях limiter.

RPC-сбои и timeout не превращать в business `route_not_found` / `misconfiguration`:
они должны попадать в существующую retry policy машины. Ошибки конфигурации policies **и prohibitions**
обрабатывать одинаково; сейчас catch в `get_routes/4` не охватывает отдельный вызов `fill_prohibition/4`.
Контракт явно задаёт отсутствие RoutingRules, неразрешённые delegates, `allowed`, дубли кандидатов
и несуществующий terminal. Для дублей по `{provider, terminal}` нужна политика до hold:
либо reject конфигурации, либо детерминированное объединение priority/weight; молчаливое удвоение запрещено.

Limiter, inspector, FD, affinity и quote остаются в адаптерах.
Доменный `PaymentRouteScores` можно временно оставить внутренним представлением score, чтобы не менять
сравнение платежей одновременно с рефакторингом. Это допустимая зависимость от `damsel`,
но не от OTP-приложения hellgate.

## Инварианты учёта hold

Из протокола платежей нужен тот же принцип: сохранять учётные candidates и намерение rollback.
Terms, LimitContext и operation ids восстанавливаются из state. Отдельный сериализованный runtime-контекст
не является условием унификации и в события не добавляется.

### Повтор hold до записи результата

Hold выполняется на кандидатах, затем выбирается маршрут и записываются события.
При crash до записи результата машина повторяет gather/hold/check с прежними ids и параметрами.
Идемпотентный HoldBatch не создаёт второе резервирование. До события chosen может поменяться,
но это не меняет учёт уже сделанных hold.

`ff_limiter` строит operation id из provider, terminal, withdrawal id и iteration
(для iteration=1 суффикс отсутствует). Пока шаг не записал события, iteration не изменилась.
При переводе на общий collector сохранить схему ids и набор/параметры запросов повторного шага.
Идемпотентность сервиса, потерянный ответ и повтор после частичной обработки подтвердить тестами.

Использовать сохранённые body/resource/domain revision. У старых историй без revision
`operation_domain_revision/1` берёт head; для них сохранить существующий recovery.
Реконструкция изменяемых wallet/destination остаётся текущим механизмом ff_limiter.
Полная фиксация всех внешних входов запросов — отдельная задача, не часть унификации routing.

### Какие данные нужны в истории

Внутренние события имеют форму `{route_changed, #{route => Route, candidates => Candidates}}`
и `{rollback_started, #{reason => Failure, candidates => Candidates}}`.
Кодек сохраняет существующие Thrift-структуры; старое `{route_changed, Route}` поддерживается при чтении.

- `RouteChange.candidates`: учётные маршруты после hold, до отсева overflow, включая невыбранных.
- `RollbackStartedChange.reason`: отказ выбранной попытки; маршрут уже есть в state.
- `RollbackStartedChange.candidates`: optional список при отказе routing до выбора маршрута,
  когда нужно компенсировать hold без фиктивного route/attempt.

Отсутствующий candidates у старого RouteChange означает legacy, а не `[chosen]`.
Пустой список означает отсутствие hold текущего routing; нельзя подставлять кандидатов предыдущей попытки.
Отсутствующий candidates у RollbackStartedChange означает failure уже выбранной попытки.
Transport failure повторяет шаг; при обрабатываемом business reject учесть контракт атомарности batch
и включить кандидатов с возможным hold, требующим компенсации.

Body, revision, resource и изменения суммы уже записаны существующими событиями.
При replay RouteChange сохранить в производном state исходную iteration и ревизию routing до изменения
индекса; для rollback_started с candidates — iteration данного routing, не предыдущего выбранного маршрута.
Это чистое обновление state без RPC и новых полей Thrift. Сам LimitContext и turnover limits собираются
в process-шаге для известных provider/terminal по соответствующей revision/varset, как в платежах.
Повторный `compute_provider_terminal_terms` допустим; повторный `compute_routing_ruleset` для новых candidates не нужен.

### Последовательность и восстановление

Единственный новый вариант Change — `RollbackStartedChange`.

1. Gather → hold/check → choose → `route_changed(chosen, candidates)`.
   После записи выбранный маршрут не пересчитывается при replay.
2. Unused rollback: учётные candidates без chosen по `{provider, terminal}`, до `p_transfer.prepared`.
   Этот переход подтверждает освобождение; crash до записи повторяет идемпотентный rollback.
3. Нет пригодного маршрута после hold или quote mismatch → `rollback_started(reason, candidates)`.
   После rollback этих кандидатов записывается финальный `status_changed failed`.
   Даже пустой candidates относится к текущему routing и не создаёт фиктивную попытку.
4. Fail выбранной попытки → `rollback_started(reason)` без candidates. Откат выбранного hold выполнить
   до `p_transfer.cancelled`, затем — следующий routing или финальный fail по существующим retryable-правилам.
   Исходный session failure сохраняется при exhaustion каскада.
5. Следующий RouteChange / финальный StatusChange завершают обработку rollback intent. Не писать их
   до компенсации. Cancel transfer прошлой попытки не подтверждает rollback нового routing-failure.
6. `apply_event` только меняет state; RPC — в process-шаге. Activity различает routing failure
   со своими candidates и processing failure выбранной попытки. Завершённый переход не запускается снова.

Отдельные события учёта/release/rollback finished не нужны. Это at-least-once: проверить повтор
HoldBatch/CommitBatch/RollbackBatch, rollback отсутствующего/уже отменённого batch и атомарность batch.
У ff_limiter нет платёжных `ignore_not_found`: обработку ответов определить по его фактическому контракту,
остальные ошибки оставляют activity на retry. Пропуск gather не означает пропуск terms/context reconstruction.

### Iteration, body_changed и границы попытки

`update_current_p_transfer/2` увеличивает индекс при cancelled/committed. Для исходного hold использовать
iteration, восстановленную при replay его routing-события, а не текущий get_index после cancel.
Не менять одновременно порядок attempted / attempt-limit: старый шаг мог уже поставить hold
до поздней проверки лимита попыток. Раннюю проверку и изменение terminal-only exclude вынести отдельно.

При успешной сессии с body_changed маршрут остаётся прежним. Новая сумма уже в BodyChange,
iteration вычисляется существующим кодом с BODY_CHANGED_ATTEMPT_MULTIPLIER.
Сохранить текущий путь: rollback старого hold → hold новой суммы → commit новой суммы.
TransferChange не расширяется, нового routing/учёта кандидатов нет. Это регресс существующего поведения.

## Этапы

Нумерация этапов соответствует смыслу изменений, номера PR приведены отдельно в конце.

### 0. Протокол выплаты и совместимость

В fistful-proto:

- `RouteChange`: сохранить required route, добавить optional list<Route> candidates.
- `RollbackStartedChange`: required Failure reason; optional list<Route> candidates для отказа без chosen.
- `Change`: один новый variant rollback_started. Другие существующие events/Route не менять.
- Никаких RoutingSnapshot, отдельных operation ids, iteration или режима машины в Thrift.

В hellgate потребуются codec, event/state/replay и bump fistful_proto в rebar.config.
Проверить хранение через ff_withdrawal_machine → ff_machine_lib/ff_machine_codec: оно тоже использует Thrift.
Новые optional-поля позволяют читать старые данные, новый union variant требует обновления readers/processors
до включения writer. Версия для отката должна читать и продолжать исполнение нового change.

Способ cleanup определяется данными конкретной операции: есть candidates — используем их без ruleset gather;
старая операция без candidates — прежний rollback. Результат routing ещё не записан — повторяем шаг.
Следующий раунд старой машины может сохранить новый формат после завершения прежних обязательств.
Детали — в разделе [«Выкатка и жизнь старых машин»](#выкатка-и-жизнь-старых-машин).

### 1. Отвязать ядро от hellgate

- `hg_route`: убрать тип `hg_invoice_payment:exchange_context()`; использовать domain-тип exchange
  или данные адаптера. Убрать `hellgate/include/domain.hrl`, общие defaults разместить в routing.
- Collector принимает `#domain_RoutingRules{}` + compute/resolve callbacks. Pin enrichment и
  `fill_accepted` / blacklist / FD overrides / exchange вынести в payment adapter.
- Платёжный `get_routes`-фасад и `get_logger_metadata` вынести в hellgate, сохранив порядок стадий.
  Ядро оставляет общие filter/choose и структурированный результат.
- Переместить `hg_route_fd`, payment-specific `hg_route_affinity`, `hg_routing_explanation`
  в hellgate (имена модулей можно сохранить). Убрать `hg_limiter` из типов ядра/ctx.
- Исправить `routing.app.src`: только фактические зависимости ядра; исключить циклы
  `routing → hellgate → routing`. `ff_transfer` получает прямую зависимость `routing`;
  `fistful` — только если там остаются прямые вызовы ядра.

Критерий: routing компилируется и тестируется без hellgate-модулей/headers/env;
нет новых обратных зависимостей по xref. Платёжные CT/eunit зелёные, выплаты не меняют поведение.

### 2. Выплаты собирают кандидатов через ядро

Заменить `ff_routing_rule:gather_routes/4` на collector в адаптере `ff_withdrawal_routing`:

- Compute: `ff_party:compute_routing_ruleset/3`; resolve: `ff_domain_config`.
- Terms: текущий `do_validate_terms/4` как callback. Не включать hold в terms-validation.
- Сохранить порядок prohibit/terms/attempted и формат rejected reasons для `build_failure`:
  failure `no_route_found` / sub `limit_overflow` и retryable-классификация не должны поменяться случайно.
- Общий collector допустим и в legacy-ветке при сохранении прежних результата и side effects.
  Перенос не даёт права менять порядок hold/rollback, operation ids и запись событий активной старой машины.
- Сохранить `prepare_routes/2,3` для получения quote: без hold, без withdrawal-state и журнала.
- `allowed={constant,false}`: сейчас выплаты принимают такой candidate, платежи считают весь набор
  misconfiguration. Зафиксировать отдельную legacy-policy адаптера выплат до согласованного изменения
  семантики; не включать это изменение молча вместе с collector. Покрыть policies и prohibitions.

Удалить `ff_routing_rule` после переноса сценариев SUITE и всех ссылок, включая remote types/logging helpers.
Выбор на этом этапе — прежний descending priority, ascending `{provider_id, terminal_id}`.
Общий chooser для этого не использовать без отдельной политики tie-break.

### 3. Candidates и rollback_started

- В успехе сохранять учётные candidates в RouteChange; при отказе до выбора — в RollbackStartedChange.
- Различать учётные candidates после hold и eligible после overflow; cleanup не должен терять overflow hold.
- Восстанавливать исходную iteration в state при replay событий до её увеличения cancel/commit.
- Runtime собирает terms/context для известных маршрутов. Убрать новый gather с rollback;
  legacy gather сохранить для старых операций без candidates.
- Сохранить порядок cancel/rollback p_transfer, существующую проверку attempt-limit, исходный failure,
  commit выбранного маршрута и путь body_changed.
- Проверить quote после choose, all-overflow, hold-error и ранний отказ до session;
  при каждом обрабатываемом routing-failure сохранить candidates, transport failure повторяет шаг.

Критерий: hold-retry не удваивает резервирование; новый rollback не собирает ruleset повторно,
использует правильную iteration и допускает вычисление terms/context в runtime.
Старые операции завершаются прежним путём, следующие раунды могут писать новый формат.

### 4. Balancer в выплатах

Использовать `hg_route_balancer:fill/1` + `hg_routing:choose_route/1` только после фильтров.
`fill/1` заменяет исходный weight на bucket `0/1`; исходные веса для диагностики хранить отдельно.
Платёжные поля FD/pin/affinity у выплат имеют нейтральные значения и не обогащаются payment callbacks.

Balancer активен с момента выкатки, без feature flag. Распределение трафика задаётся конфигурацией
ruleset: сначала выбирается максимальный priority, веса действуют внутри группы с одинаковым priority.
Проверить `weight=0`, все веса нулевые, недопустимые веса, дубли и tie-break: текущий chooser при равном
score сохраняет первый маршрут, а старый sort выбирает меньший `{provider_id, terminal_id}`.
При всех нулевых весах явно сохранить старый порядок; weight=0 не означает запрет маршрута вообще.

Balancer применяется к новым раундам **без quote**. Совместимость hold-retry проверить до выкатки. `GetQuote` и выплаты с quote
сохраняют прежний selector и `validate_quote_route`. Независимые случайные выборы при выдаче quote
и при исполнении дадут ложные mismatch даже при неизменных candidates. Балансировку quoted-выплат
рассматривать отдельно: выбранный при quote маршрут потребуется закреплять при исполнении,
явно определив поведение при его недоступности.

Рандомизацию выполнять на живом шаге выбора, результат сохранять до сессии.
После crash до записи выбор может повториться, hold использует прежние ids/параметры; после записи маршрут неизменен.

### 5. Антифрод / FD (позже)

Слот — ещё один `filter_fun` адаптера. Не тащить `hg_inspector` и card token в ядро.
FD выплат — после определения собственного service_id и метрик; образец `hg_route_fd`.

## Что не трогать в первом проходе

- Поведение пинов, affinity, recurrent tokens, skip_recurrent в платежах: допускается перенос модулей.
- `InvoicePaymentRouteChanged` / payproc rollback.
- Семантику adjustment выплаты; codec/replay, body_changed и cleanup после adjustment проверить регрессом.
- Слияние `hg_limiter` и `ff_limiter`: разный LimitContext. Контекст ff_limiter восстанавливается существующим механизмом.
- Семантику quote и `allowed=false`: любое изменение выносить из рефакторинга явно.

## Тесты

Легенда: **оставить** — гонять как регресс; **пересадить** — тот же сценарий, другой модуль; **дописать** — нет покрытия инварианта.

### Ядро `apps/routing` — оставить и расширить

Eunit уже закрывает choose/balancer/ctx/equality:

| Файл | Что покрыто | Действие |
| --- | --- | --- |
| [`hg_routing.erl`](../apps/routing/src/hg_routing.erl) | сравнение scores, pin, filter accepted/prohibit/blacklist, tie-break, preserve weights | **оставить**; добавить кейс «collector с ComputeFun + RoutingRules без PI» |
| [`hg_route_balancer.erl`](../apps/routing/src/hg_route_balancer.erl) | вес внутри priority, порядок кандидатов | **оставить**; это контракт этапа 4 для выплат |
| [`hg_routing_ctx.erl`](../apps/routing/src/hg_routing_ctx.erl) | initial / accounted / considered | **оставить**; добавить «accounted = after hold, до overflow reject» |
| [`hg_route.erl`](../apps/routing/src/hg_route.erl) | `equal/2` | **оставить** |
| [`hg_route_collector.erl`](../apps/routing/src/hg_route_collector.erl) | FD merge, blacklist pmap | **перенести** payment-only тесты вместе с функциями в hellgate; добавить callback-контракт collector |
| [`hg_route_affinity.erl`](../apps/routing/src/hg_route_affinity.erl) | affinity rank | **перенести** вместе с модулем в hellgate, выплаты не зовут |

Новый eunit/CT ядра (**дописать**):

- `get_routes` по `#domain_RoutingRules{}` без `#domain_PaymentInstitution{}`.
- prohibit table на тех же fixtures, что [`ff_routing_rule_SUITE`](../apps/fistful/test/ff_routing_rule_SUITE.erl).
- misconfiguration в policies и prohibitions: delegates не схлопнулись; `allowed` не constant.
- Отдельные политики `allowed=false` для payment и legacy withdrawal; дубли / missing terminal.
- Ошибка compute RPC остаётся retryable; callback не требует hellgate context/headers.
- `filter_routes` pipeline: attempted + overflow, порядок групп reject как у платежей.

### Платежи — оставить как золотой регресс ядра

| Сьюит | Кейсы | Действие |
| --- | --- | --- |
| [`hg_route_rules_tests_SUITE.erl`](../apps/hellgate/test/hg_route_rules_tests_SUITE.erl) | gather, prohibit, empty, misconfig, risk, allow terms, pin, FD order, recurrent skip | **оставить**; починить, если сломает отвязка collector |
| [`hg_invoice_tests_SUITE.erl`](../apps/hellgate/test/hg_invoice_tests_SUITE.erl) | `payment_cascade_*`, `payment_limit_overflow`, `switch_provider_after_limit_overflow` | **оставить**; образец cascade + rollback_started + candidates в route_changed |
| [`hg_terminal_affinity_SUITE.erl`](../apps/hellgate/test/hg_terminal_affinity_SUITE.erl) | несколько `route_changed` | **оставить** |

Не копировать платёжные CT в выплаты один в один: другой proto и limiter context. Копировать **сценарии**.

### Сбор ruleset выплат — пересадить

[`ff_routing_rule_SUITE.erl`](../apps/fistful/test/ff_routing_rule_SUITE.erl):

- `withdrawal_routes_found_test`
- `withdrawal_no_routes_found_test`
- `withdrawal_rejected_by_prohibitions_table_test`
- `withdrawal_ruleset_misconfig_test`

**Пересадить** на `hg_route_collector` / адаптер (новый `ff_withdrawal_routing` unit или CT в `apps/routing`). После удаления `ff_routing_rule` сьюит с тем же именем не нужен — сценарии важны.

Eunit `convert_to_route_test` / `sort_routes` в [`ff_withdrawal_routing.erl`](../apps/ff_transfer/src/ff_withdrawal_routing.erl): **оставить** контракт детерминированного выбора для quote и всех нулевых весов; добавить контракт priority+weight для баланса внутри одного priority.

### Интеграция выплаты — оставить, усилить ассертами

[`ff_withdrawal_routing_SUITE.erl`](../apps/ff_transfer/test/ff_withdrawal_routing_SUITE.erl):

| Кейс | Смысл | Действие |
| --- | --- | --- |
| `allow_route_test` | happy path | **оставить** |
| `not_allow_route_test` / `not_global_allow_route_test` | terms allow | **оставить** |
| `not_reduced_allow_route_test` | misconfig terms | **оставить** |
| `adapter_unreachable_route_test` | fail без каскада | **оставить**; после этапа 3 — в истории есть `rollback_started`, не только `status_changed` |
| `adapter_unreachable_route_retryable_test` | каскад | **оставить**; проверить **два** `route_changed` и rollback chosen между ними |
| `adapter_unreachable_quote_test` | quote прибивает маршрут | **оставить** |
| `attempt_limit_test` | лимит попыток | **оставить**; при исчерпании cleanup учитывает уже сделанные hold, исходный failure сохраняется |
| `termial_priority_test` | каскад по priority | **оставить**; на этапе 4 дополнить отдельным кейсом веса при равном priority |

[`ff_withdrawal_limits_SUITE.erl`](../apps/ff_transfer/test/ff_withdrawal_limits_SUITE.erl) — главный регресс hold:

| Кейс | Действие |
| --- | --- |
| `limit_success`, `sender_receiver_limit_success` | **оставить** |
| `limit_overflow` | **оставить** |
| `limit_hold_*_error`, `limit_hold_error_two_routes_failure` | **оставить**; leftover rollback без gather |
| `choose_provider_without_limit_overflow` | **оставить**; после balancer — тот, кто не overflow, не обязательно «второй по id» |
| `provider_limits_exhaust_orderly` | **оставить** |
| `provider_retry`, `limit_exhaust_on_provider_retry`, `first_limit_exhaust_on_provider_retry` | **оставить**; это каскад + hold на второй попытке |

[`ff_withdrawal_SUITE.erl`](../apps/ff_transfer/test/ff_withdrawal_SUITE.erl): `route_not_found_fail_test` и соседние — **оставить**.

[`ff_transfer_SUITE.erl`](../apps/ff_transfer/test/ff_transfer_SUITE.erl): число `RouteChange` в GetEvents — **починить**, если в истории появится `rollback_started` / candidates (сейчас считает только `{route, ...}`).

[`ff_withdrawal_adjustment_SUITE.erl`](../apps/ff_transfer/test/ff_withdrawal_adjustment_SUITE.erl):
**оставить** сценарии изменения body и статуса, проверить, что cleanup старого раунда не запускается
повторно после adjustment. Session body_changed с реальным turnover limit уже проверяет
[`create_withdrawal_with_changed_body_test`](../apps/ff_server/test/ff_withdrawal_handler_SUITE.erl):
оставить как регресс пересоздания transfer и суммы, учтённой в лимите.

Codec: **дописать** round-trip RouteChange.candidates и RollbackStartedChange; отдельно отличать пустой candidates от отсутствующего.
Добавить golden binary fixtures старых историй и replay через `ff_machine_codec`,
а также проверку чтения новой истории версией reader-релиза. Расширение union требует этой проверки;
одного round-trip новых Erlang records недостаточно.

### Дописать (нет покрытия)

Пункты 1–10 — до выкатки нового writer и balancer, пункт 11 — до удаления legacy rollback.
RPC/crash-сценарии проверять process/apply_event тестами с контролируемым limiter, денежные эффекты — CT.

1. **Повтор hold до записи результата**

   Прервать шаг после hold всех/части кандидатов, повторить на том же state новым кодом.
   Operation ids и параметры совпадают; сумма резервирования не удваивается. Отдельно потерять ответ принятого HoldBatch.

2. **Candidates и unused rollback без gather**

   Candidates содержат невыбранных и overflow. Rollback идёт по ним без chosen;
   compute_routing_ruleset не вызывается, compute_provider_terminal_terms разрешён.
   Проверить исходную revision/varset при реконструкции terms и контекста.

3. **Fail выбранной попытки**

   RouteChange(candidates) → session fail → RollbackStarted(reason) → компенсация →
   p_transfer.cancelled → следующий route / final failed. Проверить retryable/non-retryable и исходный failure.

4. **Crash при rollback/commit**

   Прервать до RPC и после принятого RPC до записи перехода. При reload — правильная исходная iteration,
   повтор без двойного эффекта. После prepared/cancelled/следующего route/final status завершённый cleanup не оживает.

5. **Balancer**

   Разные priority, веса одной группы, 0:100, все нули и tie-break; управляемая случайная величина/seed.
   После записи chosen неизменен; до записи допустим повторный выбор без второго hold.
   Quote и все нулевые веса сохраняют прежний selector; разные priority имеют преимущество перед весами.

6. **Совместимость событий**

   Старый RouteChange без candidates продолжает legacy rollback; новый — rollback по candidates.
   Пустой список отличается от отсутствующего. Старые provider-only/legacy ids читаются.
   Старый незаписанный routing повторяется с прежними ids; следующий раунд может писать новый формат без mode.
   Чтение истории не вызывает RPC; readers и версия для отката понимают новый union variant.

7. **Отказ без chosen**

   All-overflow, hold-error, quote mismatch: RollbackStarted.candidates относится к текущему routing,
   включая пустой список, и не использует route/candidates прошлой попытки. Все обязательства освобождаются.

8. **Iteration и body_changed**

   Cancel увеличивает индекс, rollback использует исходную iteration из replay.
   Смена суммы сохраняет прежний маршрут и механизм multiplier; TransferChange не меняется.
   Регресс create_withdrawal_with_changed_body_test подтверждает конечную сумму в лимите.

9. **Attempt limit и совместимость collector**

   Старый шаг прерван после hold до поздней проверки attempt limit. Повтор новым кодом освобождает hold.
   Набор запросов/порядок фильтров на первой выкатке не меняются; ранняя проверка — отдельная доработка.

10. **Quote, commit и adjustment**

    GetQuote не делает hold и не требует withdrawal-state. Commit выбранного маршрута использует
    правильные body/iteration; adjustment/repair/callback не переключают текущую операцию на другой источник candidates.

11. **Удаление legacy**

    Нет незавершённых старых операций без candidates, включая failed до cleanup и processor errors.
    Определена поддержка дальнейших adjustment/repair; чтение старого формата остаётся.

## Выкатка и жизнь старых машин

### Определение пути по данным текущей операции

Режим в created не нужен. После replay:

| Данные текущей операции | Как продолжать |
| --- | --- |
| Результат routing не записан | Повторить gather/hold/check с прежними ids и параметрами, сохранить новый результат |
| Старый RouteChange без candidates | Прежний rollback с gather и восстановлением terms/context |
| Новый RouteChange с candidates | Использовать candidates для unused cleanup; terms/context собрать в runtime |
| RollbackStarted с candidates | Routing failure до выбора: компенсировать этот список, включая пустой, без фиктивной попытки |
| RollbackStarted без candidates | Failure выбранной попытки: откатить выбранный route, затем reroute/fail |
| Старые обязательства завершены | Следующий раунд может записать новый формат; вся машина к legacy не привязывается |

Наличие нового события в прошлом не переключает автоматически все старые операции машины.
Список берётся из соответствующего текущего route/rollback-started, не из прошлого раунда.
Iteration для limiter восстанавливается при replay на момент начала данной операции, до увеличения индекса.
Остальной runtime-контекст собирается по state без дублирования тела выплаты и resource в новых событиях.

### Старая выбранная попытка и незаписанный routing

Старые записанные route/session/transfer без candidates завершаются прежним путём.
Не подставлять [chosen] вместо отсутствующего списка: это теряет невыбранные hold.
Следующий раунд после завершения прежних обязательств может сохранять candidates новым writer.

Если старый hold был выполнен до crash без события, повтор routing с теми же ids/параметрами безопасен
при идемпотентном limiter. Проверить это на стыке старого и нового collector; не менять одновременно
набор кандидатов, фильтры или формат ids. Для древних историй без revision сохранить существующий recovery.

Статус failed не доказывает завершение cleanup. Body_changed сохраняет текущий механизм повторного hold
на прежнем маршруте. Чтение истории не выполняет RPC и не дописывает данные.

### Порядок релизов

| Шаг | Что выкатываем |
| --- | --- |
| A. Readers | Proto/codec/replay candidates и rollback_started. Writer пока прежний |
| B. Исполнение | Новый cleanup по candidates, исходная iteration в производном state, legacy fallback; terms/context по-прежнему в runtime |
| C. Writer | Запись candidates/rollback_started и balancer без quote активны с выкатки |
| D. Расширение | Увеличиваем долю после проверки hold-retry, cleanup и старых активных машин |
| E. Настройка распределения | Доли трафика задаются priority и weight в ruleset |

До C все обработчики timeout/notification/repair/adjustment и потребители GetEvents должны понимать
новые данные. Настройка writer — эксплуатационное управление, не сохраняемый режим машины.
Изменение настройки не меняет обработку уже записанных candidates и rollback intent.

### Откат релиза

Выключение writer прекращает запись новых данных, но уже записанные события продолжают исполняться.
После появления rollback_started версия для отката должна читать его и продолжать соответствующую activity;
reader-only релиза недостаточно. Граница отката определяется событиями, не датой создания машины.
Повторные terms RPC для известных routes остаются допустимыми и не означают возврат к ruleset gather.

### Остаток старых операций

Для удаления fallback учитывать незавершённые операции без candidates: pending/session-wait,
processor errors, body rebuild, failed до cleanup и active adjustment.
Источник — истории/процессы namespace ff/withdrawal_v2 и задачи/retries. Готового fleet-list API в
ff_withdrawal_machine нет; инвентаризация нужна до удаления fallback, не до первого нового результата.

Отсутствие таймера или новых событий не доказывает отсутствие hold; спорные результаты сверять с limiter.
Зависшие случаи разбирать адресным repair с исходными ids; исторические revisions/terms пока сохраняются.
После завершения старых обязательств fallback можно удалить, если определена поддержка adjustment/repair
старых историй. Если они ещё требуют старой ветки, соответствующий helper остаётся. Чтение старых events сохраняется.

## Порядок PR и выкладка

| PR | Изменение | Условие включения |
| --- | --- | --- |
| 1 | fistful-proto: RouteChange.candidates и один новый RollbackStartedChange(reason, optional candidates) | Только схема |
| 2 | Readers/codec/state новых данных, golden fixtures, bump proto | Writers ещё прежние |
| 3 | Отвязка apps/routing, payment adapter; выплаты ещё на ff_routing_rule | Платёжный регресс, нет обратных зависимостей |
| 4 | Выплаты на collector + terms callback, удаление ff_routing_rule | Выбор, запросы hold и схема ids сохранены |
| 5 | Candidates, rollback intent, исходная iteration в state, legacy cleanup | Идемпотентность и совместимость повторного шага подтверждены |
| 6 | Balancer в выплатах без quote | Активен с выкатки; распределение задают priority и weight |
| 7 (условно) | Удаление legacy gather на rollback | Нет старых незавершённых операций без candidates; решены adjustment/repair |

Антифрод/FD — отдельно. Наблюдать pending cleanup, limiter errors/retries, reject/fail и доли balancer;
не использовать withdrawal id в labels. Изменение priority/weight не пересчитывает сохранённый chosen.

## Критерий готовности этапа 3 (candidates)

- Нет production-вызовов и remote types ff_routing_rule; routing не зависит от hellgate-модулей/headers/env.
- Повтор hold до события сохраняет ids/параметры и не удваивает резервирование.
- На новом rollback нет compute_routing_ruleset; terms и LimitContext восстанавливаются в runtime.
- Исходная iteration восстанавливается при replay; cancel/commit не подменяют её текущим индексом.
- Fail без chosen сохраняет candidates в RollbackStartedChange и не создаёт фиктивный route.
- Компенсация предшествует следующему route/final fail; подтверждения — существующие переходы машины.
- Смена суммы сохраняет текущий путь, TransferChange не меняется.
- Старые операции завершаются прежним способом, следующие раунды могут писать новый формат.
- Зелёные: routing eunit, payment routing/cascade/affinity CT, withdrawal routing/limits CT,
  body_changed/adjustment и codec/replay проверки; подтверждены reader-first rollout и версия для отката.

Удаление legacy gather — отдельный условный PR, а не требование для включения нового writer.
