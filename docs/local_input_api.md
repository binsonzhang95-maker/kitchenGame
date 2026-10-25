# KitchenInputAdapter API

`KitchenInputAdapter` is a `RefCounted` local-simulator normalizer. It never receives, retains, changes, or ticks a `CookingSession`. The caller passes a fresh `session.status()` dictionary to `handle()`, and is the only code allowed to submit a non-empty returned `action` to `session.act()`.

## Lifecycle

- `bind(token)` starts an isolated run and clears all prior authority. Both authority epochs advance monotonically for the adapter instance, including a same-token rebind, so an earlier connection cannot regain authority by carrying a larger sequence number.
- `reset_preparation()` is required after the caller submits `clear` or `retry`; it advances `preparation_epoch`, making queued earlier-preparation input stale. Controls already held on the current panel are retained as edge baselines, rather than replayed as new preparation actions.
- `use_screen()` switches to normal UI input, advances `connection_epoch`, and invalidates simulator input. It never changes `session.paused`.
- `connect_simulator()` advances `connection_epoch` and enters `aligning`. Only a complete `panel_snapshot` reaches `connected`.
- `disconnect_simulator()` advances `connection_epoch` and makes simulator cooking hold without losing session progress.
- `event_envelope()` returns `{source, token, preparation_epoch, connection_epoch, seq}`; producers copy it and use the returned next `seq` exactly once. `state()` is display/debug state only.

## Events and result

Every event contains the full envelope plus `type`. `source` is exactly `screen` or `simulator`; numeric epochs and `seq` are positive integers (not floats/bools). A connection accepts strictly increasing sequences. Wrong token/epoch/source or old sequences are `stale`; equal sequence is `duplicate`.

Simulator event types are `panel_snapshot`, `card`, `read_failed`, `cut`, `faucet`, `vessel`, `stove`, `oven_door`, `oven_level`, and `drink_button`. A snapshot supplies all of `stove_level`, `oven_level`, `oven_open`, `vessel`, and `faucet_open` with strict types. It only aligns panel state and never emits an action. An open faucet or present vessel in a snapshot initializes its edge latch; it needs a close/remove followed by a new open/place before it can offer an action.

Food cards are accepted only in `cutting_board`. The `pot` and `pan` card categories are vessel cards: in `stove` they have exactly the same present-edge and deduplication behavior as `{type: "vessel", kind: "pot"|"pan", present: true}`. Their other zones return `wrong_zone` (never `unknown_card`). A non-off stove event updates the reported panel level, but can offer `heat_*` only when a present panel vessel exactly matches `status.vessel`; it returns `vessel_missing` for no panel vessel and `wrong_vessel` otherwise. This rejects unsafe heat before a caller can submit it to `CookingSession`.

`handle(event, status)` returns `{action, feedback, accepted, token, preparation_epoch, connection_epoch}`. At most one action is returned; `action_candidate` means it is eligible for caller submission. `screen` semantic events return `screen_ignored`, because screen buttons use Main's normal action path rather than re-injecting device events.

## Timer hold

`hold_reason(status)` returns an empty string when this adapter does not hold cooking. For simulator mode it returns a stable reason while disconnected/alignment is incomplete or while a cooking stove/oven panel is unsafe. `ready` is intentionally never held by panel changes; the caller should separately honor manual session pause. The adapter does not mutate `paused`.
