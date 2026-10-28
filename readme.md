# AVD Mirror

Mirrors an Android emulator window **inside a VS Code panel** instead of a
browser tab, the same way the scrcpy extensions present a device screen inside
the editor.

The screen is captured on the **host** side (Windows Graphics Capture), so it
works even when the emulator window is in the background, fully occluded, or
showing a `FLAG_SECURE` screen that in-guest capture (scrcppy, `screencap`)
would return black. Gestures are streamed to the guest as real pointer events,
so every gesture the emulator understands — tap, hold, drag, swipe, fling,
pinch, two-finger pan, edge system-nav — behaves as it does on the device.

## Requirements

- **Windows 10 build 19041 or newer.** The capture is Windows Graphics Capture
  and the window handling is Win32, so the extension says so once and stops on
  any other platform rather than failing with a dead panel.
- **An Android SDK with at least one AVD**, found under `%LOCALAPPDATA%\Android\Sdk`,
  `%ANDROID_HOME%` or `C:\Android\Sdk`.
- **The .NET 8 runtime**, for the full-rate capturer: the bundled `wgccap.exe` is
  framework-dependent. Without it the mirror still runs on `PrintWindow` — slower,
  and it has the channel-swap tint — and the extension warns once, with a link,
  instead of silently serving the fallback.

## Why a panel rather than a tab

The mirror is a live, clickable screen, not a document. A browser tab brings
address-bar chrome and tab management to something you interact with
continuously. In a panel it sits beside the editor, keeps focus for keyboard
input, and never gets lost among other tabs.

## Layout

| Path | What it is |
|---|---|
| `extension.js` | the VS Code extension: supervises the servers, embeds the page, hosts the AVD tree view |
| `scripts/mirror.ps1` | the mirror server (port 8777) and the whole browser page it serves |
| `scripts/avd.ps1` | the AVD manager (port 8779, or the next free one): list / start / stop / select AVDs |
| `src/wgccap/` | the .NET 8 Windows.Graphics.Capture capturer (port 8778) |
| `harness.js` | runs the extension against a mock VS Code API, so runtime errors show up without the extension host |
| `SKILL.md` | the technical reference: capture internals, endpoints, and the traps in each part |

The project root *is* the extension: `package.json` sits beside `extension.js`,
so the relative path to `scripts/` is the same in a checkout and in an
installed VSIX.

## Use

1. Open the **AVD Mirror** panel: click **$(device-mobile) AVD Mirror** in the
   status bar, run `AVD Mirror: Open Panel` from the Command Palette
   (`Ctrl+Shift+P`), or pick **AVD Mirror** from the Panel's `...` menu at the
   bottom of the window.
2. The panel has two horizontal tabs, **Screen** and **AVDs**. Screen starts
   `mirror.ps1` on port 8777 if it is not already running; the frame appears as
   soon as the server answers. **AVDs** lists every AVD with its state. Click a row
   to make it the one the mirror shows; the ▶ button on a stopped row starts it,
   ⏹ on a running one stops it, and right-click offers **Force Stop AVD** for a
   guest that ignores the request.
3. Where the mirror appears is chosen **per AVD**. Every AVD row in the **AVDs**
   tree carries its own switches — **Show/Hide in Panel**, **Editor Tab**,
   **Browser**, **Embedded Browser** — in the row's right-click menu (`...` or
   right-click on the AVD), so nothing has to be expanded: pick one to open or
   close that surface for that AVD. A filled glyph means the surface is on; its
   hollow twin means it is off, so the current placement is readable without
   opening anything; only the entry that matches the state is listed.
   - The mirror binds to one emulator window, so only one AVD at a time can be on
     screen. That is why the row menu only offers switches on the AVD the mirror
     is showing; asking for another AVD is refused with a message naming the AVD
     in the way.
   - The icons follow reality: close the editor tab by hand and the glyph goes
     hollow again. **Panel** means the mirror is being drawn into the AVD Mirror
     container — either of its tabs counts, so the switch stays on while you are
     reading the AVD list. Turning it off **blanks the screen** rather than
     closing anything: the panel (or side bar), the AVDs view and these switches
     all stay put, and clicking Panel again brings the mirror back.
   - **Browser** cannot be closed by VS Code: turning it off stops the extension
     counting that tab as shown, nothing more. **Embedded Browser** is the same
     page framed inside an editor tab, so it stays inside VS Code and turning it
     off really does close the tab.
   - `AVD Mirror: Choose Where to Show` (Command Palette) offers the same
     switches for the current AVD as one multi-select, so "panel and browser, but
     no editor tab" is a state you can hold.
