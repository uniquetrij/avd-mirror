# Mirror Emulator

Mirrors the Android emulator window **inside VS Code / any browser, even when the emulator window is in the background or fully occluded**. Defeats `FLAG_SECURE` blackouts (Tinder etc.): those only block *in-guest* capture (screencap / screenrecord / scrcpy), so this captures the emulator **host window** from the Windows side instead.

## Architecture

| Piece | Port | Method | Notes |
|---|---|---|---|
| `scripts/mirror.ps1` | 8777 | `PrintWindow(PW_RENDERFULLCONTENT)` | fallback; ~264 ms/frame, has a channel-swap tint bug |
| `src/wgccap` (.NET 8) | 8778 | **Windows.Graphics.Capture** | full-rate, occluded-safe, correct colors, CORS; ~46 fps during motion |
| Mirror page (`/`) | 8777 | JS | tries **WGC first**, auto-falls back to PW, re-probes ~2 s; status bar shows source badge (`WGC`/`PW`) |

- `mirror.ps1` auto-starts `wgccap.exe` if it isn't running.
- WGC produces a frame **only when the window content actually changes** (idle screen = static, no new frames — that is correct mirroring behavior; check `/status` `age=`).
- **The WGC callback must never block.** `FrameArrived` only drains the pool and hands the newest frame to a dedicated pipeline thread. Two traps make this mandatory:
  - `TryGetNextFrame()` must be called in a loop until it returns `null`. A pooled surface that is never retrieved stops WGC delivering, so taking one frame per callback lets the pool back up and capture **stops for good** — the mirror freezes on one frame while `/health` still answers `ok`.
  - Nothing in the callback may block. It used to hold a lock across `CreateCopyFromSurfaceAsync(...).GetAwaiter().GetResult()`; the pool is `CreateFreeThreaded`, so a burst parked several thread-pool threads waiting on continuations that needed those same threads. The pool starved and capture stopped permanently.
