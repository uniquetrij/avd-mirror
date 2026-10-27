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
// Where the mirror is on screen right now. The panel and the editor tab are read
// back from the live view/panel instead of being remembered, so the checkboxes
// in the AVDs view cannot claim a surface that is no longer there - a tab closed
// by hand has to clear its own box. Only the browser is a flag: VS Code can hand
// a URL to the default browser but has no way to close that tab again.
let viewProvider = null;
let editorPanel = null;
let browserOpened = false;
let output = vscode.window.createOutputChannel('AVD Mirror');
let starting = false;

/**
 * Locate a script that ships with this project.
 *
 * The VSIX bundles scripts/ next to the extension code, and a checkout has the
 * very same layout, so `__dirname/scripts/...` is the path that works in both.
 * The other candidates cover a checkout where the extension is run from a
 * subfolder, the project opened as a workspace, and the old location of this
 * code inside the ai-dating skill folder.
 */
function findScript(rel) {
  const candidates = [
    // shipped in the VSIX, and the same relative path in a checkout
    path.join(__dirname, rel),
    // extension code in a subfolder of the project
    path.join(__dirname, '..', rel),
  ];
  for (const ws of (vscode.workspace.workspaceFolders || [])) {
    const uri = ws.uri;
    if (uri.scheme !== 'file') continue;
    // the project itself, opened as a workspace
    candidates.push(path.join(uri.fsPath, rel));
    // the old home of this code, still used by existing checkouts
    candidates.push(path.join(uri.fsPath, '.github', 'skills', 'mirror-emulator', rel));
  }
  return candidates.find(p => fs.existsSync(p));
}

/** Locate mirror.ps1 - the screen capture and input server. */
function findMirrorScript() {
  return findScript(REL);
}

