'use strict';
// Hosts the AVD mirror page inside a VS Code panel instead of a browser tab.
// The page itself is served by scripts/mirror.ps1, which owns the screen
// capture and the multi-touch injection; this extension only manages that
// server's lifetime and embeds the result.

const vscode = require('vscode');
const { spawn } = require('child_process');
const http = require('http');
const path = require('path');
const fs = require('fs');

const PORT = 8777;
const HOST = '127.0.0.1';
const MIRROR_URL = `http://${HOST}:${PORT}/`;
const REL = 'scripts/mirror.ps1';

let serverProc = null;
let output = vscode.window.createOutputChannel('AVD Mirror');
let starting = false;

/**
 * Locate mirror.ps1.
 *
 * VS Code *copies* an installed extension into ~/.vscode/extensions/<id>/, so the
 * sibling ../scripts path only holds while developing inside the skill folder.
 * An installed copy has to fall back to the skill in the open workspace, so both
 * layouts are searched before giving up.
 */
function findMirrorScript() {
  const candidates = [
    // running from the skill folder itself (development / symlinked install)
    path.join(__dirname, '..', REL),
    // bundled next to the extension code
    path.join(__dirname, REL),
  ];
  for (const ws of (vscode.workspace.workspaceFolders || [])) {
    const uri = ws.uri;
    if (uri.scheme !== 'file') continue;
    candidates.push(path.join(uri.fsPath, '.github', 'skills', 'mirror-emulator', REL));
  }
  return candidates.find(p => fs.existsSync(p));
}

function isUp(cb) {
  // /gsize is the cheapest liveness probe the server offers: no capture, no
  // touch state to disturb. There is no /health on this port.
  const req = http.get(`${HOST}:${PORT}/gsize`, res => {
    res.resume();
    cb(res.statusCode === 200);
  });
  req.on('error', () => cb(false));
  req.setTimeout(700, () => { req.destroy(); cb(false); });
}

function psExe() {
  return process.platform === 'win32' ? 'powershell.exe' : 'pwsh';
}

function startServer() {
  if (starting) return;
  isUp(async up => {
    if (up) {
      output.appendLine('mirror server already listening');
      return;
    }
    starting = true;
        const script = findMirrorScript();
        if (!script) {
      starting = false;
          vscode.window.showErrorMessage(
            'AVD Mirror: mirror.ps1 not found. Open the folder containing .github/skills/mirror-emulator.'
          );
          output.appendLine('mirror.ps1 not found in any known location');
          return;
        }
    output.appendLine(`starting: ${script} -Port ${PORT}`);
    // Hidden, like the documented manual launch, so the mirror never steals
    // focus or opens a console window over the editor.
    serverProc = spawn(
      psExe(),
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
       '-File', script, '-Port', String(PORT)],
      { detached: false, windowsHide: true }
    );
    serverProc.stdout.on('data', d => output.append(d.toString().trimEnd()));
    serverProc.stderr.on('data', d => output.append(d.toString().trimEnd()));
    serverProc.on('exit', code => {
      output.appendLine(`mirror server exited (${code})`);
      serverProc = null;
      starting = false;
    });

    // Poll for readiness so we can refresh the panel the moment frames exist,
    // instead of leaving a dead iframe in front of the user.
    let tries = 0;
    const tick = () => {
      isUp(ok => {
        if (ok) {
          starting = false;
          output.appendLine('mirror server ready');
          vscode.commands.executeCommand('avdMirror.reload');
          return;
        }
        if (++tries > 40) {
          starting = false;
          output.appendLine('mirror server did not come up; see output');
          vscode.window.showWarningMessage('AVD Mirror server did not start - see the AVD Mirror output channel.');
          return;
        }
        setTimeout(tick, 250);
      });
    };
    setTimeout(tick, 400);
  });
}

function stopServer() {
  if (!serverProc) {
    output.appendLine('server not started by this session');
    return;
  }
  const p = serverProc;
  serverProc = null;
  try { p.kill(); output.appendLine('stopped mirror server'); }
  catch (e) { output.appendLine(`stop failed: ${e}`); }
}

/** Webview view provider for the activity-bar panel. */
class MirrorViewProvider {
  constructor() {
    this._view = undefined;
  }

  resolveWebviewView(webviewView) {
    this._view = webviewView;
    webviewView.webview.options = { enableScripts: true };
    webviewView.webview.html = this._html();
    // The panel is usually opened while the server is still down, so start it
    // the first time the view becomes visible.
    startServer();
    webviewView.onDidChangeVisibility(() => {
      if (webviewView.visible) startServer();
    });
  }

  reload() {
    if (this._view) this._view.webview.html = this._html();
  }

  _html() {
    // Only the loopback mirror origin may be framed; everything else is denied.
    const csp = [
      "default-src 'none'",
      `frame-src http://${HOST}:${PORT}`,
      "style-src 'unsafe-inline'",
      "img-src data:",
    ].join('; ');
    return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="${csp}">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<style>
  html,body{margin:0;height:100%;background:#000;overflow:hidden}
  iframe{border:0;width:100%;height:100%;display:block;background:#000}
  #hint{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;
        color:#8b949e;font:12px var(--vscode-font-family);text-align:center;padding:1rem;pointer-events:none}
</style>
</head>
<body>
<iframe src="${MIRROR_URL}" title="AVD Mirror"></iframe>
<div id="hint">Waiting for the mirror server on port ${PORT}...<br>AVD Mirror: Start Server</div>
<script>
  // Clear the hint as soon as the framed page actually paints.
  const f = document.querySelector('iframe');
  f.addEventListener('load', () => {
    document.getElementById('hint').style.display = 'none';
  });
</script>
</body>
</html>`;
  }
}

function activate(context) {
  const provider = new MirrorViewProvider();
  context.subscriptions.push(
    vscode.window.registerWebviewViewProvider('avdMirror.view', provider),
    vscode.commands.registerCommand('avdMirror.open', () => {
      vscode.commands.executeCommand('avdMirror.view.focus');
      startServer();
    }),
    vscode.commands.registerCommand('avdMirror.start', startServer),
    vscode.commands.registerCommand('avdMirror.stop', stopServer),
    vscode.commands.registerCommand('avdMirror.restart', () => {
      stopServer();
      setTimeout(startServer, 600);
    }),
    vscode.commands.registerCommand('avdMirror.reload', () => provider.reload()),
    output
  );
}

function deactivate() {
  stopServer();
}

module.exports = { activate, deactivate };