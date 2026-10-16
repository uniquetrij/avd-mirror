'use strict';
// Hosts the AVD mirror page inside a VS Code panel instead of a browser tab.
// The page itself is served by scripts/mirror.ps1, which owns the screen
// capture and the multi-touch injection; this extension only manages that
// server's lifetime and embeds the result.

const vscode = require('vscode');
const { spawn } = require('child_process');
const path = require('path');
const os = require('os');
const fs = require('fs');

// Frame load diagnostics land here so a blank panel can be explained without
// needing the webview devtools open.
const FRAME_LOG = path.join(os.tmpdir(), 'avd-mirror-frame.log');

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

// /gsize is the cheapest liveness probe the server offers: no capture, no touch
// state to disturb. There is no /health on this port.
//
// This deliberately uses the global fetch rather than Node's http module: VS Code
// patches http/https with its own proxy agent, and that patched `get` throws
// "TypeError: Invalid URL" from inside the extension host, which surfaced as
// "An error occurred while loading view". fetch is not patched that way.
// Failures are swallowed and reported as "not up" - a probe must never be able
// to take the panel down with it.
async function isUp() {
  try {
    const res = await fetch(`http://${HOST}:${PORT}/gsize`, {
      signal: AbortSignal.timeout(700),
      cache: 'no-store',
    });
    return res.status === 200;
  } catch {
    return false;
  }
}

function psExe() {
  return process.platform === 'win32' ? 'powershell.exe' : 'pwsh';
}

async function startServer() {
  if (starting) return;
  if (await isUp()) {
    output.appendLine('mirror server already listening');
    return;
  }

  starting = true;
  try {
    const script = findMirrorScript();
    if (!script) {
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
    });

    // Poll for readiness so we can refresh the panel the moment frames exist,
    // instead of leaving a dead iframe in front of the user.
    for (let tries = 0; tries < 40; tries++) {
      await new Promise(r => setTimeout(r, 250));
      if (await isUp()) {
              output.appendLine('mirror server ready');
              vscode.commands.executeCommand('avdMirror.reload');
              return;
            }
    }
    output.appendLine('mirror server did not come up; see output');
    vscode.window.showWarningMessage('AVD Mirror server did not start - see the AVD Mirror output channel.');
  } catch (e) {
    output.appendLine(`start failed: ${e && e.stack ? e.stack : e}`);
    vscode.window.showErrorMessage(`AVD Mirror: failed to start - ${e && e.message ? e.message : e}`);
  } finally {
    starting = false;
  }
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