4. Full height is one click away — the `⤢` action in the Screen tab's title bar,
   or `AVD Mirror: Open Full Screen (Editor Tab)`, opens the same mirror as an
   editor tab.
5. Command Palette → `AVD Mirror:` for Open Panel / Choose Where to Show / Start /
   Stop / Restart / Reload.

Server logs go to the **AVD Mirror** output channel. If the **Embedded Browser**
tab ever shows only a message that the mirror page has not loaded, run
`AVD Mirror: Restart Server` and reopen the tab: the tab is a frame around the
running server, and a server started by an older version can outlive a reload.

If the **AVDs** view says the manager could not start, the output channel names
the port it tried: ports 8779, then 8781–8783. A port can be left behind by a
process that has exited, in which case it refuses connections yet cannot be
bound; the extension moves to the next one instead of failing, and returns to
8779 once it is free again.

The page also runs on its own at <http://127.0.0.1:8777/> — the extension only
embeds it.

### Hiding the emulator window

The **Hide** button in the mirror's toolbar (or `AVD Mirror: Hide / Show Emulator
Window` from the Command Palette) takes the emulator off the desktop completely,
and the mirror keeps running at full rate; **Show** puts it back exactly where it
was.

"Hiding" is three changes to the window, none of which touches the DWM surface
the capture reads (measured: frames keep arriving with all three applied):

| Change | Effect |
| --- | --- |
| move to just outside the virtual screen | nothing on screen |
| `ITaskbarList::DeleteTab` | no taskbar button |
| `WS_EX_TOOLWINDOW` on the ex-style | no Alt-Tab entry |

The window cannot be hidden outright or minimized away: a `SW_HIDE` or minimized
window leaves the DWM composition, so it produces no frames at all (measured: 0
frames in 3 s hidden, ~53 fps parked). Minimizing is therefore also treated as
"park it" — both capture paths restore the window, move it off-screen and apply
the same two shell changes.

Since the parked window has no taskbar button and no Alt-Tab entry, the only way
back is **Show** in the mirror toolbar or the Command Palette command.

## What the extension does and does not do

It only supervises `scripts/mirror.ps1` and embeds `http://127.0.0.1:8777/`.
All screen capture, JPEG encoding, stale-contact reaping and multi-touch
injection live in that server — the extension adds no input handling of its
own, so behaviour is identical to opening the page in a browser.

The mirror server binds to loopback only, and `mirror.ps1` sends
`Content-Security-Policy: frame-ancestors *` so the webview can embed it.

## Build

The WGC capturer is a .NET 8 program; build it once for the full-rate path
(the server falls back to `PrintWindow` if it is missing — slower, and it has a
channel-swap tint bug):

```powershell
cd src/wgccap
dotnet build -c Release
```

## Install from source

```powershell
cd C:\Users\uniqu\Projects\avd-mirror
npx @vscode/vsce package --allow-missing-repository
code --install-extension avd-mirror-<version>.vsix --force
```

The VSIX bundles `scripts/` and the built capturer, so the installed extension
is self-contained and works in any workspace.

Then run **Developer: Reload Window** once so VS Code registers the new view.

## Test the extension

```powershell
node harness.js
```

The harness activates the extension against a mock `vscode` API, invokes every
registered command and checks the argument shapes VS Code passes them.
