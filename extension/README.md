# AVD Mirror (VS Code extension)

Hosts the AVD Mirror page in a **VS Code panel** instead of a browser tab, the
same way the scrcpy extensions present a device screen inside the editor.

## Why a panel rather than a tab

The mirror is a live, clickable screen, not a document. A browser tab brings
address-bar chrome and tab management to something you interact with
continuously. In a panel it sits beside the editor, keeps focus for keyboard
input, and never gets lost among other tabs.

## Use

1. Click the **AVD Mirror** icon in the Activity Bar (left side).
2. The panel opens and the extension starts `mirror.ps1` on port 8777 if it is
   not already running; the frame appears as soon as the server answers.
3. Command Palette (`Ctrl+Shift+P`) → `AVD Mirror:` for Open Panel / Start /
   Stop / Restart / Reload.

Server logs go to the **AVD Mirror** output channel.

## What it does and does not do

It only supervises `scripts/mirror.ps1` and embeds `http://127.0.0.1:8777/`.
All screen capture, JPEG encoding, stale-contact reaping and multi-touch
injection live in that server — this extension adds no input handling of its
own, so behaviour is identical to opening the page in a browser.

The mirror server binds to loopback only, and `mirror.ps1` sends
`Content-Security-Policy: frame-ancestors *` so the webview can embed it.

## Install from source

```powershell
cd .github/skills/mirror-emulator/extension
npx @vscode/vsce package
code --install-extension avd-mirror-0.1.0.vsix
```

Then run **Developer: Reload Window** once so VS Code registers the new view.