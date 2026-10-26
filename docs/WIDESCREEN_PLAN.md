# Widescreen plan: full-width playable restaurant and kitchen

Written 2026-10-26. This replaces the earlier proposal to keep a centred 1536-wide scene and decorate its side space.

## Current contract

- `responsive_layout.gd` maps viewport and host safe insets to one content rectangle and one playable world width. The width is clamped inclusively to 1536..4096.
- `multi_main.gd` treats `model.relayout(width)` as transactional. It records `_laid_out_world_width` only when the model already has the requested width or the relayout returns success and the committed `model.floor.layout_width` matches. If a relayout fails, UI, room and HUD transforms are reconciled to the model's current floor width instead of presenting a wider interactive surface over old geometry. Native resize bursts are deferred/coalesced, while test layout injection stays synchronous.
- `model.floor` is the geometry authority. Its `SIZE`, table/seat/service coordinates, counter, walkable regions, queue and entrance are shared by navigation, drawing, pointer transforms and bubbles. There is no static-floor business geometry fallback.
- The restaurant becomes genuinely wider at 16:9 and 19.5:9: all twenty tables retain their IDs but use the current floor instance. The outside table columns lie outside the old centred 1536 region rather than being decorative or untappable.

## Restaurant art and movement

- The renderer samples only clean floor/wall pixels for expansion. It overlays a centred, authored-scale crop of the original kitchen upper wall (equipment, shelves and counter-back detail), then continues clean wall pixels at either side.
- The chef support point is derived from `floor.COUNTER` and placed behind its front edge. The counter foreground is drawn after the chef to hide the lower body. `kitchen_point()` remains a waiter handoff/navigation point and is not used to position the chef.
- No partition, plant or other freestanding decorative object is placed in the walkable floor unless it also has shared floor obstacle geometry. In particular, the former central partitions at y=282/612 were removed; they cannot cover chairs, guests or be walked through.
- The floor begins in front of the counter and ends at the entrance/queue region supplied by the model. Bottom art must preserve the entrance opening and never turn the final table or queue into a wall.

## HUD, kitchen and safe areas

- HUD left/right controls are children of the shared safe content root. Dynamic popups use the room transform and model-floor table coordinates; modals are allowed to centre within the safe design width.
- The cooking view uses one full kitchen panorama with a left ingredient station, centre cookware and right action station. Legacy side-strip/slice nodes have been removed. Kitchen controls and the pause layer share the same safe content rectangle.
- Host safe insets may come from `window.YggraSafeArea` on web. Explicit numeric zero remains zero; unknown mobile browsers use the documented conservative fallback.

## Verification

- `tests/test_responsive_ui.gd` builds a private fixture with twenty guests routed and seated through the model, then sends real mouse-button press/release input to every seated table at compact 4:3, 16:9 and wide safe-area layouts, including tables 13, 14, 15, 18, 19 and 20. It repeats the clicks after resize.
- `tests/test_responsive_ui.gd` and `tests/test_widescreen_regression_ui.gd` now check kitchen panorama stage continuity, left/centre/right control distribution and safe-area containment instead of the removed side-strip nodes.
- The graphical responsive test writes `verification/widescreen/responsive_viewport.png` only after real guests are in the hall. It is a review artifact, not an empty-scene image.

- The Web export was checked at 844×390, 667×375 and 1024×768, plus an explicit safe-area case and a desktop-iPad user-agent case in Chromium. All five checks loaded without page/request errors and filled the viewport. The 60-second autoplay case completed service.
- A separate normal-player browser session verified both outside table columns and completed a cheese-toast order through ingredient selection, baking, takeout, return to the hall and settlement.
- V5 geometry, V3/V4 migration, occupied-seat avoidance and 40-guest service were checked with the official Godot 4.5.1 engine.

## Remaining platform verification

iOS/WebKit and real devices have not been tested. The desktop-iPad user-agent check uses Chromium and is not a substitute for WebKit. No native iOS package or TestFlight upload was performed.
