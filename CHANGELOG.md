# Changelog

Notable changes to **AVD Mirror**. This project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) in the 0.x sense:
the minor version changes for anything that alters how the extension behaves,
the patch version for fixes.

## 0.3.46

- **The window switch moved left of power.** Both inline actions spend the row's
  hover strip, and order there is the `@N` suffix, not the order they appear in
  the manifest: the window pair is now `inline@1` and start/stop `inline@2`, so
  the icon you reach for while the AVD keeps running is not the one that ends it.

## 0.3.45

- **The emulator window switch is on the row only.** 0.3.44 also put it in the
  AVDs title bar; two buttons for one state, with no way to tell which was
  current, was one too many. `avdMirror.emulatorWindow` and the `/window?state=1`
  plumbing that fed it are gone with it — the row already knows whether the AVD
  is running, and the title bar is back to **Refresh** alone.

## 0.3.44

- **Hide/Show Emulator Window moved inline.** It was a right-click entry on the
  AVD row; it is now an icon on the row itself, next to ▶/⏹, and a button in the
  AVDs view's title bar. A context-menu row can draw no codicon, so the only way
  to give it an icon was to stop putting it there. The icons are `$(empty-window)`
  for **Hide** and `$(window)` for **Show**, swapped by the same
  `avdMirror.emulatorHidden` context key the menu already used.
- The title bar needed a second gate. A row knows whether its AVD is running from
  the item's own state, but a title-bar button has no row: without one it offered
  to hide a window that was not there. `avdMirror.emulatorWindow` now carries the
  server's `/window?state=1` answer (`no-emulator` is the only value that means
  the window is gone), set from the same poll that already tracks the hidden flag.

## 0.3.43

- **New option: honour `FLAG_SECURE`.** Off by default, because mirroring a
  secure window is the point of a host-side capture. Turned on, the mirror stops
  showing anything while the window in front of the guest sets `FLAG_SECURE` —
  the screen is replaced by a "Protected content" notice, and no frame is
  requested from the capturer while it is up. That is what a screenshot of the
  guest would give you: `screencap` on Android 14 writes a 0-byte file rather
  than a black one, and nothing on the guest side can be told to relax the flag
  (it is enforced in SurfaceFlinger; `ro.secure`/`settings` have no bearing), so
  the only thing the mirror can do is notice and stop. Note that this covers the
  **page** only: the capturer is a separate process reading the emulator's host
  window, so `/frame.jpg` on either port keeps serving live frames while the
  notice is up. Treat the option as a courtesy to whoever is looking at the
  mirror, not as protection from anyone else on the machine.
