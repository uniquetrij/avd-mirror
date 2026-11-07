# AVD Mirror

Mirrors an Android emulator window **inside a VS Code panel** instead of a
browser tab, the same way the scrcpy extensions present a device screen inside
the editor.

The screen is captured on the **host** side (Windows Graphics Capture), so it
works even when the emulator window is in the background, fully occluded, or
showing a `FLAG_SECURE` screen that in-guest capture (scrcppy, `screencap`)
would return black. Gestures are streamed to the guest as real pointer events,
so every gesture the emulator understands — tap, hold, drag, swipe, fling,
pinch, two-finger pan, edge system-nav — behaves as it does on the device. If
you would rather the mirror respect `FLAG_SECURE`, there is an option for that:
see [Honouring `FLAG_SECURE`](#honouring-flag_secure).

<!-- Screenshots: drop media/screenshots/{mirror-panel,avds-menu}.png in place
     (see media/screenshots/README.md) and uncomment this block.

![The mirror panel with the AVDs view beside it](media/screenshots/mirror-panel.png)

![An AVD's context menu: per-AVD surfaces and Hide Emulator Window](media/screenshots/avds-menu.png)
-->

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
3. Where the mirror appears is chosen **per AVD**. Right-click an AVD row (or its
   `...`) and pick **Choose Where to Show**: one ticked list of the four surfaces
   — **Panel**, **Editor Tab**, **Browser**, **Embedded Browser** — each with its
   codicon and each ticked where it is on screen right now. Tick two to have the
   mirror in both places, untick one to close it.
   - The surfaces are one menu entry because of how VS Code builds a context
     menu: a plain text label and a check span. A row there can draw neither a
     codicon nor a tick, so the icons and the state live in the list the entry
     opens.
   - The mirror binds to one emulator window, so only one AVD at a time can be on
     screen. That is why the row menu only offers the switches on the AVD the
     mirror is showing; ticking a surface for another AVD is refused with a
     message naming the AVD in the way.
   - The ticks follow reality: close the editor tab by hand and its tick clears.
     **Panel** means the mirror is being drawn into the AVD Mirror container —
     either of its tabs counts, so the switch stays on while you are reading the
     AVD list. Turning it off **blanks the screen** rather than closing anything:
     the panel (or side bar), the AVDs view and this menu all stay put, and
     ticking Panel again brings the mirror back.
   - **Browser** cannot be closed by VS Code: turning it off stops the extension
     counting that tab as shown, nothing more. **Embedded Browser** is the same
     page framed inside an editor tab, so it stays inside VS Code and turning it
     off really does close the tab.
   - `AVD Mirror: Choose Where to Show` (Command Palette) opens the same list for
     the AVD the mirror is showing, so the keyboard route and the row menu cannot
     drift apart.
   - **Hide Emulator Window** (or **Show Emulator Window** once it is parked) is
     an icon on the row itself, to the left of ▶/⏹, so the real emulator can be
     taken off the desktop without leaving the AVD row. It is offered only on a
     running AVD, because a stopped one has no window to move. See [Hiding the
     emulator window](#hiding-the-emulator-window).
4. Full height is one click away — the `⤢` action in the Screen tab's title bar,
   or `AVD Mirror: Open Full Screen (Editor Tab)`, opens the same mirror as an
   editor tab.
5. Command Palette → `AVD Mirror:` for Open Panel / Choose Where to Show / Start /
   Stop / Restart / Reload.

Server logs go to the **AVD Mirror** output channel. A server left behind by an
older version of the extension is replaced automatically: `mirror.ps1` and
`avd.ps1` report a hash of the script they actually loaded on `/build`, the
extension compares it with the copy it ships, and a server whose hash differs — or
which has no `/build` at all, and so predates the handshake — is stopped and
started again from the current build. Before that handshake existed, an old
server kept serving old capture and window code behind a new menu, so a rebuild
looked like it had done nothing. The output channel names the case when it
happens (`mirror server is a stale build ... - replacing it`).

If the **AVDs** view says the manager could not start, the output channel names
the port it tried: ports 8779, then 8781–8783. A port can be left behind by a
process that has exited, in which case it refuses connections yet cannot be
bound; the extension moves to the next one instead of failing, and returns to
8779 once it is free again.

The page also runs on its own at <http://127.0.0.1:8777/> — the extension only
embeds it.

### Hiding the emulator window

The **Hide** button in the mirror's toolbar, the **Hide Emulator Window** icon on
an AVD row, or `AVD Mirror: Hide / Show Emulator Window` from the Command Palette
takes the emulator off the desktop completely, and the mirror keeps running at
full rate; **Show** puts it back exactly where it was. Every entry point lists only
the direction that applies — **Hide** while the window is on the desktop, **Show**
once it is parked — because they read the window's real state from the server
rather than remembering what the extension last asked for.

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
back is **Show** in the mirror toolbar, the AVD row, or the Command Palette
command.

The parked state is remembered, in
`%LOCALAPPDATA%\avd-mirror\window.json`:

```json
{"parked":true,"l":116,"t":125,"r":625,"b":1210}
```

So it survives the things that used to lose it:

| Restart | Result |
| --- | --- |
| Reload VS Code / the extension | state re-read from the server, menu still offers **Show** |
| `Restart Server` | window stays parked, and **Show** still restores its position |
| Stop AVD → Start (or reboot) | the new emulator window is parked on sight |

`l/t/r/b` is the last on-screen rect. It used to be stashed in the server
process's memory, so after a restart **Show** reported success without moving
any window — the one state the user could not get out of, since the parked
window has no shell entry left to click.

`parked` is the user's *choice*, not a note of where the window was: while it is
true the server puts the window back off-screen whenever it finds it on the
desktop, and only **Show** clears it. This matters because a fresh emulator
creates its window on screen *and then re-asserts that position itself* when the
guest finishes booting. Treating "the window is on screen" as "the user wants it
there" made a hide last about a second: the window came back onto the desktop,
behind everything, with its taskbar entry already deleted — visible only until
another window covered it, and with the menu offering **Hide** because the
server reported what it saw rather than what was asked for.

### Honouring `FLAG_SECURE`

The capture is host-side, so a window that sets `FLAG_SECURE` — a bank, a
password manager, a checkout — is mirrored like any other. That is deliberate,
and it is the reason the extension exists: in-guest capture (`scrcpy`,
`adb shell screencap`) gets nothing from those windows.

If you would rather see what a screenshot would see, turn on **Honour
FLAG_SECURE**: `AVD Mirror: Honour FLAG_SECURE` in the Command Palette opens a
two-row list with the setting that is in force ticked, and the setting itself is
`avdMirror.honourFlagSecure` (default `false`). While it is on and the window in
front of the guest sets the flag, the mirror shows a **Protected content** notice
instead of the screen, and it stops asking the capturer for frames until the
secure window goes away. All four surfaces follow the same switch, because the
policy is held by the server, not by the page.

What it cannot do is turn the flag off. `FLAG_SECURE` is enforced inside the
guest — SurfaceFlinger refuses to hand the pixels to a screenshot, and on
Android 14 `screencap` writes a 0-byte file rather than a black one. No setting
or property relaxes it (`ro.secure`, `settings list secure`, `wm` — none of them
have any bearing); only a patched framework on a rooted image would. So the
choice is between mirroring the window and pretending it is not there, and this
option is the second.

It is a courtesy to the person looking at the mirror, not a barrier. The notice
is drawn by the page, so only the page is covered: while it is up,
`http://127.0.0.1:8777/frame.jpg` and the capturer's
`http://127.0.0.1:8778/frame.jpg` both keep returning live frames. The capturer
is a separate process reading the emulator's **host window** through Windows
Graphics Capture, which never asks Android for anything, so it has no flag to
honour — and neither does any other process on the machine. Screenshot the panel
and you get the notice; fetch either endpoint and you get the screen.

## What the extension does and does not do

It only supervises `scripts/mirror.ps1` and embeds `http://127.0.0.1:8777/`.
All screen capture, JPEG encoding, stale-contact reaping and multi-touch
injection live in that server — the extension adds no input handling of its
own, so behaviour is identical to opening the page in a browser.

The mirror server binds to loopback only, and `mirror.ps1` sends
`Content-Security-Policy: frame-ancestors *` so the webview can embed it.

## Build

The WGC capturer is a .NET 8 program; build it once for the full-rate path
(needs the .NET 8 **SDK**, not just the runtime; the server falls back to
`PrintWindow` if the capturer is missing — slower, and it has a channel-swap
tint bug):

```powershell
cd src/wgccap
dotnet build -c Release
```

## Install from source

```powershell
git clone https://github.com/uniquetrij/avd-mirror
cd avd-mirror
cd src/wgccap; dotnet build -c Release; cd ../..
npx @vscode/vsce package
code --install-extension avd-mirror-<version>.vsix --force
```

The VSIX bundles `scripts/` and the built capturer, so the installed extension
is self-contained and works in any workspace. The capturer's `bin/` folder is
not in the repository, so build it first — otherwise the VSIX packages without
`wgccap.exe` and the mirror runs on the `PrintWindow` fallback.

Then run **Developer: Reload Window** once so VS Code registers the new view.

## Test the extension

```powershell
node harness.js
```

The harness activates the extension against a mock `vscode` API, invokes every
registered command and checks the argument shapes VS Code passes them.
