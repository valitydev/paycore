# Миграция hellgate на action() (новый progressor)

План переработки hellgate / ff / prg_machine после релиза progressor с явной
алгеброй `action()` в `processor_intent`.

План доработки progressor: `progressor/docs/step-effect-migration.md`.

**Предпосылка:** progressor tag `vX.Y.0` — в runtime **только** wire `action()`;
`progressor_action` удалён; `normalize` внутри progressor **нет**.

---

## Затронутые области

~17 модулей (были `progressor_action:*`, переведены на wire `action()`):

| Область | Модули (основные) |
|---------|-------------------|
| prg_machine | `prg_machine.erl`, test handlers |
| HG invoice/payment | `hg_invoice.erl`, `hg_invoice_payment.erl`, `hg_session.erl`, … |
| FF transfer | `ff_withdrawal.erl`, `ff_withdrawal_session.erl`, `ff_source.erl`, … |
| Codecs | `ff_codec.erl`, `ff_withdrawal_codec.erl`, … |

Текущая зависимость: `rebar.config` → `progressor` branch `add_action_module` (заменить на tag).

---

## Принцип

**Legacy MG/map живёт только в hellgate, до marshal в progressor.**

```
┌─────────────────────────────────────┐
│  hellgate / ff (домен)              │  оркестрация шага, MG repair
│  hg_machine_action (новый)          │  timer/deadline → wire action()
└──────────────┬──────────────────────┘
               │  action()  (progressor.hrl)
┌──────────────▼──────────────────────┐
│  prg_machine                        │  marshal_intent → processor_intent
└──────────────┬──────────────────────┘
               │
┌──────────────▼──────────────────────┐
│  progressor                         │  dispatch_action — без legacy
└─────────────────────────────────────┘
```

- Поле в intent по-прежнему **`action`**, не `effect`.
- Wire-значения — атомы и `{schedule, ...}`; см. `progressor/include/progressor.hrl`.
- **`progressor_action` не вернётся** — замена локальным `hg_machine_action` (или прямым wire в домене).

### Таблица legacy → wire (для адаптера и доменов)

| Было (`progressor_action` / map) | Стало (`action()`) |
|----------------------------------|---------------------|
| `new()` / `undefined` | поле не писать (= `idle`) |
| `instant()` / `set_timeout(0, _)` | `timeout` |
| `unset_timer` | `suspend` |
| `remove()` / `#{remove := true}` | `remove` |
| `set_timeout(N, _)` / `#{set_timer => Ts}` | `{schedule, #{at => Ts, action => timeout}}` |
| `set_deadline(Dt, _)` | `{schedule, #{at => unix(Dt), action => timeout}}` |
| `#{set_timer => Ts, remove := true}` | `{schedule, #{at => Ts, action => remove}}` |

`at` — абсолютный unix sec; относительное время считает автор (`erlang:system_time(second) + N`).

---

## Фаза 0. Bump зависимости

1. `rebar.config`: `{progressor, {git, "...", {tag, "vX.Y.0"}}}`.
2. `rebar3 upgrade progressor`, обновить `rebar.lock`.

**Сразу после bump compile не зелёный** — это ожидаемо: `progressor_action` исчез из зависимости.

**Критерий:** lock обновлён; список compile errors = карта работ (grep `progressor_action`).

---

## Фаза 1. `hg_machine_action` + `prg_machine` ✓

### `hg_machine_action`

Только хелперы планирования (без coerce/legacy):

- `t() :: action()` (`progressor.hrl`);
- `marshal_timer/1`, `schedule_timer/1`, `schedule_after/1`, `schedule_deadline/1`;
- wire-атомы (`idle`, `timeout`, `suspend`, `remove`) — напрямую в доменах.

### `prg_machine`

```erlang
-type result() :: #{
    events => [event_body()],
    action => action(),
    auxst => term()
}.
```

`marshal_intent/3`: `maps:get(action, Result, idle)` → в intent только wire; ключ `action` опускается для `idle`.

Домены и FF переведены на wire; shim `progressor_action` и `from_legacy` удалены.

**Критерий:** `rebar3 compile` green; `rebar3 eunit --module=prg_machine` green.

---

## Фаза 2. Hellgate core

Порядок по риску:

