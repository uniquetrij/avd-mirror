# AVD Mirror

Mirrors the Android emulator window **inside VS Code / any browser, even when the emulator window is in the background or fully occluded**. Defeats `FLAG_SECURE` blackouts (Tinder etc.): those only block *in-guest* capture (screencap / screenrecord / scrcpy), so this captures the emulator **host window** from the Windows side instead.

This is the project's technical reference: how the capture path works, what the
endpoints are, and the traps that each part of it has to avoid. For the
day-to-day use, see [readme.md](./readme.md).

## Architecture

| Piece | Port | Method | Notes |
|---|---|---|---|
| `scripts/mirror.ps1` | 8777 | `PrintWindow(PW_RENDERFULLCONTENT)` | fallback; ~264 ms/frame, has a channel-swap tint bug |
| `src/wgccap` (.NET 8) | 8778 | **Windows.Graphics.Capture** | full-rate, occluded-safe, correct colors, CORS; ~46 fps during motion |
| Mirror page (`/`) | 8777 | JS | tries **WGC first**, auto-falls back to PW, re-probes ~2 s; status bar shows source badge (`WGC`/`PW`) |

- `mirror.ps1` auto-starts `wgccap.exe` if it isn't running, and requires it to *answer* on 8778 before claiming it started (see [Platform and runtime guards](#platform-and-runtime-guards)).
- WGC produces a frame **only when the window content actually changes** (idle screen = static, no new frames — that is correct mirroring behavior; check `/status` `age=`).
- **The WGC callback must never block.** `FrameArrived` only drains the pool and hands the newest frame to a dedicated pipeline thread. Two traps make this mandatory:
  - `TryGetNextFrame()` must be called in a loop until it returns `null`. A pooled surface that is never retrieved stops WGC delivering, so taking one frame per callback lets the pool back up and capture **stops for good** — the mirror freezes on one frame while `/health` still answers `ok`.
  - Nothing in the callback may block. It used to hold a lock across `CreateCopyFromSurfaceAsync(...).GetAwaiter().GetResult()`; the pool is `CreateFreeThreaded`, so a burst parked several thread-pool threads waiting on continuations that needed those same threads. The pool starved and capture stopped permanently.