/** Fetch the mirror page and make it self-contained for a webview. */
async function loadPage() {
  // Build the origin in one place: a `replace(':', '://')` on `HOST:PORT` would
    // match the wrong colon and produce the unparseable "127.0.0.1://8777".
    const base = `http://${HOST}:${PORT}`;
    const res = await fetch(`${base}/`, { cache: 'no-store' });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    let html = await res.text();
    // The webview supplies its own <head> (CSP, base styles), but the mirror's CSS
    // lives in the page's <head> - slicing the body alone would drop every style and
    // leave an unstyled page. Carry the page's <style> blocks over into the body.
    const styles = (html.match(/<style[\s\S]*?<\/style>/gi) || []).join('\n');
    const b = html.indexOf('<body>');
    const e = html.lastIndexOf('</body>');
    let bodyHtml = '';
    if (b >= 0 && e > b) bodyHtml = html.slice(b + 6, e);
    html = styles + bodyHtml;
    // The page addresses its own endpoints with root-relative paths ('/touch',
    // '/input', '/gsize', '/frame.jpg'). Inlined into a webview those would
    // resolve against the webview origin and 404, so point them at the server.
    html = html.replace(/(['"])\/(touch|input|gsize|frame\.jpg)\b/g, `$1${base}/$2`);
    return html;
}

/** Webview view provider for the activity-bar panel. */
class MirrorViewProvider {
  constructor() {
    this._view = undefined;
    this._editor = undefined;
    this._page = null;
  }

  /** Set HTML on a webview once the page is available, else show the hint. */
  async paint(target) {
    try {
      if (!this._page) this._page = await loadPage();
      target.webview.html = this._html(this._page);
    } catch (e) {
      output.appendLine(`paint failed: ${e && e.message ? e.message : e}`);
      target.webview.html = this._html(null);
    }
  }

  resolveWebviewView(webviewView) {
      try {
        this._view = webviewView;
        webviewView.webview.options = { enableScripts: true };
        // Never let supervision break the view: startServer already swallows its own
        // errors, and anything escaping it would blank the whole panel.
        // Must *return* the promise: callers chain .then() onto it, and a block-bodied
        // arrow with no return yields undefined -> "Cannot read properties of
        // undefined (reading 'then')", which blanks the whole panel.
        const safeStart = () => startServer().catch(e => output.appendLine(`startServer: ${e}`));
        webviewView.webview.onDidReceiveMessage(msg => {
          if (msg && msg.type === 'frame') {
            const line = `[frame] ${msg.state} ${msg.detail}`;
            output.appendLine(line);
            try { fs.appendFileSync(FRAME_LOG, line + '\n'); } catch (e) { /* best effort */ }
          }
        });
        const paint = () => Promise.resolve(safeStart()).then(() => this.paint(webviewView))
          .catch(e => output.appendLine(`paint: ${e}`));
        paint();
        webviewView.onDidChangeVisibility(() => { if (webviewView.visible) paint(); });
      } catch (e) {
        // Last line of defence: an exception here is what VS Code reports as
        // "An error occurred while loading view". Show something rather than fail.
        output.appendLine(`resolveWebviewView: ${e && e.stack ? e.stack : e}`);
        try { webviewView.webview.html = this._html(null); } catch (_) { /* give up */ }
      }
    }

  reload() {
    this._page = null;
    if (this._view) this.paint(this._view);
    if (this._editor) this.paint(this._editor);
  }

  _html(page) {
        const base = `http://${HOST}:${PORT}`;
        // The page is inlined rather than iframed. A webview iframe to a loopback
        // http origin reported a successful load and a contentWindow here, but
        // never painted - while the same page renders fine in a plain browser. The
        // webview's own origin is not 127.0.0.1, so the inlined copy needs CORS
        // from mirror.ps1 (it now sends Access-Control-Allow-Origin), and its
        // relative endpoints are rewritten to absolute URLs below.
        const csp = [
          "default-src 'none'",
          `connect-src ${base} http://${HOST}:8778`,
          `img-src ${base} data: blob: http://${HOST}:8778`,
          "style-src 'unsafe-inline'",
          "script-src 'unsafe-inline'",
        ].join('; ');
        return `<!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="${csp}">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <style>
      html,body{margin:0;height:100%;background:#000;overflow:hidden}
      #hint{position:absolute;inset:0;display:flex;flex-direction:column;gap:.6em;align-items:center;
            justify-content:center;color:#8b949e;font:12px var(--vscode-font-family);text-align:center;
            padding:1rem;background:#000;z-index:9}
      #hint a{color:#4daafc;cursor:pointer}
    </style>
    </head>
    <body>
      <div id="hint">
        <div id="msg">Loading the mirror from port ${PORT}...</div>
        <a id="fallback" href="${MIRROR_URL}" target="_blank">Open in browser</a>
      </div>
      <script>
        const vscodeApi = acquireVsCodeApi();
        const hint = document.getElementById('hint');
        const msg = document.getElementById('msg');
        function report(state, detail) {
          try { vscodeApi.postMessage({ type: 'frame', state, detail: String(detail || '') }); } catch (e) {}
        }
        // The inlined page paints into its own <img id="m">. Watch that element
                // rather than an Image() of our own: an unsourced Image never fires load,
                // so the hint would sit on top of a perfectly good mirror forever.
                let shown = false;
                function checkFrame() {
                  const el = document.getElementById('m');
                  if (el && el.naturalWidth > 0) {
                    if (!shown) { shown = true; report('inlined-ok', el.naturalWidth + 'x' + el.naturalHeight); }
                    hint.style.display = 'none';
          }
                }
                const watch = setInterval(checkFrame, 250);
                window.addEventListener('DOMContentLoaded', () => report('booted', 'doc=' + document.documentElement.clientWidth + 'x' + document.documentElement.clientHeight));
                setTimeout(() => {
                  clearInterval(watch);
                  if (!shown) {
                    msg.textContent = 'No frames yet. Check the AVD Mirror output channel, or open in browser.';
                    report('inlined-timeout', 'no frame');
                  }
                }, 8000);
      </script>
      ${page || ''}
      </body>
      </html>`;
        }
}

function activate(context) {
  const provider = new MirrorViewProvider();
    // A supervision failure must never escape into a view provider or panel:
    // that is what produces "An error occurred while loading view".
    // Must return the promise, for the same reason as in resolveWebviewView.
    const safeStart = () => startServer().catch(e => output.appendLine(`startServer: ${e}`));

    // A portrait phone screen is unreadable in a sidebar panel that is wide but
    // only ~130 px tall, so offer the same mirror full-height in an editor tab too.
    let editorPanel;
    const openInEditor = () => {
      if (editorPanel) { editorPanel.reveal(vscode.ViewColumn.Active); return; }
      editorPanel = vscode.window.createWebviewPanel(
        'avdMirror.editor', 'AVD Mirror',
        vscode.ViewColumn.Active, { enableScripts: true, retainContextWhenHidden: true }
      );
      editorPanel.webview.html = provider._html(null);
      provider._editor = editorPanel;
      editorPanel.onDidDispose(() => { editorPanel = undefined; provider._editor = undefined; });
            safeStart().then(() => provider.paint(editorPanel))
              .catch(e => output.appendLine(`openInEditor paint: ${e}`));
    };

    context.subscriptions.push(
      vscode.window.registerWebviewViewProvider('avdMirror.view', provider),
      vscode.commands.registerCommand('avdMirror.openInEditor', openInEditor),
      vscode.commands.registerCommand('avdMirror.open', () => {
        vscode.commands.executeCommand('avdMirror.view.focus');
        safeStart();
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