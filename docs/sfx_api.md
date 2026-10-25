# SFXController

`SFXController` is a small `Node` owned by one `Main` instance. Add it as a
child of that Main and let Main free it. It is not an autoload/singleton.

It plays only local desktop/mobile feedback from these fixed IDs:
`ui_click`, `ui_back`, `card_not_needed`, `card_unknown`, `step_complete`,
`dish_complete`, `toy_connected`, `toy_disconnected`. Each maps to
`res://assets/audio/sfx/<id>.ogg`. These are not hardware sound numeric IDs;
this module has no toy voice, network, TTS, music control, or save-file I/O.

```gdscript
var sfx := SFXController.new()
add_child(sfx) # setup also happens automatically in _ready
sfx.play("ui_click") # true only if enabled and its OGG loaded
sfx.set_enabled(false)
sfx.set_volume(0.6) # clamps finite values to 0..1
```

`setup()` may be called early and is idempotent: before the controller enters
the tree it allocates neither a bus nor players, and `_ready()` completes setup
after it is added. `play(id)` rejects arbitrary paths and invalid IDs. A small
fixed voice pool (at most 8 channels) replaces its oldest voice on rapid normal
input. `refresh_assets()` explicitly clears/retries both good and missing asset
cache entries without changing volume/enabled. `diagnostics()` and
`get_debug_state()` return copies suitable for UI diagnostics and tests.
`get_debug_state().played_ids` is a bounded ring of the 32 most recent
successful plays; `played_event_history_limit` exposes that cap and
`played_event_count` is the all-time successful-play total.
Tests may inject a dictionary of alternate paths with
`SFXController.new({"ui_click": "res://missing.ogg"})`; keys outside the
fixed ID list are ignored.

Every controller owns a uniquely named `MoriSFX…` bus and releases only that
exact bus on exit, after stopping its own players. Existing buses, Master,
music, and global volume are not modified. If another owner deletes the bus
and recreates its name, the controller leaves that replacement bus untouched.