- **Capture coalesces to the newest frame.** The pipeline thread owns the GPU copy, crop and JPEG encode, and skips a frame if another is already waiting — encoding a superseded frame would only show something older than the screen already has. Sustained motion measures **~46 fps with `age=0ms`**.
- **The page self-paces its frame poll** (`FRAME_MIN_GAP`, an 8 ms floor against a hot spin, not a rate cap). A fixed `setTimeout` delay is a hard display-rate cap: an 80 ms delay pinned the mirror to ~12 fps regardless of how fast the capturer answered, adding up to 80 ms of staleness on top of each frame's own age.
- **Unchanged frames cost nothing, and the poll backs off.** The capturer answers `GET /frame.jpg?since=<seq>` with **304 and no body** when the screen has not changed (`X-Frame-Seq` carries the sequence, exposed via `Access-Control-Expose-Headers`). The token goes in the **query string, not `If-None-Match`** — a custom request header makes this a CORS preflighted request and doubles the round trips. Re-decoding an identical JPEG every poll burns the main thread (which also paints and handles input) and queues older decodes ahead of the frame that is actually new, so hard polling without this makes the mirror lag *more* the harder it is polled. Consecutive 304s ramp the poll gap up (`still` counter, `FRAME_IDLE_GAP` doubling) and any real frame drops straight back to the fast floor: every poll is a TCP connection, and ~120/s of them against a static screen is pure overhead.
- **Frame budget, measured:** input round-trip is **2–4 ms**; a definite guest change reaches the page in **~65 ms** end-to-end (that includes the guest's own animation); the capturer sustains **~73 fps** during motion and the page's `frameSeq` tracks `/status frames` 1:1, so the display path introduces no queueing of its own.
- Minimized windows can't be captured (no DWM surface): both helpers auto-restore
  and park the window just outside the virtual screen. Dropping it to
  `HWND_BOTTOM` (wgccap's old behaviour) was not enough — it put the window back
  behind the editor, so an emulator minimized to get it out of the way
  reappeared. Clicking a parked window's taskbar entry restores it to where it
  was.
- **The parked flag is the user's choice, so it is enforced, not inferred.**
  `window.json` holds `parked` + the last on-screen rect (`l/t/r/b`), and
  `EnforceParked` re-parks the window whenever it finds it on screen while
  `parked` is true — called from `Track` (every captured frame) and from
  `GET /window?state=1` (so the poll alone is enough when nothing is capturing).
  Only an explicit show clears it. Inferring intent from the geometry was the bug:
  a new emulator creates its window on screen **and re-asserts that position when
  the guest finishes booting**, so the first on-screen frame flipped `parked` to
  false — the hide survived about a second, the window sat on the desktop behind
  everything with no taskbar entry left to click, and `/window?state=1` honestly
  answered `shown`, so the row menu offered **Hide** for a window the user had
  already hidden. `Rescue` (minimized window) now keeps the existing choice
  instead of forcing `parked` true.
- **Hiding the window is parking, not hiding.** `SW_HIDE` freezes the capture  (measured: `wgccap` served **0 frames in 3 s** hidden, then **182 in 3 s** after
  `SW_SHOWNOACTIVATE`), for the same reason minimizing does: no DWM surface, no
  frame. A window merely positioned outside the virtual screen keeps its surface —
  **159 frames in 3 s (~53 fps)** while parked. `GET /window?hidden=1|0|toggle`
  on **8777** parks/unparks it and remembers the last on-screen rect;
  `?state=1` reports `shown` / `hidden` / `no-emulator` as JSON. The state is read
  back from the window rect rather than from what the server last did, because
  the parked window can be brought forward by the user.
 - **A parked window is only invisible, not gone — so hiding also de-shells it.**
  Off-screen parking leaves a taskbar button (`qemu-system-x86_64 - 1 running
  window`, verified with UI Automation on `Shell_TrayWnd` before/after) and an
  Alt-Tab entry, which reads as "minimized" rather than hidden. Both capture
  paths therefore also call `ITaskbarList::DeleteTab(hwnd)` and add
  `WS_EX_TOOLWINDOW` to the ex-style (`SWP_FRAMECHANGED|NOSIZE|NOMOVE|NOZORDER|
  NOACTIVATE`, so geometry is untouched: rect identical before/after), and undo
  both on restore. Neither touches the DWM surface — frames kept arriving
  (`frames` 747 → 829) with both applied. `ITaskbarList` is STA while wgccap's
  main thread is MTA, so the COM call runs on a short-lived `ApartmentState.STA`
  background thread; never on the frame path.
 - **Restoring a parked window needs a foreground *change*.** `Track` /
  `RescueIfMinimized` put a parked window back when it becomes foreground — but
  only if the foreground moved away first (`sawFgOther` / `_sawOther`). Without
  that guard a window that was already in front when hidden was pulled straight
  back out of its parked position on the next tick. With stealth applied there is
  no taskbar button or Alt-Tab entry to click, so the mirror's **Show** button /
  the palette command is the way back.
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
| Toolbar `Hide` / `Show` | park the emulator window off-screen (still mirroring) | `/window?hidden=1\|0` |
| Toolbar `Start` / `Stop` | start the selected AVD, or stop the running one | `avd.ps1` on :8779 |
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
- **Wheel direction: natural scrolling by default.** Wheel-down drags the synthetic finger **up**, so the content scrolls forward (later items are revealed) — matching trackpad/macOS natural scrolling. The toolbar button **`Natural ⇅` / `Classic ⇅`** (element `#sdir`) flips it to the legacy inverted direction; the choice is persisted in `localStorage` under `mirror.scrollNatural` (default `"1"` = natural). The sign is applied at the only place that matters: `const sgn=naturalScroll?-1:1;` in the wheel handler. The word lives in `#sdir .lbl` and the compact layout hides it, leaving the bare `⇅` — the glyph plus the `title` is enough in a 320 px panel, and the word cost more width than any other control in the strip.
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
   powershell -ExecutionPolicy Bypass -File scripts/mirror.ps1 -Port 8777
   ```
3. Open **http://127.0.0.1:8777/** in a VS Code Simple Browser (`http://127.0.0.1:8777/` in the browser preview).
4. Status bar should read `live` + `WGC` (if it reads `PW`, wgccap didn't start — build it, below).

## Endpoints (verification)

```powershell
Invoke-WebRequest http://127.0.0.1:8777/build          # {"build":"<sha256/12>","pid":N} - which script is loaded
Invoke-WebRequest http://127.0.0.1:8779/build          # same for the AVD manager
Invoke-WebRequest http://127.0.0.1:8778/health        # "ok"
Invoke-WebRequest http://127.0.0.1:8778/status         # fps, frames, age=<ms>
Invoke-WebRequest http://127.0.0.1:8778/frame.jpg      # WGC JPEG (CORS *)
Invoke-WebRequest http://127.0.0.1:8777/frame.jpg      # PrintWindow JPEG (cropped to the guest display)
Invoke-WebRequest http://127.0.0.1:8777/gsize          # "1080x2280" (guest display)
Invoke-WebRequest "http://127.0.0.1:8777/window?state=1"        # {"ok":true,"state":"shown","hidden":false}
Invoke-WebRequest "http://127.0.0.1:8777/window?hidden=1"       # park off-screen, drop taskbar button + Alt-Tab entry
Invoke-WebRequest "http://127.0.0.1:8777/window?hidden=0"       # put it back where it was, restore both
Invoke-WebRequest "http://127.0.0.1:8777/touch?p=1:540:1200"   # pointer down
Invoke-WebRequest "http://127.0.0.1:8777/touch?p="             # lift all
Invoke-WebRequest "http://127.0.0.1:8777/input?nav=back"       # Back
Invoke-WebRequest "http://127.0.0.1:8777/input?key=KEYCODE_APP_SWITCH"
```

Freshness test: `adb shell input keyevent KEYCODE_APP_SWITCH` → `/status` `frames` increments within ~2 s.

## AVD management

`scripts/avd.ps1` owns the *emulator process* — which AVDs exist, which is running, starting and stopping — while `mirror.ps1` owns the capture and input of a running one. It is a separate small server on **8779** so the controls work with no mirror running, and so the mirror page can call it cross-origin.

- **8779 is a preference, not an assumption.** A loopback port can be left held by a process that no longer exists: `Get-NetTCPConnection` still lists it as `Listen`, `tasklist` cannot find the owner, connects are refused, and `bind` fails — so the manager cannot start, the tree's read fails, and the only thing the user sees is `fetch failed`. That is not hypothetical: a force-killed test process poisoned 8779 on this machine, and neither a window reload nor 45 s of waiting released it. `pickAvdPort()` therefore probes `[8779, 8781, 8782, 8783]`, adopts a manager that already answers, otherwise takes the first port it can *bind* (the only test that tells a stale socket from a free port, since both refuse connects), and the mirror server is started with `-AvdPort <chosen>`, which rewrites the page's `AVD_BASE`. The editor-tab CSP `connect-src` follows the same variable. A busy port is an inconvenience; the AVDs view still works, on 8781. The port must not move once the mirror is serving, because the served page has it baked in (`startAvdManager()` only re-picks while `serverProc` is null).

```powershell
powershell -ExecutionPolicy Bypass -File scripts/avd.ps1 -Command list
powershell -ExecutionPolicy Bypass -File scripts/avd.ps1 -Command status
powershell -ExecutionPolicy Bypass -File scripts/avd.ps1 -Command start -Name ai_dating
powershell -ExecutionPolicy Bypass -File scripts/avd.ps1 -Command stop
```

- **Enumerate with `emulator -list-avds`, not `avdmanager list avd`.** On this machine avdmanager reports the AVD as *"Corrupted AVD ini file"* even though the emulator boots it fine, so it would hide every AVD. `emulator -list-avds` lists them correctly.
- **The API level is not a `target` key** in `config.ini` here — it is embedded in the system image path (`image.sysdir.1 = system-images\android-34\...`). Reading `target` alone shows a blank API for every AVD.
- **Rotation needs `wm fixed-to-user-rotation enabled` first**, then `wm user-rotation lock N`. Alone, the lock stores and reads back correctly yet never moves the display.
- **Start and stop return immediately**; the state is read back from the system on each poll. The accept loop is single-threaded, so a request that blocked for the ~40 s an AVD takes to boot would stall every other request behind it.
- **Stop is graceful by default** (`adb emu kill`, waits for exit) and only forces when asked — a force stop loses unsaved guest state.
- **The extension's Stop always asks how to stop.** A QuickPick offers "Stop gracefully" first and "Force stop" second, and cancelling does nothing. The force option is never chosen silently, not even after a graceful stop has already failed — a force stop loses unsaved guest state, so the choice stays with the user every time.
- **The selected AVD is shared through `%LOCALAPPDATA%\avd-mirror-selected.txt`**, so `mirror.ps1` can start the same AVD on its own. When no emulator is running, `mirror.ps1` starts the selected AVD and waits for its window (≈5 s) rather than failing.
- **`Get-Content` returns a provider-decorated object inside the server** (it is a plain string in an interactive shell), so values read that way are cast with `[string]` — otherwise the selected AVD serialises into the JSON as a nested blob instead of its name.

AVD controls appear in two places: the **AVDs** view (start / stop / refresh, with the running one marked) and a picker in the **mirror page toolbar** for quick start/stop while the mirror is open.

- **The container lives in the Panel, not the Activity Bar, so its views are tabs.** VS Code renders a container's views as horizontal tabs only in the Panel; in the side bar they are stacked, collapsible sections — two headings that read as two vertical tabs and push the screen down by a header each. The Panel container makes `Screen` and `AVDs` proper tabs, and `Screen` is first in the `views` array because the first view is the one that opens. The price is height: a portrait phone in a ~200 px dock is small, so `AVD Mirror: Open Full Screen (Editor Tab)` is a `view/title` action on the Screen tab rather than a palette-only command.
- **A Panel container gets no Activity Bar icon, so the status bar carries the entry point.** `$(device-mobile) AVD Mirror` sits on the right and runs `avdMirror.open` (which focuses `avdMirror.view`, revealing the panel). Without it the only way back to a closed panel is the Command Palette, which is not where a running tool should live. There is no way to have both: this VS Code build has no sidebar tab mode (nothing for `horizontalTabs`, `viewContainer.tabs` or `sidebarTabs` in the workbench bundle), so the icon and the tabs are mutually exclusive.
  - **Where the mirror appears is chosen per AVD, from one entry in the row's menu.** The four surfaces — Panel, Editor Tab, Browser, Embedded Browser — are a single `view/item/context` entry, `avdMirror.toggleDisplay` at `2_display@1`, which opens a ticked QuickPick. A tree row cannot host a switch widget, and a menu contribution is the only per-item place VS Code lets a contribution act on one item; the list behind it is what can show four icons and four ticks at once (see the next bullet). The history matters because each earlier shape failed for a different reason: checkboxes on child rows (`TreeItem.checkboxState` + `onDidChangeCheckboxState`) cost a click to expand and put the state in a widget the row's own menu could not see; four inline icons (`inline@2`–`inline@5`) crowded start/stop out of a narrow panel; eight labelled menu pairs (show/hide per surface, gated on `avdMirror.shown.<key>`) had no icon on screen at all, because a menu row draws neither a codicon nor a tick. **Only the mirrored AVD's row offers the entry**, gated by a `Mirrored` suffix on the context value — a single context value cannot express two facts, so running/idle and mirrored are spelled out as four values (`avdRunning`, `avdIdle`, `avdRunningMirrored`, `avdIdleMirrored`) and the `when` clauses match with `||`. `chooseDisplay(arg)` takes the row's item and resolves it with `resolveAvdName`; with no item (the Command Palette) it acts on whatever the mirror is showing, which is why one command serves both places and they cannot drift apart.
- **Start/stop is the only inline button on the row.** ▶ appears on a stopped AVD and ⏹ on a running one, both at `inline@1`, gated on the plain `avdIdle`/`avdRunning` context values — stopping an AVD never requires it to be the mirrored one — while the surface switches in the menu are gated on the `Mirrored` ones. **Force stop stays in the row's right-click menu**, not inline: it is the rare, destructive action, and an icon beside the everyday stop invites the wrong click. The AVDs title bar keeps **Refresh** only — nothing that means one AVD lives in the header, because a `view/title` entry gets no item and can only act on "whatever the mirror happens to show".
  - **The inline strip holds power and nothing else.** Every extra inline action shrinks the label until a narrow panel drops the tail into `...`, and the one control that must never be guessed at is start/stop. Placement does not have that problem — it is opened deliberately — so the four surfaces are one entry in the menu, separated from **Select AVD** and **Force Stop** by the group names (`1_select`, `2_display@N`, `3_forcestop`).
  - **The emulator's own window is the one switch that stays a menu pair, and the one piece of state that has to be polled.** `Hide Emulator Window` / `Show Emulator Window` (`2_display@2`, gated on a *running* row because a stopped AVD has no window) stayed two entries because it is a single yes/no and a menu row can still list the one direction that applies. The surfaces cannot be *derived* on every render the way this can — the window is moved by the server, and by the page's own toolbar, and by the user clicking its taskbar entry — after which `Track()` restores it without telling anyone. So `syncEmulatorHidden()` asks `GET /window?state=1` from `syncDisplay()` (fire-and-forget, one loopback GET per 3 s poll, in-flight guard so a slow answer cannot stack) and the state becomes `avdMirror.emulatorHidden`, seeded to `false` at activation because an unset key matches `!key` but not `key` and the second half of the pair would silently vanish. `moveEmulatorWindow(mode)` takes `true`/`false` from the two menu entries and `'toggle'` from the palette, and always repaints from what the server *reports*, so a wrong guess cannot leave "Show" on a window that is already back. The pair is hidden from the Command Palette (`"when": "false"`): in a flat list there is no row to read the state from, and a stale "Hide" is a trap. `Hide / Show Emulator Window` stays palette-visible as the single toggle.
  - **"On" means "this AVD is on that surface", not "this AVD would like to be".** The mirror binds to one emulator window, so exactly one AVD can be shown at a time: which row carries the icons is derived on every render from `mirrorAvd()`. Acting on another AVD is refused with a warning that names the AVD in the way (or says the AVD is not running); quietly switching a surface on for something that will never appear would be worse than saying no. The alternative — a real per-AVD mirror — needs a capturer and port per emulator, which `wgccap --hwnd/--port` could do but is a feature, not a setting.
  - **Nothing that means one AVD lives in the header.** The AVDs title bar is down to **Refresh**: start/stop moved to an inline action on the row it applies to, and the four surface switches were only ever there as duplicates of the row's. A `view/title` entry gets no item, so it can only act on "whatever the mirror happens to show" — a second control for one piece of state, and the one that could not say which AVD it was about.
  - **The parked state lives in a file, because the stash cannot outlive the process.** `%LOCALAPPDATA%\avd-mirror\window.json` holds `{"parked":bool,"l","t","r","b"}` where the rect is the last *on-screen* position. `stashRect`/`haveStash` are per-process, which produced a trap: after `Restart Server` the window was still parked (so `HiddenState()` said `hidden`) while `SetHidden(false)` hit `if (!haveStash) return "shown"` and reported success without moving anything — an invisible window with no taskbar button and no Alt-Tab entry left to click, i.e. unreachable. The file is read by `LoadState()` (lazily, once), written by `ParkState()` only when the flag or the stashed rect actually changes (never per frame — `Track()` runs on every captured frame), and `Resume()` re-applies it to a window that was just adopted: once after `Add-Type` at startup, and in `Update-EmulatorTarget()` when a stopped AVD is replaced by a new emulator, which is what makes "hidden" survive an emulator restart. Two safety valves: a saved rect that is now entirely off the virtual screen (monitor unplugged) falls back to `virtual origin + 80`, and bringing a parked window back by hand (`Track()`'s restore branch, or an on-screen rect seen while `parked` is set) writes `parked:false` so a restart does not re-hide what the user un-hid. The same file keeps the headless path honest with `wgccap`: it has its own `_stash`/`Stealth`, and the ex-style bit — not the flag — is the shared source of truth between the two processes.
  - **A context-menu row draws neither an icon nor a tick, so the surface list is a QuickPick.** `MenuItemAction` does compute `action.class` from the command's `ThemeIcon`, but the menu's `doGetActionViewItem()` builds each entry with `{enableMnemonics, useEventAsContext, getKeyBinding}` and never passes `icon`, so `BaseMenuActionViewItem.updateClass()` takes its `else` branch and strips the `codicon` class again; a row is exactly `span.menu-item-check` + `span.action-label` (text) + keybinding, and the check span is the fixed `menuSelection` tick that VS Code paints from `toggled`, not from our state. `$(zap)` in a title is the other dead end — `updateLabel()` runs `stripIcons()` on it — and a stand-in character in the label (`▤`, `◉`) renders, but as a font glyph with no state behind it. So the state moved to where VS Code does draw both: `chooseDisplay(arg)` builds the four surfaces as QuickPick items with `iconPath: new ThemeIcon(...)` (the codicons `layout-panel`, `screen-full`, `globe`, `browser`) and `picked: displayShown(key)`, and one `view/item/context` entry opens it. The same function serves the Command Palette, so there is one implementation of "tick what you want" instead of eight commands. What the picker must get right: a row for an AVD the mirror is *not* showing starts with nothing ticked (its own ticks would promise a mirror that cannot appear there) and ticking one is refused through `setAvdDisplay`; only the difference between `picked` and the answer is applied, so re-opening a surface that is already open does not re-fetch the page. The `icon` codicons stay contributed because the inline strip, the `view/title` buttons and the palette *do* render them.
  - **`Embedded Browser` is the same page framed, not the page inlined.** The Editor Tab fetches the page and splices its `<style>`/`<body>` into the webview so it can talk to the extension over `postMessage`; that copy has to be re-fetched per paint and its root-relative URLs rewritten. The embedded surface instead sets `webview.html` to a full-bleed `<iframe src="http://127.0.0.1:8777/">` with `frame-src` for that origin in the meta CSP, and `mirror.ps1` answers with `Content-Security-Policy: frame-ancestors * vscode-webview: vscode-file: file:`. The live document brings its own scripts, styles and polling, so nothing has to be rewritten and the page cannot drift from what a real browser shows. It is deliberately an own `createWebviewPanel` rather than `simpleBrowser.show`: same rendered result, but the panel is ours to `dispose()`, so the switch is derived exactly (`!!embeddedPanel`) instead of hunting a built-in extension's tab through `tabGroups`, and switching it off can never close somebody else's Simple Browser tab. `startServer()` is awaited before the panel is created — a frame pointed at a closed port is a dead tab that never retries.
  - **`frame-ancestors *` does not cover a webview, and the failure is a silent black tab.** The first shipped version framed the live page and showed nothing but the tab title: Chromium had refused the frame with `Framing 'http://127.0.0.1:8777/' violates the following Content Security Policy directive: "frame-ancestors *". Note that '*' matches only URLs with network schemes ('http', 'https', 'ws', 'wss')`. A desktop webview's document is `vscode-webview:` and the workbench around it is `vscode-file://vscode-app/…`, so **both** are non-network ancestors that the server must name. `frame-ancestors` is checked against *every* ancestor, not just the immediate parent, so listing only the webview scheme would still be refused by the workbench above it. The fix lives in the server header, so an already-running server keeps serving the old one until it is restarted (`startServer()` treats a live `/gsize` as "up"). The page therefore also carries a "loading / has not loaded — run Restart Server" note behind the frame, because a CSP refusal produces no on-screen error at all.
  - **The framed page has to own keyboard focus, and `img.focus()` was a no-op.** All four surfaces type through one `keydown` listener on the page's own `document`, which fires whenever that document has focus — true on its own tab, and true for the inlined panel/editor copies, so only the embedded surface looked broken. A framed document starts without focus, and while clicking into it normally transfers focus, `pointerdown` calls `preventDefault()` (to keep text selection and native drags out of the gesture) and so cancels the browser's default focus transfer, leaving `img.focus()` as the only route — and an `<img>` without a `tabindex` is not focusable, so it silently did nothing. The screen image now carries `tabindex="-1"`: still out of the tab order, but `img.focus()` is real, so the click that starts a gesture also moves keyboard focus into the frame and later keystrokes reach the handler. Verified by framing the live page in a sandboxed iframe: with the old markup the frame reported `document.hasFocus() === false` and issued no `/input?text=` requests; with `tabindex` it reports focus and one request per character.
  - Two rules keep the switches honest: the **panel and both tabs are derived, never remembered** (`panelShown()`, `!!editorPanel`, `!!embeddedPanel`), so a tab closed by hand flips its own icon back through `onDidDispose`, and only the **browser** is a flag because `vscode.env.openExternal` is one-way — VS Code cannot close an external tab, so switching it off only stops counting it, which the command's tooltip says. The surface icons are **menu entries, not a row `command`**: an inline action fires once per click, whereas a `command` on a row that also hosts a state widget fires twice and looks dead.
  - **The Panel switch asks whether *our container* is open, not whether the Screen tab is showing.** Both views share the Panel, so `panelShown()` is `avdTreeView.visible || viewProvider.visible`. Deriving it from the Screen view alone made the icon read "hidden" the entire time the user was on the AVDs tab, which is the only tab where that control can be reached: flipping Panel looked inert. Both visibility handlers now call `syncDisplay()` themselves, because `refresh()` cannot resync a tree that is not on screen. `setDisplay('panel', true)` focuses the Screen tab unless it is already visible — showing the mirror in the panel means bringing that tab up, and the AVDs tab is one click away.
  - `setDisplay('editor', false)` **clears `editorPanel` before calling `dispose()`**: the icon is rendered from that variable and `onDidDispose` is the only other writer, so relying on the callback alone left the switch reading "on" when a stub or a failed dispose did not fire it.
  - **Switching Panel off blanks the mirror instead of closing a part.** `workbench.action.closePanel` was a no-op in the window this was reported from, because the AVD Mirror container had been dragged into the **side bar**: VS Code's stored `views.customizations` read `{"workbench.view.extension.avdMirror": 0}` (0 = side bar) with both views reassigned to a `workbench.views.service.sidebar.<uuid>` container. There is no API that answers "which part holds these views" and none to hide a single view, so the first attempt closed candidate parts in turn and remembered the winner in `globalState` — but closing the part also closes the AVDs view, which is where these very switches live, and the notification explaining that is a poor trade for a switch. The part is the user's layout; the mirror inside it is ours. So panel-off sets `panelMirror = false`, `panelShown()` becomes `panelMirror && (either view visible)`, and `MirrorViewProvider.paint()` short-circuits to `showBlank()` (a muted one-line hint) for the Screen view, leaving the container, the AVDs view, the status bar and the switches exactly where the user put them. Switching Panel back on repaints the mirror. The tab round trip while off stays blank because the flag lives in the extension, not in the webview.
- **Activation is `onStartupFinished` now, so activation must stay free.** The status bar item has to exist before the panel has ever been opened, which is the only reason the extension activates at startup. Nothing that spawns a process runs there: the servers start from `paint()`/`startServer()`, and the AVD tree polls only while it is visible (`onDidChangeVisibility`, plus `getChildren()` because an already-open tab does not fire an initial change event) — that poll is what spawns the manager on 8779. The platform and .NET warnings moved with it: they fire when the user opens the view, not on every window that happens to start.

- **The toolbar row is three zones, and only the middle one may shrink:** `#barrow` = `#bar` (the tool strip) + `#avdbar` (the AVD control) + `#helpbtn`. The strip is `flex:1 1 auto; min-width:64px`; the other two are pinned. In the compact layout — which is what the VS Code panel always uses, because the panel is short — the strip collapses to a single `nowrap` row with `overflow-x:auto` and a 4 px scrollbar, so anything at its far end is reachable only by scrolling it into view. That is why neither the help button nor the AVD control was left in that strip: an in-flow button at its end lands ~570 px past the right edge of a 320 px panel, and "start an emulator" is the reason the panel exists, so it must never be the thing that scrolls out of reach.
- **The AVD control is one button, not two.** `Start` and `Stop` are mutually exclusive states of the same thing, so two equal-weight buttons made the reader work out which one applied right now. The single button states the next action (`Start` → `Booting…` → `Stop`) and dispatches on `dataset.act`; it stays enabled during `starting` because that is also the cancel path, and `paintAvd()` is the only place that writes its label, its `act`, or the state dot's class, so the two can never disagree.
- **Status is a dot plus truncating text, and red is reserved for a lost connection.** `#status[data-state]` drives the dot (`live` green, `idle` amber, `error` red) and `setStatus()` is the only writer. A cold start reports "no emulator running" in amber; painting it red made every normal connect read as a failure. The text truncates (`min-width:34px` in compact) and carries a `title`, because "reconnecting… (no emulator running)" is long enough to reflow the whole strip by itself, and the frame counter is given `tabular-nums` and `ch` widths so 9 → 100 fps stops shoving every button to its right.
- **The mirror survives the emulator being replaced.** Stopping an AVD used to take the mirror down with it: the accept loop exited on emulator exit (`EMULATOR_EXITED`), so restarting the emulator left the page permanently on "reconnecting". The emulator's window handle and console port are now re-acquired on the request path (`Update-EmulatorTarget`), and the server keeps serving.
- **The WGC capturer is bound to the emulator *window*,** so a replaced emulator leaves it capturing a window that no longer exists — it stops producing frames and then exits, taking port 8778 with it. The capturer is restarted alongside the emulator, and a rate-limited liveness check (`Ensure-Capturer`, one `Get-Process` every 2 s) covers a capturer that dies for any other reason. Without this the page silently fell back to PrintWindow: slower, and it has the channel-swap tint bug.
- **"No emulator running" is a normal state,** not a lost connection, and the page says so in amber rather than reporting "reconnecting" in red. The mirror answers `/frame.jpg` with `503 no emulator running`, and the page reads the response body rather than only the status.
- **Toolbar chrome is themed; the surround is transparent, not black.** Everything that draws *chrome* — `#barrow`, buttons, selects, the help button — is painted from `--tb-*`, each of which is `var(--vscode-…, <the old GitHub-dark hex>)`, so the panel belongs to the editor in a light theme too. The letterbox around the screen (and the soft-key strip behind `#navbar`) used to be hard-coded `#000`, which left two black bars beside a themed panel. It is now `--bezel: transparent` over `--page: var(--tb-bg)`: the guest keeps `object-fit: contain` (never distort it), but the leftover area shows the toolbar surface, so in the webview it is the real VS Code background and in a plain tab it is the same slate as the toolbar. The **hardware keys** stay hard-coded: a key is an object, not a surface, and a themed key would vanish into the surface it sits on. `#navbar::before` paints `--softkey` only because it must hide the guest frame sliding underneath the strip.
  - Two host-specific traps: the webview cannot be transparent unless `html,body` are too *and* the inlined page's own `<style>` (injected later, equal specificity) is outranked — hence `class="embed"` on `<html>` plus `:root.embed{--page:transparent}`. A transparent page with no `--vscode-*` vars (the integrated browser tab has none) falls back to the canvas `#121212`, so "just delete the black" is *not* what you want; paint `--page` from `--tb-bg` instead.
- **The capture is not a clean rectangle, so the screen's bottom corners are patched.** The emulator's device skin rounds the display's bottom two corners, and that arc is *inside* the frame: a light curve at each bottom corner of a screen that is otherwise a hard edge, which reads as a rounded screen once the soft-key bar's hairlines run up to it. No CSS can add those pixels back, so `#sqL`/`#sqR` are 12 px canvases over the corners holding the frame's own content from one patch height above the arc (`patchCorners`, re-run from `layoutNav` because the source offset depends on the displayed scale). Copying real pixels is what keeps the patch invisible — a flat colour sampled from the frame would show as a dot the moment the bottom of the screen is not uniformly dark. The patch is positioned from `--imx/--imw/--imy/--imh`, so it follows the letterbox, and `pointer-events:none` keeps taps going to `#m` (verified with `elementFromPoint`). The top corners need no patch: the crop starts at the client area's top, which the window rounding does not reach.
- **The soft-key strip is one shade darker than the surfaces around it,** so it reads as the phone's chin rather than as more empty panel: `#navbar::before` paints `color-mix(in srgb, var(--softkey) 60%, #000)` (60% mix of `#161b22` → `#0d1014`) while the letterbox and toolbar stay at `--tb-bg`. The `color-mix` sits in a *second* `background` declaration after a plain `background: var(--softkey)`, never inside `--softkey` itself — custom properties are validated lazily, so an unsupported `color-mix` in the variable would make the using declaration invalid at computed-value time and the bar would go transparent instead of merely undarkened. Declared this way, a browser that cannot parse `color-mix` drops the second declaration and keeps the plain fill. Its three hairlines are the *same* colour as the fill (`border-color: color-mix(in srgb, var(--softkey) 60%, #000)`), so the chin is one solid block against the letterbox — any lighter outline turned it into a framed box. The mix is therefore written out twice, once for `background` and once for `border-color`, rather than hoisted into a local custom property: custom properties are validated lazily, so a browser without `color-mix` would lose the fill *and* the border colour together instead of falling back to the plain surface. Kept as second declarations, both degrade to `--softkey` and the strip stays a flat, visible block.
- **The webview's CSP must list port 8779.** The mirror page calls the AVD manager cross-origin; without it the panel's AVD picker reports "no manager" while the browser tab works fine (the tab has no CSP).
- **With no emulator running the screen goes blank and says so.** The page shows a centred "Emulator is not running" notice, clears the last frame (a stale screen reads as a live app that has merely frozen) and hides the on-screen keys, which would otherwise float over an empty area. The webview's own "Loading the mirror" hint stands down when the page shows this notice, so the two do not overlap.
- **A refused connection to a dead local port takes ~2 s to fail on this machine** (measured with a raw `TcpClient`, not just the browser). Polling a capturer that is not there therefore stalls the frame loop, which is why the no-emulator notice used to appear only after several seconds of "connecting...". The server now reports the capturer's state in the `/rot` reply (`WxH:R:C`), the page skips the WGC attempt when it knows the capturer is down, and it backs off for 5 s after a failure. The notice now appears in ~190 ms.

> ⚠️ If `/status` `age=` keeps growing while the guest screen is visibly changing, capture has **stalled**, not gone idle. Restart `wgccap.exe` — and check the two WGC traps above (`TryGetNextFrame` must be drained in a loop; the callback must not block). `/health` keeps answering `ok` while stalled, so health checks alone will not catch it.

> ⚠️ `age=` also grows legitimately on a **static** screen, because WGC only produces frames when content changes. To tell "idle" from "stalled", cause a screen change (e.g. a nav key) and confirm `frames` and `age=` both move.

## Platform and runtime guards

Three failures looked identical before this pass — a dead panel — so each now names itself.

- **Windows-only, enforced at activation, not in the manifest.** `package.json` has no `os` field that stops an extension loading, so on another platform the servers were spawned as `pwsh` against scripts that call `PrintWindow`, `ITaskbarList` and `SetWindowPos`. `activate()` now checks `process.platform` first, and `startServer()` / `startAvdManager()` refuse before spawning. The commands are still *registered* on the wrong platform: an unregistered command is reported as "command 'avdMirror.open' not found", which hides the real reason. The message is shown once (`platformReported`), and the panel body is `MirrorViewProvider.platformHtml()` rather than the "Loading the mirror from port 8777…" hint, which would sit there forever.
- **The .NET 8 runtime is checked before the capturer is asked for.** `src/wgccap` is framework-dependent (`net8.0-windows10.0.19041.0`, no `RuntimeIdentifier`), so it needs the **.NET 8 runtime**, not just any .NET: the apphost does not roll forward across a major version. Missing, the apphost exits immediately and the page quietly drops to PrintWindow. The probe reads `dotnet --list-runtimes` (trying `dotnet` on PATH, then `%ProgramFiles%\dotnet`, then the user-local `%LOCALAPPDATA%\Microsoft\dotnet`) and looks for `Microsoft.NETCore.App 8.` — the app is `OutputType=Exe` with no `UseWPF`/`UseWindowsForms`, so WindowsDesktop is only matched as a courtesy. The result is cached, logged, and only a definite `missing` produces a warning; a probe that cannot run at all reports `unknown` and stays silent, because no answer is not evidence of absence.
- **`Start-Process` succeeding means nothing.** It returns as soon as the process is created, so `mirror.ps1` used to log "WGC capturer started" for a capturer that had already died. `Start-Capturer` now returns `missing` / `died` / `timeout` / `ok`, and the startup call passes `-Verify` to wait for `/health` (≤6 s). Without `-Verify` it is fire-and-forget, because `Restart-Capturer` runs **on the request path**. That is also why `Restart-Capturer` now returns a bool and `Ensure-Capturer` backs off 30 s after a failure: a machine with no .NET 8 makes every restart fail after a 5 s wait, and retrying that every 2 s stalls the frame loop.
- **A spawn failure is an `'error'` event, not an exit code.** With no listener, `spawn` throws it out of the extension host and takes the extension down. `wireProc()` attaches the listener for the mirror and the AVD manager: `ENOENT` is reported as "powershell.exe not found on PATH", and the message names the label (`mirror server`, `AVD manager`). A non-zero exit adds a `Get-ExecutionPolicy -List` hint — `-ExecutionPolicy Bypass` on the command line covers every local scope but cannot override a `MachinePolicy`/`UserPolicy` set by Group Policy, which is the usual reason the same command works by hand and fails from the panel.
- **A server left behind by an older build is invisible from the outside, so the build identifies itself.** A reload of the extension host does not stop the powershell process that holds port 8777, and `isUp()` asking `/gsize` cannot tell which *version* answered — so the new extension adopted a server started from a previous installed folder and ran last build's capture and window code behind the new menu. That is what made "rebuild and reinstall" look like a no-op while the row menu still appeared to work, and why the persisted window state never got written. Both scripts now compute `$script:BuildId` (first 12 hex of SHA-256 of `$PSCommandPath`, read **at startup**, so it describes the file this process actually loaded) and answer `GET /build` with `{"build":...,"pid":N}`. `startServer()` / `startAvdManager()` hash the script they ship and compare: equal → reuse; different → stop and respawn; **no `/build` at all** → old by definition, replace. The pid comes from `/build`, falling back to `listenerPid()` (parsing `netstat -ano`), because a server too old to answer `/build` is exactly the one that cannot be asked for its pid. The extension no longer needs to be told to "Restart Server" after an upgrade.
- **The return value of `Restart-Capturer` matters.** It now yields `$true`/`$false`, so every call site that does not consume it is `[void](…)`. `Sync-AfterRotation` returning it would have appended `True` to the `/rot` response body (`WxH:R`) and broken the page's rotation parsing.

## Build wgccap

```powershell
$env:PATH = "$env:LOCALAPPDATA\Microsoft\dotnet;$env:PATH"   # user-local SDK 8
cd src/wgccap
dotnet build -c Release
```

Exe: `bin/Release/net8.0-windows10.0.19041.0/wgccap.exe` (no NuGet deps). The
versioned folder name is not hard-coded anywhere — `mirror.ps1` looks the
executable up under `src/wgccap/bin/Release/`, so a different target framework
or Windows SDK moves it without breaking the server.

Stop any running `wgccap.exe` before rebuilding — the running binary locks the output file.

## Notes / gotchas (interop)

- **Input path.** Gestures go through the emulator console, *not* adb: `adb shell input` is single-pointer (so no real pinch/two-finger pan) and `sendevent` is blocked by SELinux. The console connection is opened on demand, drained before each write, and re-opened if it drops (a dropped console makes `/touch` return 503 and the page shows `touch unavailable`).
- **Pointer state, not events.** `/touch` always sends the *whole* current pointer set, so the page may coalesce rapid moves; the guest still sees a correct multi-touch stream (that is exactly how a real touchscreen reports).
- The bridge from `HWND` → `GraphicsCaptureItem` needs three literal IIDs (reflection returns *wrong* synthesized GUIDs under CsWinRT):
  - `IGraphicsCaptureItemInterop` = `3628E81B-3CAC-4C60-B7F4-23CE0E0C3356`
  - `IGraphicsCaptureItem` (item IID) = `79C3F95B-31F7-4EC2-A464-632EF5D30760`
  - `IDXGIDevice` = `54ec77fa-1377-44e6-8c32-88fd5f44c84c`
- Stop: `Stop-Process -Id <pid>` for the powershell running `mirror.ps1` and any `wgccap.exe`.