| Модуль | ~вызовов | Заметки |
|--------|----------|---------|
| `hg_session.erl` | 10 | proxy/timer |
| `hg_invoice_payment_refund.erl` | 9 | |
| `hg_invoice_payment_chargeback.erl` | 8 | |
| `hg_invoice_payment.erl` | 31 | самый большой |
| `hg_invoice.erl` | 14+ | `action_to_prg`, repair |
| `hg_invoice_registered_payment.erl` | 3 | |
| `hg_invoice_repair.erl` | 1 | |

Для каждого:

- `progressor_action:*` → `hg_machine_action:*` или прямой wire (`timeout`, `suspend`, `{schedule, ...}`);
- `-type action()` в домене → `hg_machine_action:t()` или `action()`;
- аккумулятор `{Events, Action}` — перезапись `Action` на шаге, не `set_timeout(0, Old)`.

### `hg_invoice`

- `action_to_prg/1` → `hg_machine_action:from_mg/1`;
- `merge_repair_action/2` → `hg_machine_action:from_repair/2` (один исход, без затирания timer);
- `set_invoice_timer/2` → deadline → `{schedule, #{at => ..., action => timeout}}`.

**Тест:** repair timer + remove → `{schedule, #{action => remove, at => ...}}`.

**Критерий:** HG ct по invoice/payment green.

---

## Фаза 3. FF transfer

| Модуль | Паттерн |
|--------|---------|
| `ff_withdrawal.erl`, `ff_withdrawal_session.erl` | `map_action/1` → wire `action()` |
| `ff_source.erl`, `ff_destination.erl`, `ff_deposit.erl` | `instant` → `timeout` |

```erlang
map_action(continue) -> timeout;
map_action(sleep) -> suspend;
map_action({setup_timer, T}) -> hg_machine_action:schedule_timeout(T).
```

**Критерий:** ff ct (withdrawal, destination suites) green.

---

## Фаза 4. Codecs и repair API

- `ff_codec.erl` — `repairer_ComplexAction` → `hg_machine_action:from_repair/2`;
- `ff_withdrawal_codec.erl`, `ff_*_codec.erl` — то же;
- `ff_repair.erl`, `hg_invoice_tests_SUITE` repair macros.

**Критерий:** repair-тесты: timer only, remove only, timer + remove.

---

## Фаза 5. Зачистка

```bash
rg 'progressor_action' apps/    # → 0 ✓
rg '#{set_timer' apps/          # → 0 ✓
# unset_timer остаётся в thrift/repair unmarshal (MG), не в processor intent
```

1. ~~Удалить `from_legacy`~~ ✓
2. Обновить `docs/prg-machine-migration-context.md`, `prg-machine-remaining-debt.md` при наличии.
3. Lock progressor на tag в `rebar.config` / `rebar.lock` (сейчас ref `4f6d78a`).

**Критерий:** полный CI hellgate green.

---

## Фаза 6. MG/thrift (опционально, отдельный PR)

`#mg_stateproc_ComplexAction{}` в woody-путях — `hg_machine_action:from_mg/1`.

Долгосрочно: thrift ComplexAction не протаскивается в progressor как map-ключи.

---

## Порядок

```
progressor tag → hg_machine_action + prg_machine (фаза 1)
              → HG domains (фаза 2) ∥ FF (фаза 3)
              → codecs (фаза 4) → cleanup (фаза 5)
```

Фазы 2 и 3 частично параллелятся после готового `hg_machine_action`.

---

## Не делать

- `effect` / `prg_effect` / `normalize` **в progressor** — контракт уже другой.
- Возвращать `progressor_action` / legacy map в processor intent.
- Fold repair actions с затиранием timer — один `action()` на intent.
- Authoring `{timeout, N}` в intent progressor — только wire.

---

## Чеклист приёмки

- [x] progressor на ref `4f6d78a` (до tag)
- [x] `prg_machine:result()` — `action => action()`
- [x] `marshal_intent` — wire `action()` без coerce/legacy
- [x] нет `progressor_action` в apps/
- [ ] repair timer + remove → `{schedule, #{action => remove, at => ...}}` (сейчас remove побеждает timer, как раньше)
- [ ] семантика `call_replace_timer` сохранена (новый schedule отменяет pending remove)
- [x] `from_legacy` / `coerce` удалены
- [x] `rebar3 compile` + `prg_machine` eunit green
- [ ] полный CI hellgate
- [ ] progressor tag в `rebar.config`
