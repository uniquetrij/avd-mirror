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
const AVD_REL = 'scripts/avd.ps1';
// The AVD manager is a separate small server so the controls work whether or
// not a mirror is running, and so the mirror page can call it cross-origin
// exactly as it already calls wgccap on 8778.
const AVD_PORT = 8779;
const AVD_URL = `http://${HOST}:${AVD_PORT}`;

let serverProc = null;
let avdProc = null;
// The AVD tree provider, kept at module scope so deactivate() can stop its
// polling timer even when deactivate() is called on its own.
let avdTreeRef = null;
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

/** Locate avd.ps1 - the AVD manager. Same search order as mirror.ps1. */
function findAvdScript() {
  const candidates = [
    path.join(__dirname, '..', AVD_REL),
    path.join(__dirname, AVD_REL),
  ];
  for (const ws of (vscode.workspace.workspaceFolders || [])) {
    const uri = ws.uri;
    if (uri.scheme !== 'file') continue;
    candidates.push(path.join(uri.fsPath, '.github', 'skills', 'mirror-emulator', AVD_REL));
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

// --- AVD manager -------------------------------------------------------------
// The manager is a separate server on 8779 so the AVD controls work with no
// mirror running, and so the mirror page can reach it cross-origin.

async function avdManagerUp() {
  try {
    const res = await fetch(`${AVD_URL}/health`, {
      signal: AbortSignal.timeout(700),
      cache: 'no-store',
    });
    return res.status === 200;
  } catch {
    return false;
  }
}

async function startAvdManager() {
  if (await avdManagerUp()) return true;
  const script = findAvdScript();
  if (!script) {
    output.appendLine('avd.ps1 not found - AVD controls unavailable');
    return false;
  }
  try {
    avdProc = spawn(
      psExe(),
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
       '-File', script, '-Port', String(AVD_PORT)],
      { detached: false, windowsHide: true }
    );
    avdProc.stdout.on('data', d => output.append(d.toString().trimEnd()));
    avdProc.stderr.on('data', d => output.append(d.toString().trimEnd()));
    avdProc.on('exit', code => {
      output.appendLine(`AVD manager exited (${code})`);
      avdProc = null;
    });
    for (let tries = 0; tries < 30; tries++) {
      await new Promise(r => setTimeout(r, 200));
      if (await avdManagerUp()) {
        output.appendLine('AVD manager ready');
        return true;
      }
    }
    output.appendLine('AVD manager did not come up');
    return false;
  } catch (e) {
    output.appendLine(`AVD manager start failed: ${e && e.message ? e.message : e}`);
    return false;
  }
}

function stopAvdManager() {
  if (!avdProc) return;
  const p = avdProc;
  avdProc = null;
  try { p.kill(); output.appendLine('stopped AVD manager'); }
  catch (e) { output.appendLine(`AVD manager stop failed: ${e}`); }
}

/** Read the AVD inventory from the manager. */
async function avdState() {
  try {
    const res = await fetch(`${AVD_URL}/avds`, { cache: 'no-store' });
    if (!res.ok) return null;
    return await res.json();
  } catch {
    return null;
  }
}

async function avdCommand(path) {
  await startAvdManager();
  try {
    const res = await fetch(`${AVD_URL}${path}`, { method: 'POST', cache: 'no-store' });
    const body = await res.json().catch(() => ({}));
    return { ok: res.ok && body.ok !== false, body };
  } catch (e) {
    return { ok: false, body: { error: e && e.message ? e.message : String(e) } };
  }
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
    // The AVD manager comes up first: the mirror may need it to start the
    // selected AVD when nothing is running yet.
    await startAvdManager();
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
    // Cache-bust the URL as well as sending no-store: this fetch runs in the
    // extension host, whose HTTP cache is separate from the webview's, and a
    // stale copy here silently pins old CSS in the panel across server restarts.
    const res = await fetch(`${base}/?t=${Date.now()}`, { cache: 'no-store' });
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
        // Always re-fetch. The page embeds the mirror's CSS, and this provider is
        // asked to paint on every visibility change, so a cached copy here pins
        // whatever CSS was current at first load into the panel for the rest of
        // the session - edits to mirror.ps1 appeared to have no effect at all.
        this._page = await loadPage();
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
          // 8777 is the mirror, 8778 the WGC capturer, 8779 the AVD manager.
          // The AVD manager has to be listed or the page's AVD picker is
          // blocked by CSP and reports "no manager" even though the manager
          // is running - the browser tab has no CSP, which is why the same
          // controls worked there and not in the panel.
          `connect-src ${base} http://${HOST}:8778 http://${HOST}:8779`,
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
                    return;
                  }
                  // The page shows its own "Emulator is not running" notice when
                  // there is no emulator. Stand down so that notice is visible
                  // rather than covered by this hint, which sits on top of the
                  // whole webview.
                  const ne = document.getElementById('noemu');
                  if (ne && !ne.hidden) { hint.style.display = 'none'; }
                }
                const watch = setInterval(checkFrame, 250);
                window.addEventListener('DOMContentLoaded', () => report('booted', 'doc=' + document.documentElement.clientWidth + 'x' + document.documentElement.clientHeight));
                setTimeout(() => {
                  clearInterval(watch);
                  if (!shown) {
                    const ne = document.getElementById('noemu');
                    if (ne && !ne.hidden) {
                      // The page has already said what is wrong; do not talk over it.
                      report('inlined-no-emulator', 'no emulator running');
                    } else {
                      msg.textContent = 'No frames yet. Check the AVD Mirror output channel, or open in browser.';
                      report('inlined-timeout', 'no frame');
                    }
                  }
                }, 8000);
        // Layout probe. The panel is a different host from a browser tab - different
        // width, different gutter, and the compact media query can apply - so
        // measuring in a browser says nothing about the panel. This reports the
        // real numbers from whatever host renders it, on every resize, so a
        // detached or clipped key can be read straight off the log.
        function measureKeys(tag) {
          const stage = document.getElementById('stage');
          if (!stage) return;
          const cs = getComputedStyle(stage);
          const num = v => parseFloat(cs.getPropertyValue(v)) || 0;
          const sb = stage.getBoundingClientRect();
          const imx = num('--imx'), imw = num('--imw');
          const screenL = sb.left + imx, screenR = screenL + imw;
          const g = id => {
            const el = document.getElementById(id);
            return el ? el.getBoundingClientRect() : null;
          };
          const up = g('volup'), dn = g('voldown'), pw = g('pwr');
          if (!up || !dn || !pw) return;
          const f = n => Math.round(n * 100) / 100;
          report('keys', tag
            + ' doc=' + document.documentElement.clientWidth + 'x' + document.documentElement.clientHeight
            + ' gutter=' + f(imx)
            + ' volW=' + f(up.width)
            + ' volUpGap=' + f(screenL - up.right)
            + ' volDnGap=' + f(screenL - dn.right)
            + ' volPairGap=' + f(up.top - dn.bottom)
            + ' pwrGap=' + f(pw.left - screenR)
            + ' volClipL=' + f(sb.left - up.left)
            + ' pwrClipR=' + f(pw.right - sb.right)
            + (f(screenL - up.right) > 1 || f(screenL - dn.right) > 1 ? '  <<< DETACHED' : '')
            + (sb.left - up.left > 1 || pw.right - sb.right > 1 ? '  <<< CLIPPED' : ''));
        }
        setTimeout(() => measureKeys('t1s'), 1000);
        setTimeout(() => measureKeys('t3s'), 3000);
        let rt;
        window.addEventListener('resize', () => {
          clearTimeout(rt);
          rt = setTimeout(() => measureKeys('resize'), 250);
        });
      </script>
      ${page || ''}
      </body>
      </html>`;
        }
}

// --- AVD tree view -----------------------------------------------------------
// One row per AVD, showing which one is running and which is selected. The
// list is re-read from the manager rather than cached, so an AVD created or
// deleted elsewhere appears without a reload.
class AvdTreeProvider {
  constructor() {
    this._onDidChangeTreeData = new vscode.EventEmitter();
    this.onDidChangeTreeData = this._onDidChangeTreeData.event;
    this._state = null;
    this._timer = null;
  }

  refresh() {
    this._onDidChangeTreeData.fire();
  }

  async poll() {
    await startAvdManager();
    const st = await avdState();
    if (st) {
      this._state = st;
      this.refresh();
    }
  }

  start() {
    if (this._timer) return;
    this.poll();
    this._timer = setInterval(() => this.poll().catch(() => {}), 3000);
  }

  stop() {
    if (this._timer) { clearInterval(this._timer); this._timer = null; }
  }

  getTreeItem(el) {
    const st = this._state || {};
    const running = st.running === el.name;
    const selected = st.selected === el.name;
    const item = new vscode.TreeItem(
      el.name,
      running
        ? vscode.TreeItemCollapsibleState.None
        : vscode.TreeItemCollapsibleState.None
    );
    item.description = running
      ? '● running'
      : (selected ? '○ selected' : '');
    // A clear icon per state beats a colour alone: the tree is small and the
    // running/selected distinction has to be readable at a glance.
    item.iconPath = new vscode.ThemeIcon(
      running ? 'vm-active' : (selected ? 'vm-outline' : 'vm'),
      running ? new vscode.ThemeColor('charts.green')
               : (selected ? new vscode.ThemeColor('charts.blue') : undefined)
    );
    item.tooltip = `${el.name}${el.api ? ' - ' + el.api : ''}${el.device ? ' - ' + el.device : ''}`;
    item.contextValue = running ? 'avdRunning' : 'avdIdle';
    item.command = {
      command: 'avdMirror.selectAvd',
      title: 'Select AVD',
      arguments: [el.name],
    };
    return item;
  }

  async getChildren() {
    if (!this._state) await this.poll();
    const st = this._state || {};
    return (st.avds || []).map(a => ({ name: a.name, api: a.api, device: a.device }));
  }
}

/**
 * Work out which AVD a command should act on.
 *
 * The same command is reachable from three places and each hands over a
 * different kind of argument:
 *   - the view title bar  -> the TreeView object
 *   - an item's context menu -> the tree item (an object with .name)
 *   - the command palette -> nothing at all
 *
 * Passing the argument straight through meant the title bar's start button
 * asked the manager to start an AVD literally named "[object Object]". Only a
 * plain string is an AVD name; a tree item contributes its .name; anything else
 * means "no AVD was named", which falls back to the selected one.
 */
function resolveAvdName(arg) {
  if (typeof arg === 'string') return arg.trim();
  if (arg && typeof arg === 'object' && typeof arg.name === 'string') return arg.name.trim();
  return '';
}

/** Select an AVD, which is what the mirror starts next time. */
async function selectAvd(arg) {
  const name = resolveAvdName(arg);
  if (!name) {
    vscode.window.showWarningMessage('AVD Mirror: no AVD to select.');
    return;
  }
  await startAvdManager();
  try {
    await fetch(`${AVD_URL}/avd/select?name=${encodeURIComponent(name)}`, { cache: 'no-store' });
  } catch (e) {
    vscode.window.showErrorMessage(`AVD Mirror: could not select ${name} - ${e && e.message ? e.message : e}`);
    return;
  }
  vscode.window.setStatusBarMessage(`AVD Mirror: selected ${name}`);
}

/** Start an AVD and wait until the guest is actually up. */
async function startAvd(arg) {
  const named = resolveAvdName(arg);
  const target = named || (await avdState() || {}).selected;
  if (!target) {
    vscode.window.showWarningMessage('AVD Mirror: no AVD selected.');
    return;
  }
  await vscode.window.withProgress(
    { location: vscode.ProgressLocation.Notification, title: `AVD Mirror: starting ${target}` },
    async () => {
      const r = await avdCommand(`/avd/start?name=${encodeURIComponent(target)}`);
      if (!r.ok) {
        vscode.window.showErrorMessage(`AVD Mirror: start failed - ${r.body.error || 'unknown error'}`);
        return;
      }
      // The AVD takes ~40 s to boot. Wait for it so the mirror is usable the
      // moment the notification closes, and so a failure is reported here
      // rather than as a blank panel later.
      for (let i = 0; i < 120; i++) {
        await new Promise(r => setTimeout(r, 1000));
        const st = await avdState();
        if (!st) continue;
        if (st.status === 'running') {
          vscode.window.setStatusBarMessage(`AVD Mirror: ${target} running`);
          return;
        }
        if (st.status === 'stopped') {
          vscode.window.showErrorMessage(`AVD Mirror: ${target} did not start.`);
          return;
        }
      }
      vscode.window.showWarningMessage(`AVD Mirror: ${target} is taking longer than expected to boot.`);
    }
  );
}

/** Stop the running AVD. Always asks how to stop unless force is already decided. */
async function stopAvd(force) {
  const st = await avdState();
  if (!st || (!st.running && st.status !== 'starting')) {
    vscode.window.setStatusBarMessage('AVD Mirror: no AVD running');
    return;
  }
  if (force) {
    await avdCommand('/avd/stop?force=1');
    vscode.window.setStatusBarMessage('AVD Mirror: emulator stopped');
    return;
  }
  // Ask each time, with the graceful stop offered first. A force stop kills the
  // emulator process outright and loses unsaved guest state, so it is never
  // chosen silently - not even when the graceful stop has already failed.
  const choice = await vscode.window.showQuickPick(
    [
      {
        label: 'Stop gracefully',
        description: 'Ask the emulator to shut down cleanly',
        detail: 'The emulator saves its state and exits on its own.',
      },
      {
        label: 'Force stop',
        description: 'Kill the emulator process now',
        detail: 'Unsaved guest state is lost.',
      },
    ],
    { title: st.running ? `Stop "${st.running}"?` : 'Stop the emulator?', placeHolder: 'Choose how to stop' }
  );
  if (!choice) return;   // dismissed - do nothing

  const isForce = choice.label === 'Force stop';
  await vscode.window.withProgress(
    { location: vscode.ProgressLocation.Notification, title: 'AVD Mirror: stopping emulator' },
    async () => {
      const r = await avdCommand(`/avd/stop?force=${isForce ? 1 : 0}`);
      if (!r.ok && r.body.error) {
        const forceNow = await vscode.window.showWarningMessage(
          `AVD Mirror: ${r.body.error}`,
          'Force stop'
        );
        if (forceNow === 'Force stop') {
          await avdCommand('/avd/stop?force=1');
          vscode.window.setStatusBarMessage('AVD Mirror: emulator force-stopped');
        }
        return;
      }
      vscode.window.setStatusBarMessage(
        isForce ? 'AVD Mirror: emulator force-stopped' : 'AVD Mirror: emulator stopped'
      );
    }
  );
}

function activate(context) {
  const provider = new MirrorViewProvider();
  const avdTree = new AvdTreeProvider();
  avdTreeRef = avdTree;
  // The AVD list has to be live: an emulator started or stopped from the
  // mirror page's own toolbar must show up here without a reload.
  avdTree.start();
  context.subscriptions.push({ dispose: () => avdTree.stop() });
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
      vscode.window.createTreeView('avdMirror.avds', { treeDataProvider: avdTree }),
      vscode.commands.registerCommand('avdMirror.selectAvd', (name) => selectAvd(name)),
      vscode.commands.registerCommand('avdMirror.startAvd', (name) => startAvd(name)),
      vscode.commands.registerCommand('avdMirror.stopAvd', () => stopAvd(false)),
      vscode.commands.registerCommand('avdMirror.forceStopAvd', () => stopAvd(true)),
      vscode.commands.registerCommand('avdMirror.refreshAvds', () => avdTree.poll()),
      vscode.commands.registerCommand('avdMirror.openInEditor', openInEditor),      vscode.commands.registerCommand('avdMirror.open', () => {
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
  stopAvdManager();
  // The AVD tree polls on a timer. It is also disposed through the
  // subscriptions list, but deactivate() has to be safe on its own - a live
  // interval keeps the extension host's event loop busy after the extension
  // has gone.
  if (avdTreeRef) avdTreeRef.stop();
}

module.exports = { activate, deactivate };