- **Capture coalesces to the newest frame.** The pipeline thread owns the GPU copy, crop and JPEG encode, and skips a frame if another is already waiting — encoding a superseded frame would only show something older than the screen already has. Sustained motion measures **~46 fps with `age=0ms`**.
- **The page self-paces its frame poll** (`FRAME_MIN_GAP`, an 8 ms floor against a hot spin, not a rate cap). A fixed `setTimeout` delay is a hard display-rate cap: an 80 ms delay pinned the mirror to ~12 fps regardless of how fast the capturer answered, adding up to 80 ms of staleness on top of each frame's own age.
- **Unchanged frames cost nothing, and the poll backs off.** The capturer answers `GET /frame.jpg?since=<seq>` with **304 and no body** when the screen has not changed (`X-Frame-Seq` carries the sequence, exposed via `Access-Control-Expose-Headers`). The token goes in the **query string, not `If-None-Match`** — a custom request header makes this a CORS preflighted request and doubles the round trips. Re-decoding an identical JPEG every poll burns the main thread (which also paints and handles input) and queues older decodes ahead of the frame that is actually new, so hard polling without this makes the mirror lag *more* the harder it is polled. Consecutive 304s ramp the poll gap up (`still` counter, `FRAME_IDLE_GAP` doubling) and any real frame drops straight back to the fast floor: every poll is a TCP connection, and ~120/s of them against a static screen is pure overhead.
- **Frame budget, measured:** input round-trip is **2–4 ms**; a definite guest change reaches the page in **~65 ms** end-to-end (that includes the guest's own animation); the capturer sustains **~73 fps** during motion and the page's `frameSeq` tracks `/status frames` 1:1, so the display path introduces no queueing of its own.
- Minimized windows can't be captured (no DWM surface): both helpers auto-restore; wgccap drops it to `HWND_BOTTOM` so it stays out of the way.
- **Frames are cropped to the guest display.** Both helpers remove the window chrome (title bar + borders), so the served JPEG *is* the guest screen at the window's client size (`270x570` for a `1080x2280` guest, `270x128` for `2280x1080`). The page can therefore map image-fraction → guest px directly. `--gsize WxH` (wgccap) and `Get-GuestSize` (mirror.ps1) supply the guest size used by the crop — and both must be the **rotated** size, not `wm size`, for rotation to work (see below).
- Both helpers are **per-monitor DPI aware** (`SetProcessDpiAwarenessContext(-4)` / `SetThreadDpiAwarenessContext(-4)`). Without it the process measures virtualized metrics (÷1.25 at 125%) while `PrintWindow` still renders the guest 1:1 *physical*, producing a cropped, mis-mapped image.
- The WGC frame pool is created once with the item size; on a window resize `Direct3D11CaptureFramePool.Recreate` is called, otherwise stale-sized frames are returned forever.

## Input forwarding (raw multi-touch)

The page **does not classify gestures**. It streams the actual pointer state to the guest, which interprets the gesture itself — so every gesture the emulator understands (tap, touch & hold, drag & drop, swipe, fling, pinch/spread, two-finger pan, edge system-nav swipes, sliders, text selection) behaves on the mirror exactly as on the emulator. No window focus is needed (input goes through the emulator console, not the window).

| Interaction | Guest action | Route |
|---|---|---|
| Left click | tap | `/touch?p=1:x:y` then `/touch?p=` |
| Left drag | swipe / scroll / fling (raw gesture, count = motion) | `/touch?p=1:x:y` streamed |
| Wheel / Shift+wheel | scroll / fling (vertical / horizontal, **natural** direction) | synthetic short drag at the cursor, replayed over `/touch` |
| Toolbar `Natural ⇅` / `Classic ⇅` | toggle wheel scroll direction (persisted) | local-only, `mirror.scrollNatural` |
| **Right press & drag** | **drag** = touch & hold, then move (drag & drop, reorder, sliders) | touch-down 140 ms after the press, then move |
| Right click (no drag) | Back | `/input?nav=back` |
| Middle click | Home | `/input?nav=home` |
| Ctrl + drag | pinch & spread (two fingers mirrored about the anchor) | `/touch?p=1a:…,1b:…` |
| Ctrl + wheel | pinch & spread around the cursor | `/touch?p=pa:…,pb:…` |
| Bottom soft keys ◀ ● ■ | Back / Home / Recents | `/input?nav=` |
| Toolbar Vol+ Vol− ⏻ | Volume / Power | `/input?nav=` |
| Toolbar Rotate ↶ ↷ | Rotate the guest 90° left / right | `/input?rot=` (replies with the new `WxH`) |
| Printable keys, Enter, Esc, Tab, arrows, Ctrl+C/V/X/A | text / keyevents / clipboard | `/input?text=`, `/input?key=` |

- **Rotation takes three steps on the guest, and only the last one alone does nothing.** `wm user-rotation lock N` (0=portrait, 1=90, 2=180, 3=270) *stores* the setting and reads it back correctly, yet `mCurrentOrientation` stays `0` and the frame never changes — the guest ignores it. `wm fixed-to-user-rotation enabled` must run **first**; only then does the lock apply. Also `wm user-rotation` (the newer subcommand) is a no-op here in isolation, and `settings put system user_rotation` is no better on its own. Verified all four values: 0/2 give `1080x2280`, 1/3 give `2280x1080`.

- **Three things must follow the rotation or the mirror silently goes wrong.** (1) `/gsize` must report the *rotated* size: `wm size` only ever returns the physical panel (`1080x2280`) regardless of orientation, so it is now read from `dumpsys window displays` `cur=WxH`, with `wm size` kept only as the portrait fallback. (2) The **emulator window** keeps its old aspect and letterboxes the rotated guest inside itself, so its client area is reshaped via `SetWindowPos` (`EmuMirrorWin.ReshapeToGuest`) before the capturer re-reads its crop — otherwise the crop is a thin landscape strip down the middle of a tall window. (3) `wgccap` reads `--gsize` **once at startup**, so it must be restarted with the new size; the page falls back to `/frame.jpg` (PrintWindow) meanwhile. Leaving any one of these stale shows a plausible-looking screen while every tap lands at the wrong guest pixel.

- **Rotation replies with the new size in the same request.** `/input?rot=N` returns `WxH` as its body so the page adopts it without a second round trip. `GW`/`GH` drive *every* client→guest mapping (`gp`, the pointer handlers, the pinch radius), so the page also calls `liftAll()` on rotate — stale pointers would otherwise be reinterpreted against the new dimensions.

- **Soft nav keys are a bottom bar (`#navbar`), centred on 25% / 50% / 75% of the *displayed guest screen*.** They are positioned from `layoutNav()`, which exports the image's letterbox offset and displayed width as CSS vars `--imx` / `--imw`; it re-runs on frame load, on `/gsize`, and on `resize`. Anchoring to the *window* width instead looks right until there are side letterboxes — with a 892 px window and a 482 px image the outer keys land ~102 px off the guest's own nav positions, so they must follow the image, not the page. The top toolbar keeps Vol+ / Vol− / Power / the scroll toggle. The JS element is named `navbar`, not `nav`, because `function nav(a)` already owns that identifier — reusing it is a **parse error that silently kills the whole page script** (no frames, no input), and `node --check` on the served `<script>` body is the quick way to catch it.
- **Transport.** `/touch?p=id:x:y,id:x:y` is a *complete pointer state* in guest px (`p=` alone lifts every finger). The server keeps slot state and emits **MT protocol B** (`ABS_MT_SLOT`, `ABS_MT_TRACKING_ID`, `ABS_MT_POSITION_X/Y`, pressure) via `event send` on the **emulator console** (`127.0.0.1:5554`, token `~/.emulator_console_auth_token`). Nothing else works: `adb shell input` is single-pointer only, and `sendevent` is SELinux-denied.
- Pointer ids are free-form strings (`1`, `2`, `1a`/`1b`, `pa`/`pb`, `w`); each id owns its own MT slot, so multi-touch is genuine.
- Guest px → panel raw: `round(px * 32767 / (dim - 1))` (the emulator panel reports 0..32767 on both axes).
- Right-drag timing: the touch-down is delayed `DRAG_HOLD_MS` = 140 ms so a quick right-click stays a pure **Back** (otherwise Back *and* a stray tap would both fire). Holding ≥ ~500 ms before moving gives Android's own long-press (drag & drop); moving sooner than the delay starts the drag immediately (`DRAG_SLOP` = 10 px).
- **Wheel direction: natural scrolling by default.** Wheel-down drags the synthetic finger **up**, so the content scrolls forward (later items are revealed) — matching trackpad/macOS natural scrolling. The toolbar button **`Natural ⇅` / `Classic ⇅`** (element `#sdir`) flips it to the legacy inverted direction; the choice is persisted in `localStorage` under `mirror.scrollNatural` (default `"1"` = natural). The sign is applied at the only place that matters: `const sgn=naturalScroll?-1:1;` in the wheel handler.
- **The wheel drag is replayed in the page (`wheelAnimate`), not on the server.** It interpolates the drag with `requestAnimationFrame` over `/touch`, rather than posting one `/input?swipe=` for the whole gesture. The server runs a **single-threaded serial accept loop**, so an inline gesture there blocks every other request for its full duration — two-finger input arriving mid-scroll had to wait out the rest of it (measured **1178 ms** behind a 660 ms swipe; now **2–3 ms**). A burst landing while an animation is already running sets `wheelPending` and replays once the current one finishes, so no scroll distance is dropped.
- **Never pace a gesture with `Start-Sleep`/`[Thread]::Sleep` on this path.** Both round up to the ~15.6 ms Windows timer tick, so a 16 ms step really costs ~31 ms and gestures ran at roughly **twice** their requested duration (a 660 ms swipe took 1265 ms; measured 678 ms after the fix). `Wait-ForDeadline` sleeps the bulk of the remaining time and spins out the last millisecond, and `Get-StepDeadline` paces against a wall-clock start so per-step send cost is absorbed into the step's budget instead of stacking on top of it.
- Mapping: the page converts a client point to guest px with `object-fit: contain` math against the image's real size, so letterboxing is handled. Frames are cropped to the guest display, so the image *is* the guest screen.
- **Scripted verbs** (fire-and-forget, handy for automation/other skills) are also available on `/input` and drive the same MT slot engine: `tap=x,y`, `press=x,y[,ms]` (touch & hold), `swipe=x1,y1,x2,y2,ms`, `pinch=cx,cy,r1,r2,ms`, `recents=x,y[,mid]`.
- **Rotation is intentionally not exposed** (no rotate control); guest coordinates assume portrait at the current `wm size`.

## Verifying input end-to-end

Kernel level — what the guest actually receives (run `adb shell getevent -t`, then send an event through `/touch`):

```text
/dev/input/event2: 0003 0039 0000000c   # ABS_MT_TRACKING_ID -> new contact
/dev/input/event2: 0003 0036 00004365   # ABS_MT_POSITION_Y 0x4365=17253 -> guest y=1200
...                                     # interpolated moves
/dev/input/event2: 0003 0039 ffffffff   # tracking id -1 -> lift
```

Framework level — what Android dispatched (`adb shell dumpsys input`, look for `mLastTouchEvents` / `TouchStatesByDisplay`):

```text
4:NotifyMotionArgs(id=…, source=TOUCHSCREEN | STYLUS, action=MOVE, pointerCount=1
   pointers={0: id=0 x=540.5 y=1050.5 pressure=0.5 …})
```

App level — assert the UI actually moved. **Compare pixels, not `uiautomator` text order**: `uiautomator dump` emits list children in *layout* order, not visual scroll order, so "the first N labels changed" stays constant across a real scroll and makes a working gesture look broken.

```powershell
$adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
function Hash { & $adb -s emulator-5554 shell "screencap -p /sdcard/s.png; md5sum /sdcard/s.png" 2>$null |
               Select-String '^[0-9a-f]{32}' | ForEach-Object { ($_ -split '\s+')[0] } }
$before = Hash; Invoke-WebRequest "http://127.0.0.1:8777/input?swipe=540,1366,540,970,300" -UseBasicParsing
Start-Sleep -Seconds 2; $after = Hash; "scrolled=$($before -ne $after)"
```

Confirm *which way* it scrolled by pulling a screenshot (`adb shell screencap -p /sdcard/x.png; adb pull …`) and looking at it — a screen-hash change alone cannot tell forward from backward.

⚠️ When asserting a wheel/drag scroll, pick a page that **has a scroll range**: e.g. Settings' homepage is a `ScrollView` whose content ends exactly at the viewport bottom, so dragging it legitimately does nothing. `uiautomator dump` also exposes `scrollable="true"` nodes and their bounds — use those as the drag target. Scrolling the Settings list down should reveal extra rows (Network → Sound & vibration → Display → Wallpaper).

⚠️ **A `uiautomator dump` taken too early shows a uniform shift, not a scroll.** Just after an activity opens, every element sits mid-transition and the whole window appears to have moved by one offset. Re-dump after a pause and diff against that settled baseline — a real scroll moves rows by a *large, row-varying* amount and clips rows off the top, whereas the transition moves everything identically. Comparing per-row `bounds` across two settled dumps is the reliable signal; screenshot hashing only proves *that* the screen changed, never which way.

⚠️ Long, fast drags are interpreted as **system gestures**, not scrolls — an 800 px drag in 330 ms through `/input?swipe=` navigates out of the app into the launcher/app drawer. Use short, slow drags when testing scroll behaviour.

## Stale / phantom contacts

A finger that is injected but never lifted stays **held down in the guest forever**. Android then parses every later gesture as multi-touch, so single-finger swipes turn into two-finger pans/pinches and simply do nothing. Symptom: swipes "work" on the first try, then stop responding everywhere.

Symptom check — `dumpsys input` shows more pointers than you sent:

```text
mLastTouchEvents: ... pointerCount=2 pointers={0: id=1 x=66.0 y=139.3 pressure=0.1 ...},
                                            {1: id=3 x=540.5 y=601.2 pressure=0.5 ...}
```

The extra pointer is not one you sent, and `/touch?p=` may not clear it, because the panel's slot space (0..9) is **shared with the emulator window's own pointer input** — a contact injected elsewhere is invisible to the server's slot bookkeeping.

Recovery — lift every slot, not just the tracked ones:

```powershell
# via the mirror (sweeps all 10 slots)
Invoke-WebRequest http://127.0.0.1:8777/touch?p= -UseBasicParsing
```

Verify the guest is clean afterwards (`pointerCount=0` on every device):

```powershell
adb shell dumpsys input | Select-String "Last Raw Touch: pointerCount=(\d+)"
```

Prevention is built into `mirror.ps1`: any slot not refreshed within `$script:ReapMs` (1500 ms) is swept, the page sends a 700 ms keepalive while a finger is down (so a genuine press & hold is *not* mistaken for a dead client), and `pagehide`/`blur`/`visibilitychange` beacon a final lift so closing or reloading the tab mid-gesture cannot wedge a contact.

> If `adb shell input` appears to "not show up" in `getevent`, that is expected — it injects through the framework, not evdev. Judge `input` via `dumpsys input` / UI state, and judge `event send` (the mirror's path) via `getevent`.

## When to Use

- "mirror the emulator", "emulator is black", scrcpy/screencap returns black frames, FLAG_SECURE screens
- Background monitoring of the AVD while working elsewhere in VS Code

## Procedure

1. Emulator running (`/start-avd` if not).
2. Start the mirror:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .github/skills/mirror-emulator/scripts/mirror.ps1 -Port 8777
   ```
3. Open **http://127.0.0.1:8777/** in a VS Code Simple Browser (`http://127.0.0.1:8777/` in the browser preview).
4. Status bar should read `live` + `WGC` (if it reads `PW`, wgccap didn't start — build it, below).

## Endpoints (verification)

```powershell
Invoke-WebRequest http://127.0.0.1:8778/health        # "ok"
Invoke-WebRequest http://127.0.0.1:8778/status         # fps, frames, age=<ms>
Invoke-WebRequest http://127.0.0.1:8778/frame.jpg      # WGC JPEG (CORS *)
Invoke-WebRequest http://127.0.0.1:8777/frame.jpg      # PrintWindow JPEG (cropped to the guest display)
Invoke-WebRequest http://127.0.0.1:8777/gsize          # "1080x2280" (guest display)
Invoke-WebRequest "http://127.0.0.1:8777/touch?p=1:540:1200"   # pointer down
Invoke-WebRequest "http://127.0.0.1:8777/touch?p="             # lift all
Invoke-WebRequest "http://127.0.0.1:8777/input?nav=back"       # Back
Invoke-WebRequest "http://127.0.0.1:8777/input?key=KEYCODE_APP_SWITCH"
```

Freshness test: `adb shell input keyevent KEYCODE_APP_SWITCH` → `/status` `frames` increments within ~2 s.

> ⚠️ If `/status` `age=` keeps growing while the guest screen is visibly changing, capture has **stalled**, not gone idle. Restart `wgccap.exe` — and check the two WGC traps above (`TryGetNextFrame` must be drained in a loop; the callback must not block). `/health` keeps answering `ok` while stalled, so health checks alone will not catch it.

> ⚠️ `age=` also grows legitimately on a **static** screen, because WGC only produces frames when content changes. To tell "idle" from "stalled", cause a screen change (e.g. a nav key) and confirm `frames` and `age=` both move.

## Build wgccap

```powershell
$env:PATH = "$env:LOCALAPPDATA\Microsoft\dotnet;$env:PATH"   # user-local SDK 8
cd .github/skills/mirror-emulator/src/wgccap
dotnet build -c Release
```

Exe: `bin/Release/net8.0-windows10.0.19041.0/wgccap.exe` (no NuGet deps).

Stop any running `wgccap.exe` before rebuilding — the running binary locks the output file.

## Notes / gotchas (interop)

- **Input path.** Gestures go through the emulator console, *not* adb: `adb shell input` is single-pointer (so no real pinch/two-finger pan) and `sendevent` is blocked by SELinux. The console connection is opened on demand, drained before each write, and re-opened if it drops (a dropped console makes `/touch` return 503 and the page shows `touch unavailable`).
- **Pointer state, not events.** `/touch` always sends the *whole* current pointer set, so the page may coalesce rapid moves; the guest still sees a correct multi-touch stream (that is exactly how a real touchscreen reports).
- The bridge from `HWND` → `GraphicsCaptureItem` needs three literal IIDs (reflection returns *wrong* synthesized GUIDs under CsWinRT):
  - `IGraphicsCaptureItemInterop` = `3628E81B-3CAC-4C60-B7F4-23CE0E0C3356`
  - `IGraphicsCaptureItem` (item IID) = `79C3F95B-31F7-4EC2-A464-632EF5D30760`
  - `IDXGIDevice` = `54ec77fa-1377-44e6-8c32-88fd5f44c84c`
- Stop: `Stop-Process -Id <pid>` for the powershell running `mirror.ps1` and any `wgccap.exe`.
