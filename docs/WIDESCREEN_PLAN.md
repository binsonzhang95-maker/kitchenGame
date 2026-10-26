# Widescreen plan: kitchen game inside the Yggra iPhone app

Written 2026-10-26. The game runs in the Yggra app as a Web export inside a full-screen WebView. The app forces landscape while the game is open.

## What is wrong now (TestFlight build 3)

1. **Aspect ratio.** The canvas is 1536 x 1152 (4:3) with `stretch/mode="canvas_items"` and `stretch/aspect="keep"`. On an iPhone in landscape (19.5:9, about 2.17:1) Godot letterboxes inside the canvas. The game uses about 61 % of the width, with black bars left and right.
2. **Room background missing on iOS.** In the iPhone 17 simulator the tables, chairs and animals draw, but `restaurant_art/restaurant_open_background.png` (floor, walls, kitchen counter) does not. Everything floats on black. In desktop Chrome the same export draws it.
   - The file is in the pck and imported lossless (`compress/mode=0`, 1536 x 1024, no mipmaps).
   - So this is a runtime problem in WebKit, not missing data. See section 4.

Tried and rejected: `stretch/aspect="expand"` alone. The HUD stretched to full width, but the room stayed pinned to the left, leaving a big empty area on the right. The layout code places everything at fixed coordinates, so the extra width needs layout work.

## Target screens (landscape)

