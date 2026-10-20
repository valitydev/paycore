# Роутинг платежей и выплат

Реализации маршрутизации находятся рядом в `apps/routing`. Общий collector собирает
кандидатов, применяет prohibitions и объединяет дубли; доменные реализации задают
доступ к конфигурации, проверку условий и работу с лимитами.

## Структура

| Модуль в `apps/routing/src` | Назначение |
| --- | --- |
| `hg_routing` | Прежний вход платежей `get_routes/1`, фильтрация и выбор маршрута |
| `hg_route_collector` | Общий алгоритм policies/prohibitions и объединения кандидатов |
| `hg_routing_domain` | Контракт доменной реализации |
| `hg_payment_routing` | Платёжные terms, pins, blacklist и настройки FD |
| `ff_withdrawal_routing` | Выплатные terms, лимиты, сортировка quote и выбор по весам |
| `hg_route`, `hg_routing_ctx`, `hg_route_balancer` | Представление маршрута, результат фильтрации и веса |
| `hg_route_fd`, `hg_route_affinity`, `hg_routing_explanation` | Платёжные обогащения и объяснение выбора |

Домен реализует три callback-функции:

```erlang
compute_ruleset(RulesetRef, Varset, Revision) -> {ok, Ruleset}.
resolve_terminal(TerminalRef, Revision) -> {ok, ProviderRef} | {error, notfound}.
validate_candidate(Candidate) -> ok. % либо throw({misconfiguration, Details})
```

Collector вызывается как `hg_route_collector:get_routes(Revision, Varset, Rules, Domain)`.
Для платежей `Domain = hg_payment_routing`, для выплат — `ff_withdrawal_routing`.
Он одинаково обрабатывает policies и prohibitions. Платёжный домен принимает только
`allowed = {constant, true}`; выплатной сохраняет прежнюю обработку обеих boolean-констант.
Различие находится в реализациях callback, общий collector не выбирает поведение по имени домена.

Дубли `{provider, terminal}` объединяются до hold: побеждает больший priority, затем
больший weight, при полном равенстве — первый кандидат. Для отсутствующих priority/weight
используются доменные значения по умолчанию: 1000 и 0.

Платёжная машина использует прежние `hg_routing:get_routes/1` и `get_logger_metadata/2`.
Выплатная сохраняет API `ff_withdrawal_routing`. Машины отвечают за события и переходы состояния;
сбор маршрутов, terms и вызовы limiter находятся в routing. Сервисы домена запускает вызывающее
приложение; обратных OTP-зависимостей routing на hellgate/ff_transfer нет.

## Балансировка

Балансировка выплат без quote активна с момента выкатки. Управление — через priority и weight
в ruleset: приоритет сравнивается первым, веса распределяют выбор внутри одного priority.
При всех нулевых весах сохраняется сортировка по убыванию priority и возрастанию
`{provider_id, terminal_id}`. Отрицательный вес — ошибка конфигурации.

`GetQuote` и выплаты с quote сохраняют прежнюю сортировку и `validate_quote_route`.
Это сохраняет соответствие маршрута выдачи quote и исполнения. После записи выбранный маршрут
не пересчитывается при replay или изменении конфигурации.

## Учёт лимитов вывода

Внутренние события имеют форму:

```erlang
{route_changed, #{route => Route, candidates => Candidates}}.
{rollback_started, #{reason => Failure, candidates => Candidates}}.
```

`candidates` содержит учётные маршруты после hold, включая отброшенные по overflow.
`undefined` в старом RouteChange означает legacy-обработку; `[]` означает отсутствие hold
текущего routing. Эти значения не взаимозаменяемы. У RollbackStarted отсутствие candidates
означает отказ уже выбранной попытки; список относится к отказу routing до выбора.
Кодек сохраняет Thrift-структуры RouteChange/RollbackStartedChange и читает старые события.

Последовательность обработки:

1. Gather → hold/check → choose → запись `route_changed` с candidates.
2. Rollback невыбранных candidates до `p_transfer.prepared`.
3. При отказе routing — запись `rollback_started` с candidates, компенсация, затем финальный failed.
4. При отказе выбранной попытки — rollback выбранного hold до `p_transfer.cancelled`, затем каскад
   либо финальный failed. При исчерпании каскада сохраняется исходная ошибка сессии.

Для новых событий rollback использует записанные candidates без повторного ruleset gather.
Исходные iteration, revision и varset восстанавливаются при replay; terms вычисляются в process-шаге.
`apply_event` не выполняет RPC. Старые события без candidates сохраняют legacy gather при cleanup.
Для старых историй без revision остаётся существующий recovery через head.

Повтор шага до записи событий использует прежние limiter operation ids и параметры.
RPC-сбой не превращается в business-отказ и не теряет сведения о возможном hold.
Ошибка восстановления terms для известного hold прерывает шаг, не пропуская компенсацию.
При body_changed сохраняется цепочка rollback старой суммы → hold новой суммы → commit;
новая iteration вычисляется существующим BODY_CHANGED_ATTEMPT_MULTIPLIER.

## Совместимость и проверки

До записи новых событий readers, timeout/notification/repair/adjustment и потребители GetEvents
должны понимать candidates и RollbackStartedChange. Версия для отката должна уметь продолжать
незавершённую компенсацию. Legacy cleanup удаляется только после завершения старых операций,
включая pending, session-wait, processor errors, body rebuild и active adjustment.

Unit-тесты collector, payment/withdrawal routing и withdrawal проверяют условия, дубли, приоритеты,
веса, quote, replay, iteration и повтор process-шагов. Codec-тесты проверяют round-trip событий.
`hg_route_rules_tests_SUITE` и `ff_withdrawal_routing*_SUITE` проверяют маршрутизацию с реальными
сервисами; `ff_withdrawal_limits_SUITE` — денежные эффекты hold/commit/rollback.