- The verdict comes from the server (`adb shell dumpsys window`, the focused
  window's `fl=` line) and rides on the page's existing `/rot` poll as a fifth
  field; the policy is one setting, `avdMirror.honourFlagSecure`, pushed to the
  server at `/secure` so every surface obeys the same switch. Detection costs
  ~75 ms and is cached for a second, and it is only ever run when the option is
  on — with it off, the check is a single boolean.
- **The inlined panel now reaches `/rot`.** `loadPage()` rewrites the page's
  root-relative endpoints to the server's origin before inlining it into a
  webview, and `/rot` was not on that list: the panel never got the guest's size,
  orientation or capturer state from the server, and fell back to the portrait
  defaults until the first frame arrived. The `FLAG_SECURE` verdict only reaches
  the page through `/rot`, so the panel could not have obeyed it either.

## 0.3.42

- **The row menu's surface switches are one entry that opens a ticked list.**
  VS Code builds a context-menu row from a check span and a plain text label, so
  it draws neither a contributed codicon nor a tick — the eight `Show Mirror
  in …` / `Hide Mirror from …` entries could not show which surface was on.
  The AVD row's menu now offers **Choose Where to Show**, which opens the four
  surfaces — Panel, Editor Tab, Browser, Embedded Browser — as one multi-select
  with their real codicons and a tick for every surface that is on screen right
  now. Tick two to have the mirror in both places, untick one to close it; only
  the difference is applied, so nothing already open is re-fetched. The same
  command and the same list serve the Command Palette, and the eight per-surface
  commands (and the context keys they were gated on) are gone with the entries
  that needed them.
- **No more stand-in characters in menu labels.** The previous preview build led
  each entry with a geometric glyph (`▤`, `◉`, `◆`) because a menu row cannot draw
  an icon; with the list carrying the codicons, every label is plain text again.

## 0.3.40

- **Typing works in the Embedded Browser surface.** The framed page starts
  without keyboard focus, and the pointer handler's `preventDefault()` — there to
  keep text selection and native drags out of a gesture — also cancels the
  browser's default focus transfer. The only remaining call, `img.focus()`, did
  nothing because an `<img>` without a `tabindex` is not focusable, so focus
  stayed in the webview around the frame and every keystroke missed the page's
  `keydown` listener. The screen image is now focusable (`tabindex="-1"`, still
  out of the tab order), so clicking the mirror — the first thing a gesture does
  anyway — moves focus into the frame and typing reaches the guest. The other
  three surfaces were never affected: there the page *is* the document, so it
  already had focus.

## 0.3.39

- **A hidden emulator stays hidden.** Parking was recorded as an observation
  ("the window is on screen") rather than as the user's choice, so the first
  captured frame after a new emulator finished booting — which re-asserts its own
  window position — cleared the flag. The window then sat on the desktop behind
  everything with no taskbar button to click, while the state query honestly
  answered `shown` and the row menu offered **Hide**. The flag is now enforced:
  the window is re-parked whenever it is found on screen while the flag is set,
  from every captured frame and from the state poll, and only **Show** clears it.
- A start from the **AVDs** list refreshes the window state as soon as the AVD
  reports running, so the row menu flips to **Show** without waiting for the poll.
- **A server left behind by an older build is replaced instead of adopted.** Both
  servers report a hash of the script they actually loaded on `GET /build`, and
  the extension stops and restarts one whose hash differs from the copy it ships —
  including one that has no `/build` at all, which predates the handshake. Rebuilding
  no longer silently runs last build's capture and window code.

## 0.3.38

- The AVD manager is validated the same way as the mirror server: whatever answers
  on a candidate port is checked against the shipped script's hash rather than
  adopted on `/health` alone.

## 0.3.37

- The emulator's parked state and last on-screen rect are stored in
  `%LOCALAPPDATA%\avd-mirror\window.json`, so **Show** restores the window after a
  server restart or an emulator restart, not just an extension reload.

## 0.3.36

- **Hide / Show Emulator Window** added to an AVD row's context menu, gated on the
  window's live state, alongside the existing palette toggle.

## 0.3.35

- The per-AVD surface switches (Panel, Editor Tab, Browser, Embedded Browser) moved
  from the row's inline strip into its context menu. The inline strip holds only
  start/stop.

## 0.3.34

- **Embedded Browser** surface: the mirror as a full-bleed `<iframe>` in an editor
  tab, with the CSP relaxed for that origin.

## 0.3.33

- A port left behind by a dead process no longer disables the AVD controls: a
  bindable candidate port is chosen instead, so `fetch failed` cannot masquerade as
  "no AVDs".

## 0.3.32

- The AVD inventory reports *why* it could not be read, instead of rendering an
  empty list that looked identical to having no AVDs.

## 0.3.31

- The AVDs title bar is down to **Refresh**: nothing that means one AVD lives in the
  header, where a title-bar entry gets no item and can only act on "whatever the
  mirror happens to show".

## 0.3.30

- The AVDs view moved into the **Panel** container so it can sit beside the mirror,
  with the status bar item as the way in.

## 0.3.29

- **Hide** de-shells the window as well as parking it: `ITaskbarList::DeleteTab`
  removes the taskbar button and `WS_EX_TOOLWINDOW` removes the Alt-Tab entry, so it
  reads as gone rather than minimized — without touching the DWM surface the
  capture reads.

## 0.2.1

- First version published as its own project, with the hide/show toggle that parks
  the emulator window off-screen while mirroring continues at full rate.

## 0.1.0 – 0.2.0

- Host-side mirroring with Windows Graphics Capture, multi-touch forwarding through
  the emulator console, auto-rotation, on-screen keys, and the AVD selector.