| Device | Aspect | Canvas at height 1152 |
|---|---|---|
| iPhone with notch / Dynamic Island (main target) | 19.5:9 ≈ 2.17 | 2496 x 1152 |
| iPhone SE / 8 | 16:9 ≈ 1.78 | 2048 x 1152 |
| iPad | 4:3 = 1.33 | 1536 x 1152 (today's size) |

## Layout today (from the code)

- `game_hud.gd`: `SIZE = 1536 x 1152`.
  - Top bar: `Vector2.ZERO`, size 1536 x 80.
  - Bottom bar: y = 1104, size 1536 x 48.
  - Pause overlay: (0, 80), 1536 x 1024.
  - Popups are clamped to `1536 - width`.
- `multi_main.gd:128`: `room.position = Vector2(0, 80)`. The room is 1536 x 1024 (`floor_plan.gd` `SIZE`).
- `multi_main.gd:598`: completion card at a fixed (634, 116).
- `floor_plan.gd`: all seats, counter and paths are in room coordinates. **These do not need to change.**

## Recommended approach: 4:3 safe area in the middle, wider scene around it

Keep the 1536 x 1152 design as the minimum "safe area" (iPad shows exactly this). On wider screens, show more restaurant at the sides instead of bars.

1. **Project settings**
   - Keep `viewport_width/height = 1536 x 1152` and `stretch/mode="canvas_items"`.
   - Change to `stretch/aspect="expand"`. Height stays 1152 on phones; width grows to about 2496.
   - Optional: use a feature override `window/stretch/aspect.web="expand"` if desktop should stay 4:3.
2. **One layout function.** Add `_layout()` in `multi_main.gd`, called from `_ready()` and on `get_viewport().size_changed`.
   - `var w := get_viewport().get_visible_rect().size.x`
   - `var side := (w - 1536.0) / 2.0` (0 on iPad).
   - `room.position = Vector2(side, 80)`. Centres the room; floor_plan coordinates stay as they are.
   - Top and bottom HUD bars: width `w`. Left-side items stay at x = margin; right-side items (pause and settings buttons, coins) anchor to `w - margin`.
   - Pause overlay: width `w`.
   - Popup clamp: `w` instead of 1536.
   - Completion card: centre with `side + 634`.
   - Tap and hit tests: subtract `room.position` once. Check `multi_view.gd:405/419`, which use local room coordinates; they should already be fine if input goes through `room.to_local()`.
3. **Art for the extra width.** Each side needs up to 480 px of 1024-high art next to the room. Pick one:
   - **(a) Simple.** Extend the background: draw a wall + floor strip tile (or mirrored edge slices of `restaurant_open_background.png`) to fill `side`. Add a few plants / windows / shelves so it doesn't look stretched.
   - **(b) Richer.** Paint a wide background (2496 x 1024) with a waiting area, entrance and window seats, and keep the 1536 middle identical to today's art. Draw it at x = `side - 480`, so on iPad only the middle shows.
   - Customers and waiters keep walking inside the 1536 room, so no path changes are needed. If (b) has extra seats, that is a later step.
4. **Missing background on iOS: ROOT CAUSE FOUND (2026-10-26 10:48).**
   - Both room backgrounds were 8-bit **RGB** PNGs (no alpha). The art that does draw is all RGBA. Godot's GL Compatibility renderer on iOS WebKit fails to draw RGB8 textures; desktop Chrome draws them.
   - The same export also fails in Safari on the simulator, so this is not the app's WebView.
   - Fix, verified in Safari on the iPhone 17 simulator, which now shows floor, walls and kitchen: re-save `restaurant_art/restaurant_open_background.png` and `restaurant_empty_background.png` as **RGBA8**, then re-import and re-export. A Godot headless script does this: `Image.load_from_file(path)`, `convert(Image.FORMAT_RGBA8)`, `save_png(path)`.
   - **Rule for new art (including the wide background): always save PNGs as RGBA.** Check with `file x.png`, which should print "8-bit/color RGBA".
   - The app ships this fix as TestFlight build 4. The export was made from a copy of the game with only these two PNGs converted, and your working copy was not touched. When you change the game, convert these two files too, or keep RGBA when you repaint them.
   - Earlier hypotheses, kept for reference:
   - **WebGL texture/upload problem in WKWebView.** Test the same export in Safari on the Mac and on the iPhone, using the app's game or Safari pointed at a local server. If Safari also fails, try:
     - Re-saving the PNG as 8-bit RGBA without an ICC profile or 16-bit channels (`file restaurant_art/restaurant_open_background.png`).
     - Splitting it into 2 x 512 high tiles.
   - **Timing.** `ResourceLoader.exists()` / `load()` succeeds on desktop but returns null on iOS. Add `push_warning` / `print` when `background == null` (autoplay already reports `error:*` to the app; we could send `error:bg`).
   - **Export preset.** `vram_texture_compression/for_mobile=false`. Only VRAM-compressed textures would be affected and this one is lossless, but if anything else is VRAM compressed, turn on `for_mobile`.
5. **Notch and home-indicator safe area.**
   - In landscape the iPhone notch takes about 47 pt on one side (about 140 canvas px at height 1152) and the home indicator about 21 pt at the bottom (about 60 px).
   - Keep tappable HUD items at least 150 px from the left/right edges and 60 px from the bottom when `side > 0`. Decoration can go under the notch.
   - If you want exact values, the app can pass them in: `window.YggraSafeArea = {left, right, top, bottom}` (CSS px). The game reads them with `JavaScriptBridge.eval("JSON.stringify(window.YggraSafeArea||{})")`. Tell me and I'll add the app side.
6. **Keep autoplay working.**
   - Run `tests/test_autoplay.gd` and the full headless suite.
   - Autoplay must still post `ready` within 60 s and `tick:<n>` every 5 s.

## Art at iPhone proportions (user's choice, 2026-10-26)

New art is generated at iPhone landscape proportions, so the game itself is wide and the app just shows it full screen.
- Target 19.5:9. At canvas height 1152 that is about **2496 x 1152**: room area 2496 x 1024 under the 80 px top bar, plus the 48 px bottom bar. Set `viewport_width=2496` and `viewport_height=1152`.
- Use `stretch/aspect="expand"` (or `keep_height`) so 16:9 iPhones and iPads crop or extend at the sides, never letterbox. Keep tappable HUD and seats inside the middle 2048 px if 16:9 phones should see everything.
- Save every PNG as **RGBA** (see the iOS background bug above).
- Keep tappable things about 150 px away from the left and right edges (notch / Dynamic Island) and 60 px from the bottom (home indicator).

## What the app does (no change needed for this plan)

- `lib/features/game/game_page.dart` shows the WebView full screen, forces landscape and restores portrait on close.
- The backdrop and WebView background are the game cream `#F7F2E7`, so there is no black flash while loading.
- The game page is a full-screen WebView in landscape with a cream (#F7F2E7) backdrop. There is no app-side frame or aspect logic; the game decides its own layout.

## How to hand the new export to the app

1. Export: `~/tools/Godot_4.5.1.app/Contents/MacOS/Godot --headless --export-release "Web" build/web/index.html`
2. Quick check at phone sizes, in headless Chrome. Look at both files:
   - `WIN=844,390 node <scratchpad>/cdp_shot.mjs http://127.0.0.1:8765/index.html out.png 45` (iPhone 19.5:9)
   - `WIN=667,375 …` (16:9)
   - Serve first with `python3 -m http.server 8765` in `build/web`.
3. Tell me. I'll then:
   1. Copy `build/web/*` to `app/assets/game/kitchen/`.
   2. Run the on-device walkthrough on the iPhone 17 simulator.
   3. Rotate the game screenshot and check that it fills the screen and shows the background.
   4. Upload TestFlight build 4 (version is already `0.1.0+4`).

## Done when

- [ ] iPhone 17 simulator, landscape: no black bars. The room is centred with side art, and the background (floor, walls, kitchen) draws.
- [ ] iPhone 16:9 and iPad 4:3 also look right (no clipped HUD, nothing under the notch you need to tap).
- [ ] Autoplay test passes; `ready` arrives in the app (the walkthrough waits for it).
- [ ] TestFlight build 4 installed and checked on a real iPhone.

## Play level from the app (added 2026-10-26)

Each toy in the app has a play level (age band). The app opens the game as `index.html?autoplay=1&level=2-4|4-6|6-8` (the demo game uses `4-6`). The game can read it with `JavaScriptBridge.eval("new URLSearchParams(location.search).get('level')")`. Suggested behaviour, matching the descriptions the app shows parents:
- `2-4`: name the food. Tap or place a card, hear its name and sound; no timers, no failing.
- `4-6`: simple recipes. 2–3 steps with voice help.
- `6-8`: run the restaurant. Take orders, multi-step recipes, coins.
Unknown or missing `level` means `4-6`.
