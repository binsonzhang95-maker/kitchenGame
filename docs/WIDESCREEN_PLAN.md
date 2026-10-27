# Widescreen plan: full-width playable restaurant and kitchen

Written 2026-10-26. This replaces the earlier proposal to keep a centred 1536-wide scene and decorate its side space.

## Current contract

- `responsive_layout.gd` maps viewport and host safe insets to one content rectangle and one playable world width. The width is clamped inclusively to 1536..4096.
- `multi_main.gd` treats `model.relayout(width)` as transactional. It records `_laid_out_world_width` only when the model already has the requested width or the relayout returns success and the committed `model.floor.layout_width` matches. If a relayout fails, UI, room and HUD transforms are reconciled to the model's current floor width instead of presenting a wider interactive surface over old geometry. Native resize bursts are deferred/coalesced, while test layout injection stays synchronous.
- `model.floor` is the geometry authority. Its `SIZE`, table/seat/service coordinates, counter, walkable regions, queue and entrance are shared by navigation, drawing, pointer transforms and bubbles. There is no static-floor business geometry fallback.
- The restaurant becomes genuinely wider at 16:9 and 19.5:9: all twenty tables retain their IDs but use the current floor instance. The outside table columns lie outside the old centred 1536 region rather than being decorative or untappable.

## Restaurant art and movement

- The restaurant uses fixed authored side strips and an expanding clean centre. The left `388` world units retain four full-height private rooms; the right `336` units retain the terrace/bar. Only the span between them grows from 1536 through 4096.
- Tables 15–18 stay in the four left rooms at the original support points near `(175,170)`, `(160,390)`, `(145,615)` and `(135,840)`. Tables 19–20 alone occupy the right terrace at fixed offsets from the right edge. Hall tables 1–14 use the original three columns/five rows, with width growth distributed 20%/50%/80% across the columns.
- `multi_view.gd` samples `restaurant_open_background.png` at native scale: fixed left-room and right-rail crops, repeated native window/wall bays, one centred green-curtain entrance crop, and the centred kitchen artwork. Windows, mats, plants and rails are never stretched. Nearest filtering remains authoritative and all source PNGs are RGBA.
- The 646-unit counter remains centred at `y=176`. Back-wall windows/plants remain beside it. The entrance support point is centred at `(W/2,976)` and the queue occupies the intentionally unused bottom-right hall slot beginning at `(W/2+172,962)`. The central floor meets the entrance corridor at `y=948`, so there is no unwalkable seam in front of the curtain.
- `floor_layout.gd` owns matching room passages, terrace opening, partitions, rails, front wall, plants, counter and furniture footprints. Room/terrace floors above `y=256` are explicit regions. Architecture is expanded by the moving animal's `64×32` ground footprint plus clearance for navigation; private-room service points and the visibly widened terrace gate match that clearance. Rendering, navigation, seat avoidance and pointer picking all consume this shared architecture, and foreground partition/rail/front-wall pixels draw after actors for occlusion.
- `wide_backdrop.gd` remains a viewport-only, non-interactive underlay. Unsafe left/right bands use procedural wooden plank walls with solid posts at the playable-room edge; the bottom band uses a plain facade plinth and tiled exterior step. These flat-colour pixel forms contain no copied plants, windows, partitions or railings. It covers the complete viewport, never supplies playable rooms or business geometry, and the playable world width remains derived solely from the safe rectangle so saves keep the same width contract.
- The chef support point is derived from `floor.COUNTER` and placed behind its front edge. The counter foreground is drawn after the chef to hide the lower body. `kitchen_point()` remains a waiter handoff/navigation point and is not used to position the chef.
- The layout revision now includes an architecture version as well as width. Old open-floor V5 snapshots use a frozen 1024-high snapshot with the historical `(W/2,1000)` entrance and `(W/2-126+36i,985)` queue for validation, then migrate transactionally even at the same width; frozen V3/V4 validation remains in `floor_plan.gd`.

## HUD, kitchen and safe areas

- HUD left/right controls are children of the shared safe content root. Dynamic popups use the room transform and model-floor table coordinates; modals are allowed to centre within the safe design width. With Web query `host=app`, the left HUD cluster moves past a 64 CSS-pixel keep-out from the safe top-left for the host close button; `input=device` remains independent and may be used in the same URL.
- The top HUD paint extends across the viewport, while hall controls, tables, actors and popups remain inside `safe_rect`. The restaurant underlay continues architecture through side insets and continues the facade below the front wall through the home-indicator inset.
- The cooking view uses one full kitchen panorama with a left ingredient station, centre cookware and right action station. Legacy side-strip/slice nodes have been removed. Kitchen controls and the pause layer share the same safe content rectangle.
- Host safe insets may come from `window.YggraSafeArea` on web. Explicit numeric zero remains zero; unknown mobile browsers use the documented conservative fallback. The Web viewport meta declaration uses `viewport-fit=cover`, allowing WebKit `env(safe-area-inset-*)` values to describe the full edge-to-edge canvas.

## Verification

- `tests/test_responsive_layout.gd` and `tests/test_responsive_ui.gd` cover 956×440 with `(62,62,0,21)` insets and 844×390 with `(47,47,0,21)`: viewport architecture coverage, safe table/actor/button hit rectangles, the host close-button keep-out, and unchanged zero-inset 4:3/16:9 layouts.
- `tests/preview_gameplay.gd` and `tests/preview_cooking.gd` accept `--insets=left,right,top,bottom` in Godot user arguments for device-safe-area reference renders.
- `tests/test_responsive_ui.gd` builds a private fixture with twenty guests routed and seated through the model, then sends real mouse-button press/release input to every seated table at compact 4:3, 16:9 and wide safe-area layouts, including tables 13, 14, 15, 18, 19 and 20. It repeats the clicks after resize.
- `tests/test_responsive_ui.gd` and `tests/test_widescreen_regression_ui.gd` now check kitchen panorama stage continuity, left/centre/right control distribution and safe-area containment instead of the removed side-strip nodes.
- The graphical responsive test writes `verification/widescreen/responsive_viewport.png` only after real guests are in the hall. It is a review artifact, not an empty-scene image.

- The Web export was checked at 844×390, 667×375 and 1024×768, plus an explicit safe-area case and a desktop-iPad user-agent case in Chromium. All five checks loaded without page/request errors and filled the viewport. The 60-second autoplay case completed service.
- A separate normal-player browser session verified both outside table columns and completed a cheese-toast order through ingredient selection, baking, takeout, return to the hall and settlement.
- V5 geometry, V3/V4 migration, occupied-seat avoidance and 40-guest service were checked with the official Godot 4.5.1 engine.

## Remaining platform verification

iOS/WebKit and real devices have not been tested. The desktop-iPad user-agent check uses Chromium and is not a substitute for WebKit. No native iOS package or TestFlight upload was performed.
