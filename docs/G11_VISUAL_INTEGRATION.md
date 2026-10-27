# G11 visual integration

G11 keeps the G10 room, counter, twenty table IDs and landscape layout intact. The delivered P0 side set is intentionally limited to cat, dog, panda, capybara and hamster. Other species continue to use the existing front-facing renderer; the missing twelve P1 side species are not fabricated.

Each party has one order and one table lifecycle. Rendering reads `model.table_members(table_id)` and draws every descriptor at its own `pos`; it never derives a companion location from the leader. `back` members use the front set, `left` uses native right-facing side art, and `right` mirrors the whole authored side frame (including foreground hand and side chair) without reversing frames. Each delivered side body and hand is a complete 128×128 PNG, so its draw source is always `[0,0,128,128]`; atlas coordinates apply only to the front-facing sheets. The per-frame `frame_rects[index].pivot` is authoritative, then `per_frame_pivot`, then the action pivot.

Family visual art is selected only while the assigned party actually has more than one member—not merely because that table could seat three. Family tables use their native 200×110 top/front split at one origin. A neutral group platter may sit behind the actual recipe dish, never replace it. Stable table-ID variants are used for ordinary-table cloths and vases; cloths are never stretched onto family tables. At most one deterministic party member chats while waiting or eating.

The view takes `arrival`, `transition`, `transition_elapsed`, and `stand_duration` from the model as read-only animation state. `sit_down` wins before chat and starts at zero for the entire party. A seated guest holds its physical seat through `stand_up`; only after the model clears that transition is it drawn as a walker. Queue/in-flight exits have no `stand_up` transition. Cup suppression is limited to the actual baked-cup frames, so an idle side guest never hides the tabletop cup.

`G11DecorLayout.build(width)` is the shared pure layout source for renderer and floor model. Rugs, runner, doormat and borders are traversable. Wall art is placed only in the two empty bands outside the native 704×176 kitchen crop; the window view is at curtain-local `[8,28]`, and wide bands expose every frame variant without shelf/curtain overlap.

The host stand, coat rack and service station are genuine colliding objects in the empty central hall at every supported width. At 2048px and wider, the delivered bar counter and large plant also occupy central-hall slots—not the fixed right terrace, whose rails and pots are baked into the original room. Every solid keeps its exact source-local `raw_feet` metadata from `restaurant_art/props.json`; its translated `footprint` is what the floor inserts into navigation. They are never rendered as pass-through decoration. A pendant is non-colliding overhead wall decor.

## Verification

`tests/test_g11_visual.gd` adds the HallView to the render tree and waits for real draw frames. It drives an ordinary assigned party through order/cook/service to nonzero `eat` frames; it does not patch actors, routes, table phase, or animation clock.

`tests/preview_g11.gd` is the GUI-only visual evidence runner. It uses Main and model admissions/routing/actions to show a three-member hall party (cat/dog/panda), a private party (capybara/hamster/cat), a bar single, and an ordinary single-cloth table. It writes its eating screenshot first, then naturally pays table 1 and requires the real `stand_up` transition and whole-party departure before it exits successfully. Example official-Godot commands (never `--headless`):

```sh
GODOT=/Users/kari/Documents/Codex/2026-10-24/task-4/tools/official-godot-4.5.1-20261024/engine/Godot.app/Contents/MacOS/Godot
$GODOT --path . --resolution 1688x780 --script tests/preview_g11.gd --audio-driver Dummy -- --out=/var/folders/_q/v91ld50s5clccz1lf00myl4h0000gn/T/kitchen-g11-s3apnn7h/evidence/g11-1688x780.png
$GODOT --path . --resolution 956x440 --script tests/preview_g11.gd --audio-driver Dummy -- --insets=62,62,0,21 --out=/var/folders/_q/v91ld50s5clccz1lf00myl4h0000gn/T/kitchen-g11-s3apnn7h/evidence/g11-promax-safe.png
$GODOT --path . --resolution 1024x768 --script tests/preview_g11.gd --audio-driver Dummy -- --out=/var/folders/_q/v91ld50s5clccz1lf00myl4h0000gn/T/kitchen-g11-s3apnn7h/evidence/g11-4by3.png
```