/** Locate avd.ps1 - the AVD manager. */
function findAvdScript() {
  return findScript(AVD_REL);
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

// --- platform guard ----------------------------------------------------------
// Everything below is Windows-only: mirror.ps1 calls PrintWindow, ITaskbarList
// and SetWindowPos, and src/wgccap uses Windows Graphics Capture. package.json
// has no field that stops an extension loading on a given OS, so the check has
// to happen at activation - otherwise the servers spawn `pwsh` against scripts
// that call Win32 APIs and the panel dies with no explanation at all.
const WINDOWS_ONLY_HELP =
  'AVD Mirror needs Windows 10 (build 19041 or newer): it captures the emulator ' +
  'window with Windows Graphics Capture and moves that window with Win32 APIs.';

function unsupportedPlatform() {
  return process.platform !== 'win32';
}

let platformReported = false;

/** Say once per session why nothing here can work, instead of failing silently. */
function warnUnsupportedPlatform() {
  output.appendLine(
    `unsupported platform "${process.platform}" (${process.arch}); ${WINDOWS_ONLY_HELP}`
  );
  if (platformReported) return;
  platformReported = true;
  vscode.window.showErrorMessage(`AVD Mirror: ${WINDOWS_ONLY_HELP}`);
}

function psExe() {
  // Windows PowerShell ships with Windows. The pwsh branch is only a developer
  // fallback: activation is gated by unsupportedPlatform(), so it is unreachable.
  return process.platform === 'win32' ? 'powershell.exe' : 'pwsh';
}

/**
 * Log a child's output, and turn a spawn failure into one readable message.
 *
 * A missing executable arrives as an 'error' event, not an exit code: without a
 * listener here it is thrown out of the extension host and takes the whole
 * extension down. It used to reach the user as nothing but a dead panel.
 */
function wireProc(proc, label) {
  proc.stdout.on('data', d => output.append(d.toString().trimEnd()));
  proc.stderr.on('data', d => output.append(d.toString().trimEnd()));
  proc.on('error', e => {
    const why = e && e.code === 'ENOENT'
      ? `${psExe()} not found on PATH - AVD Mirror drives the Windows PowerShell that ships with Windows`
      : (e && e.message ? e.message : String(e));
    output.appendLine(`${label} failed to start: ${why}`);
    vscode.window.showErrorMessage(`AVD Mirror: ${label} could not start - ${why}.`);
  });
  return proc;
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
  if (unsupportedPlatform()) return false;
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
    const proc = avdProc;
    wireProc(proc, 'AVD manager');
    proc.on('exit', code => {
      output.appendLine(`AVD manager exited (${code})`);
      if (avdProc === proc) avdProc = null;
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

/**
 * Why the last inventory read failed, so an empty tree can say so.
 *
 * This used to return null on any problem, and the tree rendered as a plain
 * empty list: a manager that was up but answering nothing looked identical to a
 * machine with no AVDs at all.
 */
let avdStateError = '';

/** Read the AVD inventory from the manager. */
async function avdState() {
  try {
    const res = await fetch(`${AVD_URL}/avds`, { cache: 'no-store' });
    if (!res.ok) { avdStateError = `manager replied HTTP ${res.status}`; return null; }
    const st = await res.json();
    avdStateError = '';
    return st;
  } catch (e) {
    avdStateError = e && e.message ? e.message : String(e);
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

// --- .NET runtime guard ------------------------------------------------------
// src/wgccap is built framework-dependent for net8.0-windows, so the .NET 8
// runtime has to exist on the machine. Without it the apphost exits immediately,
// the page silently drops to the PrintWindow fallback - slower, and prone to the
// colour-channel tint described in SKILL.md - and nothing anywhere said why.
const DOTNET_DOWNLOAD = 'https://dotnet.microsoft.com/download/dotnet/8.0';
const DOTNET_WINGET = 'winget install Microsoft.DotNet.Runtime.8';

// null until probed, then 'ok' | 'missing' | 'unknown'.
let dotnetState = null;
let dotnetReported = false;

/** Run a command and resolve its combined output, or null if it would not run. */
function runCapture(exe, args, timeoutMs) {
  return new Promise(resolve => {
    let settled = false;
    const done = value => { if (!settled) { settled = true; resolve(value); } };
    let proc;
    try {
      proc = spawn(exe, args, { windowsHide: true });
    } catch {
      done(null);
      return;
    }
    let text = '';
    proc.stdout.on('data', d => { text += d.toString(); });
    proc.stderr.on('data', d => { text += d.toString(); });
    proc.on('error', () => done(null));
    proc.on('exit', code => done(code === 0 ? text : null));
    setTimeout(() => {
      try { proc.kill(); } catch { /* already gone */ }
      done(text || null);
    }, timeoutMs);
  });
}

/** Is a .NET 8 runtime installed? Cached - the answer cannot change mid-session. */
async function dotnetRuntime() {
  if (dotnetState) return dotnetState;
  // `dotnet` is not always on PATH: the user-local install that winget and the
  // VS Code build task use lives under %LOCALAPPDATA%\Microsoft\dotnet.
  const candidates = ['dotnet'];
  if (process.env.ProgramFiles) {
    candidates.push(path.join(process.env.ProgramFiles, 'dotnet', 'dotnet.exe'));
  }
  if (process.env.LOCALAPPDATA) {
    candidates.push(path.join(process.env.LOCALAPPDATA, 'Microsoft', 'dotnet', 'dotnet.exe'));
  }
  let listing = '';
  for (const exe of candidates) {
    const text = await runCapture(exe, ['--list-runtimes'], 8000);
    if (text) { listing = text; break; }
  }
  if (!listing) {
    // No answer is not evidence of absence: stay quiet rather than tell the user
    // to install something that may already be there.
    dotnetState = 'unknown';
    output.appendLine(
      'dotnet: could not run "dotnet --list-runtimes" - cannot tell whether the .NET 8 runtime is installed'
    );
    return dotnetState;
  }
  // 8.x specifically: the host does not roll forward across a major version.
  const ok = /Microsoft\.(NETCore|WindowsDesktop)\.App 8\./.test(listing);
  dotnetState = ok ? 'ok' : 'missing';
  output.appendLine(ok
    ? 'dotnet: .NET 8 runtime found'
    : `dotnet: no .NET 8 runtime (found: ${listing.replace(/\r?\n/g, ', ').trim() || 'nothing'})`);
  return dotnetState;
}

/** Warn once if the fast capturer cannot run, naming the fix, not the symptom. */
async function ensureDotnetRuntime() {
  if (await dotnetRuntime() !== 'missing' || dotnetReported) return;
  dotnetReported = true;
  const pick = await vscode.window.showWarningMessage(
    'AVD Mirror: the .NET 8 runtime is not installed, so the full-rate capturer ' +
    '(wgccap) cannot start. The mirror falls back to PrintWindow - slower, and it ' +
    'can tint colours.',
    'Get .NET 8', 'Copy install command'
  );
  if (pick === 'Get .NET 8') {
    await vscode.env.openExternal(vscode.Uri.parse(DOTNET_DOWNLOAD));
  } else if (pick === 'Copy install command') {
    await vscode.env.clipboard.writeText(DOTNET_WINGET);
    vscode.window.setStatusBarMessage(`AVD Mirror: copied "${DOTNET_WINGET}"`, 4000);
  }
}

async function startServer() {
  if (starting) return;
  if (unsupportedPlatform()) { warnUnsupportedPlatform(); return; }
  if (await isUp()) {
    output.appendLine('mirror server already listening');
    return;
  }

  starting = true;
  try {
    const script = findMirrorScript();
    if (!script) {
      vscode.window.showErrorMessage(
        'AVD Mirror: mirror.ps1 not found. Reinstall the extension, or open the avd-mirror project folder.'
      );
      output.appendLine('mirror.ps1 not found in any known location');
      return;
    }
    // The AVD manager comes up first: the mirror may need it to start the
    // selected AVD when nothing is running yet.
    await startAvdManager();
    // Fire and forget: the capturer check must not delay the server, and the
    // probe caches its answer so repeated starts cost nothing.
    ensureDotnetRuntime().catch(e =>
      output.appendLine(`dotnet check: ${e && e.message ? e.message : e}`)
    );
    output.appendLine(`starting: ${script} -Port ${PORT}`);
    // Hidden, like the documented manual launch, so the mirror never steals
    // focus or opens a console window over the editor.
    serverProc = spawn(
      psExe(),
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
       '-File', script, '-Port', String(PORT)],
      { detached: false, windowsHide: true }
    );
    const proc = serverProc;
    let exitCode = null;
    wireProc(proc, 'mirror server');
    proc.on('exit', code => {
      exitCode = code;
      output.appendLine(`mirror server exited (${code})`);
      if (code !== 0) {
        // -ExecutionPolicy Bypass in the command line covers every local scope,
        // but not a machine or user policy set by Group Policy - the usual reason
        // the same command works by hand and fails from here.
        output.appendLine(
          'if that repeats, check "Get-ExecutionPolicy -List": a MachinePolicy or ' +
          'UserPolicy scope cannot be overridden by -ExecutionPolicy Bypass'
        );
      }
      if (serverProc === proc) serverProc = null;
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
    const why = exitCode === null ? '' : ` (PowerShell exited with code ${exitCode})`;
    output.appendLine(`mirror server did not come up${why}; see output`);
    vscode.window.showWarningMessage(
      `AVD Mirror server did not start${why} - see the AVD Mirror output channel.`
    );
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
    html = html.replace(/(['"])\/(touch|input|gsize|window|frame\.jpg)\b/g, `$1${base}/$2`);
    return html;
}

// --- where the mirror is displayed ------------------------------------------
// Three surfaces can show the mirror: the VS Code panel, an editor tab, and the
// default browser. The AVDs view carries one checkbox per surface *under each
// AVD*, and the three global switches live in that view's title bar.
//
// A surface has at most one owner, because the mirror itself does: mirror.ps1
// binds to a single emulator window, so "ai_dating in a tab and pixel_test in
// the browser" is not a state this server can hold. Ticking a surface on another
// AVD therefore moves it rather than adding a second one - and if that AVD is
// not the one being mirrored, the request is refused with the reason instead of
// leaving a tick over an empty promise.
//
// Ownership is derived, never remembered: a surface belongs to whichever AVD the
// mirror is showing while it is open, so a tab closed by hand, or a different
// emulator started, corrects itself on the next render. The browser is the one
// exception - vscode.env.openExternal is one-way, so clearing its box only stops
// us counting that tab as shown.
const DISPLAY_TARGETS = {
  panel: {
    label: 'Panel',
    onIcon: 'layout-panel',
    offIcon: 'layout-panel-off',
    detail: 'The Screen tab in the VS Code panel.',
  },
  editor: {
    label: 'Editor Tab',
    onIcon: 'screen-full',
    offIcon: 'screen-normal',
    detail: 'The mirror as a full-height editor tab, next to your code.',
  },
  browser: {
    label: 'Browser',
    onIcon: 'globe',
    offIcon: 'circle-slash',
    detail: `The page at ${MIRROR_URL} in your default browser. VS Code cannot close that tab again.`,
  },
};
const DISPLAY_KEYS = Object.keys(DISPLAY_TARGETS);

/** The AVD the mirror is showing, or the one it would start if asked. */
function mirrorAvd() {
  const st = (avdTreeRef && avdTreeRef.state) || {};
  return st.running || st.selected || null;
}

/** Which AVD each surface is showing; null when it is closed. */
const displayOwner = { panel: null, editor: null, browser: null };
const displayContext = { panel: null, editor: null, browser: null };

/** A checkbox row: one surface of one AVD. */
class DisplayItem {
  constructor(avd, target) { this.avd = avd; this.target = target; }
}

function displayShown(target) {
  if (target === 'panel') return !!(viewProvider && viewProvider.visible);
  if (target === 'editor') return !!editorPanel;
  return browserOpened;
}

/**
 * Re-read the live surfaces before the tree renders.
 *
 * Called from getChildren, which the tree already runs on every poll and on
 * every refresh, so nothing extra ticks: the checkboxes and the title-bar icons
 * both follow whatever is true right now.
 */
function syncDisplay() {
  const cur = mirrorAvd();
  for (const target of DISPLAY_KEYS) {
    const shown = displayShown(target);
    displayOwner[target] = shown ? cur : null;
    // Each title-bar switch is two menu entries with different icons, gated on
    // this key: a filled glyph when the surface is on, its "off" counterpart
    // when it is not.
    if (displayContext[target] !== shown) {
      displayContext[target] = shown;
      vscode.commands.executeCommand('setContext', `avdMirror.shown.${target}`, shown);
    }
  }
}

/** Create or reveal the mirror as an editor tab. */
function showInEditor() {
  if (!viewProvider) return;
  if (editorPanel) { editorPanel.reveal(vscode.ViewColumn.Active); return; }
  const panel = vscode.window.createWebviewPanel(
    'avdMirror.editor', 'AVD Mirror',
    vscode.ViewColumn.Active, { enableScripts: true, retainContextWhenHidden: true }
  );
  editorPanel = panel;
  panel.webview.html = viewProvider._html(null);
  viewProvider._editor = panel;
  panel.onDidDispose(() => {
    if (editorPanel === panel) editorPanel = undefined;
    if (viewProvider) viewProvider._editor = undefined;
    // Keep the checkbox honest when the tab is closed from its own tab strip.
    if (avdTreeRef) avdTreeRef.refresh();
  });
  startServer()
    .then(() => viewProvider && viewProvider.paint(panel))
    .catch(e => output.appendLine(`editor paint: ${e && e.message ? e.message : e}`));
}

/** Turn one display surface on or off. */
async function setDisplay(target, on) {
  try {
    if (target === 'panel') {
      if (on) {
        // Reveal first, then start: the view paints its own loading hint, and a
        // cold start should not delay the panel appearing.
        await vscode.commands.executeCommand('avdMirror.view.focus');
        await startServer();
      } else {
        // There is no API to hide a single view, only the whole panel - and the
        // AVDs view lives in that panel, so these very checkboxes disappear with
        // it. Say where to find them again instead of leaving the user stuck.
        await vscode.commands.executeCommand('workbench.action.closePanel');
        vscode.window.showInformationMessage(
          'AVD Mirror: panel hidden. The AVDs view - and the switches that bring '
          + 'it back - live in that panel; use "AVD Mirror: Show Mirror in Panel" '
          + 'from the Command Palette, or the status bar entry.');
      }
    } else if (target === 'editor') {
      // No await before opening the tab: the panel shows its "loading" hint at
      // once and paints itself when the server answers, so a cold start does not
      // look like a click that did nothing.
      if (on) showInEditor();
      else if (editorPanel) {
        // Clear the reference before disposing: the checkbox is rendered from
        // it, and onDidDispose is the only other place that clears it.
        const tab = editorPanel;
        editorPanel = undefined;
        if (viewProvider) viewProvider._editor = undefined;
        tab.dispose();
      }
    } else if (target === 'browser') {
      if (on) {
        // The page is served on loopback, so bring the server up first: handing
        // the browser a URL that nothing is listening on shows a dead tab.
        await startServer();
        await vscode.env.openExternal(vscode.Uri.parse(MIRROR_URL));
        browserOpened = true;
      } else {
        browserOpened = false;
      }
    }
  } catch (e) {
    const why = e && e.message ? e.message : String(e);
    output.appendLine(`display ${target}: ${why}`);
    vscode.window.showErrorMessage(`AVD Mirror: could not switch the ${target} display - ${why}`);
  }
  if (avdTreeRef) avdTreeRef.refresh();
}

/**
 * One AVD's checkbox.
 *
 * A tick means "this AVD's mirror is on that surface", so it can only be granted
 * to the AVD the mirror is actually showing. Anything else is refused with the
 * reason: quietly ticking a surface that will never appear is worse than saying
 * no.
 */
async function setAvdDisplay(avd, target, on) {
  if (on && avd !== mirrorAvd()) {
    const cur = mirrorAvd();
    vscode.window.showWarningMessage(
      cur
        ? `AVD Mirror mirrors one emulator at a time: ${cur} is on screen. Stop it `
          + `(or start ${avd}) before showing ${avd} in the ${DISPLAY_TARGETS[target].label}.`
        : `${avd} is not running. Start it first, then tick where its mirror should appear.`
    );
    if (avdTreeRef) avdTreeRef.refresh();
    return;
  }
  await setDisplay(target, on);
}

/** The three switches as one multi-select list, for the Command Palette. */
async function chooseDisplay() {
  const picks = DISPLAY_KEYS.map(key => ({
    key,
    label: DISPLAY_TARGETS[key].label,
    description: displayShown(key) ? 'shown' : 'hidden',
    detail: DISPLAY_TARGETS[key].detail,
    picked: displayShown(key),
  }));
  const chosen = await vscode.window.showQuickPick(picks, {
    canPickMany: true,
    title: 'AVD Mirror: show the mirror in',
    placeHolder: 'Tick every place the mirror should appear',
  });
  if (!chosen) return;
  // Apply the difference only: re-opening what is already open would steal focus
  // and re-fetch the page for nothing.
  for (const pick of picks) {
    const want = chosen.some(c => c.key === pick.key);
    if (want !== pick.picked) await setDisplay(pick.key, want);
  }
}

/** Webview view provider for the activity-bar panel. */
class MirrorViewProvider {
  constructor() {
    this._view = undefined;
    this._editor = undefined;
    this._page = null;
  }

  /** Is the Screen view actually on screen? The Panel checkbox reads this. */
  get visible() {
    return !!(this._view && this._view.visible);
  }

  /** Set HTML on a webview once the page is available, else show the hint. */
  async paint(target) {
    // Nothing to fetch on a platform that cannot serve it: show the reason rather
    // than leaving "Loading the mirror from port 8777..." up forever.
    if (unsupportedPlatform()) {
      warnUnsupportedPlatform();
      target.webview.html = MirrorViewProvider.platformHtml();
      return;
    }
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
        webviewView.onDidChangeVisibility(() => {
          if (webviewView.visible) paint();
          // The Panel checkbox in the AVDs view mirrors this, so it has to be
          // repainted when the panel is opened or closed by any other route -
          // the status bar entry, Ctrl+J, or closing the panel by hand.
          if (avdTreeRef) avdTreeRef.refresh();
        });
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

  /** Panel body for a machine that cannot run any of this. Static: no page needed. */
  static platformHtml() {
    return `<!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <style>
      body{margin:0;padding:1.2rem;font:13px/1.5 var(--vscode-font-family);
           color:var(--vscode-foreground);background:var(--vscode-editor-background)}
      h1{font-size:1em;margin:0 0 .6em;font-weight:600}
      p{margin:0 0 .8em;color:var(--vscode-descriptionForeground)}
      code{font-family:var(--vscode-editor-font-family)}
    </style>
    </head>
    <body>
      <h1>AVD Mirror needs Windows</h1>
      <p>${WINDOWS_ONLY_HELP}</p>
      <p>This machine reports <code>${process.platform} ${process.arch}</code>.</p>
    </body>
    </html>`;
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
    <html lang="en" class="embed">
    <head>
    <meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="${csp}">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <style>
      /* Transparent, not black: the webview host paints the panel's own
         background behind this document, so the loading hint and the inlined
         page's transparent surround blend into VS Code instead of sitting in a
         black box. VS Code ships body{background-color:transparent} in a
         @layer, and this document's <style> is unlayered, so the declaration
         has to be repeated here to take effect. */
      html,body{margin:0;height:100%;background:transparent;overflow:hidden}
      /* --page is the surface the inlined page's transparent letterbox shows
         through to. The page declares its own --page on :root, and its styles
         are inlined *after* this <head>, so equal specificity would give the
         page the win - :root.embed (0,2,0) is the only way to override it. */
      :root.embed{--page:transparent}
      /* The hint is the only thing on screen while the page is being fetched,
         so it sits on the panel background rather than on black - which means
         its colours have to come from the theme to stay legible in a light
         one. */
      #hint{position:absolute;inset:0;display:flex;flex-direction:column;gap:.6em;align-items:center;
            justify-content:center;color:var(--vscode-descriptionForeground,#8b949e);
            font:12px var(--vscode-font-family);text-align:center;
            padding:1rem;background:transparent;z-index:9}
      #hint a{color:var(--vscode-textLink-foreground,#4daafc);cursor:pointer}
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
// A row that reports why the tree is empty, instead of an empty tree.
class ErrorItem {
  constructor(message, tooltip) { this.message = message; this.tooltip = tooltip; }
}

// One row per AVD, showing which one is running and which is selected. The
// list is re-read from the manager rather than cached, so an AVD created or
// deleted elsewhere appears without a reload.
class AvdTreeProvider {
  constructor() {
    this._onDidChangeTreeData = new vscode.EventEmitter();
    this.onDidChangeTreeData = this._onDidChangeTreeData.event;
    this._state = null;
    this._error = '';
    this._errorTooltip = '';
    this._timer = null;
  }

  refresh() {
    this._onDidChangeTreeData.fire();
  }

  /** Last state read from the manager; mirrorAvd() reads this. */
  get state() {
    return this._state;
  }

  async poll() {
    // On a platform that cannot run the manager there is nothing to poll: say why
    // once, instead of retrying a server that will never answer.
    if (unsupportedPlatform()) {
      const error = 'AVD Mirror only runs on Windows';
      if (this._error !== error) {
        this._error = error;
        this._errorTooltip = WINDOWS_ONLY_HELP;
        output.appendLine(`AVD list unavailable: ${WINDOWS_ONLY_HELP}`);
        this.refresh();
      }
      return;
    }
    await startAvdManager();
    const st = await avdState();
    if (st) {
      this._state = st;
      this._error = '';
      this._errorTooltip = '';
      this.refresh();
      return;
    }
    // Log each distinct failure once, not every 3 s.
    const error = avdStateError || 'no response';
    if (this._error !== error) {
      this._error = error;
      output.appendLine(`AVD list unavailable: ${error}`);
      this.refresh();
    }
  }

  start() {
    if (this._timer) return;
    this.poll();
    // No timer where the manager can never start: the message is already final.
    if (unsupportedPlatform()) return;
    this._timer = setInterval(() => this.poll().catch(() => {}), 3000);
  }

  stop() {
    if (this._timer) { clearInterval(this._timer); this._timer = null; }
  }

  getTreeItem(el) {
    if (el instanceof DisplayItem) {
      const meta = DISPLAY_TARGETS[el.target];
      // A tick means "this AVD is on that surface", not "this AVD would like to
      // be": the two are the same thing until a second emulator is started, and
      // only one of them can be true at a time.
      const shown = displayShown(el.target) && displayOwner[el.target] === el.avd;
      const item = new vscode.TreeItem(meta.label, vscode.TreeItemCollapsibleState.None);
      item.checkboxState = shown
        ? vscode.TreeItemCheckboxState.Checked
        : vscode.TreeItemCheckboxState.Unchecked;
      item.iconPath = new vscode.ThemeIcon(shown ? meta.onIcon : meta.offIcon);
      item.description = shown ? 'shown' : 'hidden';
      item.tooltip = `${meta.detail}\n\nTick to show ${el.avd}'s mirror here.`;
      item.contextValue = 'displayTarget';
      // Deliberately no `command`: with a checkbox on the row, a command would
      // toggle a second time for a single click and appear to do nothing.
      return item;
    }
    if (el instanceof ErrorItem) {
      const bad = new vscode.TreeItem(el.message, vscode.TreeItemCollapsibleState.None);
      bad.iconPath = new vscode.ThemeIcon('warning', new vscode.ThemeColor('problemsWarningIcon.foreground'));
      bad.tooltip = el.tooltip || 'The AVD manager is not answering. See the AVD Mirror output channel.';
      bad.contextValue = 'avdError';
      return bad;
    }
    const st = this._state || {};
    const running = st.running === el.name;
    const selected = st.selected === el.name;
    const mirrored = mirrorAvd() === el.name;
    // Every AVD expands into its own three switches, so the mirror's placement
    // is chosen per AVD rather than once for the whole view.
    const item = new vscode.TreeItem(el.name, vscode.TreeItemCollapsibleState.Collapsed);
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
    item.tooltip = `${el.name}${el.api ? ' - ' + el.api : ''}${el.device ? ' - ' + el.device : ''}`
      + (mirrored ? '\n\nThis is the AVD the mirror is showing.' : '\n\nThe mirror cannot show this AVD until it is the one running.');
    item.contextValue = running ? 'avdRunning' : 'avdIdle';
    item.command = {
      command: 'avdMirror.selectAvd',
      title: 'Select AVD',
      arguments: [el.name],
    };
    return item;
  }

  async getChildren(el) {
    // Rendering the tree is also the signal that it is on screen.
    this.start();
    if (!this._state) await this.poll();
    // The checkboxes are about to be built from these, so re-read the surfaces
    // first: a tab opened or closed since the last render has to be reflected.
    syncDisplay();
    if (el instanceof DisplayItem) return [];
    if (el && el.name) return DISPLAY_KEYS.map(target => new DisplayItem(el.name, target));
    const st = this._state || {};
    const avds = (st.avds || []).map(a => ({ name: a.name, api: a.api, device: a.device }));
    // An empty list has to say why it is empty: "no AVDs" and "manager not
    // answering" looked the same, and the second one is a bug to report.
    if (!avds.length) return [new ErrorItem(this._error || 'No AVDs found', this._errorTooltip)];
    return avds;
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

/**
 * Park the emulator window off-screen, or bring it back.
 *
 * Hiding for real would stop the mirror: the capture reads the window's DWM
 * surface, so a hidden (SW_HIDE) or minimized window produces no frames at all.
 * The server parks it just outside the virtual screen instead - out of sight,
 * and still captured at full rate.
 */
async function toggleHide() {
  let body;
  try {
    const res = await fetch(`http://${HOST}:${PORT}/window?hidden=toggle`, { cache: 'no-store' });
    body = await res.json();
  } catch (e) {
    vscode.window.showErrorMessage(
      `AVD Mirror: mirror server unreachable (${e && e.message ? e.message : e})`
    );
    return;
  }
  if (!body.ok) {
    if (body.state === 'no-emulator') {
      vscode.window.setStatusBarMessage('AVD Mirror: no emulator window to move', 3000);
    } else {
      vscode.window.showWarningMessage(`AVD Mirror: cannot move the emulator window (${body.state})`);
    }
    return;
  }
  vscode.window.setStatusBarMessage(
    body.hidden
      ? 'AVD Mirror: emulator window hidden - still mirroring'
      : 'AVD Mirror: emulator window restored',
    4000
  );
}

function activate(context) {
  // Activation is also onStartupFinished, so that the status bar entry point
  // exists before the panel has ever been opened - it replaces the Activity Bar
  // icon a Panel container does not get. Nothing that spawns a process may run
  // here: the servers start when a view is actually shown, and the platform and
  // .NET warnings fire from paint()/startServer() when the user asks for them,
  // not on every window that happens to open.
  const provider = new MirrorViewProvider();
  viewProvider = provider;
  const avdTree = new AvdTreeProvider();
  avdTreeRef = avdTree;
  context.subscriptions.push({ dispose: () => avdTree.stop() });

  // The status bar entry point. A Panel container gets no Activity Bar icon, so
  // without this the only way back to the mirror once the panel is closed is the
  // Command Palette, which is not somewhere a running tool should live.
  const status = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 100);
  status.text = '$(device-mobile) AVD Mirror';
  status.tooltip = 'Open the AVD Mirror panel';
  status.command = 'avdMirror.open';
  status.show();

  // The AVD list has to be live while it is on screen - an emulator started or
  // stopped from the mirror page's own toolbar must show up here without a
  // reload - but activation happens at startup now, so polling follows the
  // tree's visibility instead of starting with the extension: it is what spawns
  // the manager on 8779. getChildren() starts it too, because the initial
  // visibility of an already-open tab does not fire a change event.
  const treeView = vscode.window.createTreeView('avdMirror.avds', { treeDataProvider: avdTree });
  context.subscriptions.push(
    treeView,
    treeView.onDidChangeVisibility(e => { if (e.visible) avdTree.start(); else avdTree.stop(); }),
    // The per-AVD checkboxes. The state is applied and then the tree is
    // repainted from the live surfaces, so a surface that refuses to change
    // reports that instead of leaving a box ticked over nothing.
    treeView.onDidChangeCheckboxState(async e => {
      for (const [el, state] of e.items) {
        if (el instanceof DisplayItem) {
          await setAvdDisplay(el.avd, el.target, state === vscode.TreeItemCheckboxState.Checked);
        }
      }
    })
  );
    // A supervision failure must never escape into a view provider or panel:
    // that is what produces "An error occurred while loading view".
    // Must return the promise, for the same reason as in resolveWebviewView.
    const safeStart = () => startServer().catch(e => output.appendLine(`startServer: ${e}`));

    // A portrait phone screen is unreadable in a sidebar panel that is wide but
    // only ~130 px tall, so the same mirror can also be shown full-height in an
    // editor tab. That is one of the Display targets now; see setDisplay().
    context.subscriptions.push(
      status,
      vscode.window.registerWebviewViewProvider('avdMirror.view', provider),
      vscode.commands.registerCommand('avdMirror.selectAvd', (name) => selectAvd(name)),
      vscode.commands.registerCommand('avdMirror.startAvd', (name) => startAvd(name)),
      vscode.commands.registerCommand('avdMirror.stopAvd', () => stopAvd(false)),
      vscode.commands.registerCommand('avdMirror.forceStopAvd', () => stopAvd(true)),
      vscode.commands.registerCommand('avdMirror.refreshAvds', () => avdTree.poll()),
      vscode.commands.registerCommand('avdMirror.openInEditor', () => setDisplay('editor', true)),
      vscode.commands.registerCommand('avdMirror.toggleDisplay', chooseDisplay),
      // The three global switches in the AVDs title bar. Each surface is a pair
      // of commands - show and hide - because a menu entry's icon is fixed per
      // command, so the only way to paint on/off state is to swap the command
      // (and its glyph) on a context key that syncDisplay() maintains.
      vscode.commands.registerCommand('avdMirror.showInPanel', () => setDisplay('panel', true)),
      vscode.commands.registerCommand('avdMirror.hideFromPanel', () => setDisplay('panel', false)),
      vscode.commands.registerCommand('avdMirror.showInEditor', () => setDisplay('editor', true)),
      vscode.commands.registerCommand('avdMirror.hideFromEditor', () => setDisplay('editor', false)),
      vscode.commands.registerCommand('avdMirror.showInBrowser', () => setDisplay('browser', true)),
      vscode.commands.registerCommand('avdMirror.hideFromBrowser', () => setDisplay('browser', false)),
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
    vscode.commands.registerCommand('avdMirror.toggleHide', toggleHide),
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