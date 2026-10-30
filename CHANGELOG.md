# Changelog

Notable changes to **AVD Mirror**. This project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) in the 0.x sense:
the minor version changes for anything that alters how the extension behaves,
the patch version for fixes.

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
