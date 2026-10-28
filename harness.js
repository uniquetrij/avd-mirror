// Harness: exercise extension.js against a mock VS Code API so runtime errors
// in the AVD tree view / commands show up here instead of in the extension host.
const path = require('path');
const Module = require('module');

const calls = [];
const panels = [];
const mk = (name) => (...a) => { calls.push([name, ...a]); return undefined; };

// Whether the AVDs tree is on screen. The Panel switch is derived from this as
// well as from the Screen webview view, because both share the Panel container.
const viewState = { treeVisible: true };

class EventEmitter {
  constructor() { this.handlers = []; this.event = (h) => { this.handlers.push(h); return { dispose() {} }; }; }
  fire(x) { for (const h of this.handlers) h(x); }
}

const vscodeMock = {
  EventEmitter,
  ThemeIcon: class { constructor(id, color) { this.id = id; this.color = color; } },
  ThemeColor: class { constructor(id) { this.id = id; } },
  TreeItem: class {
    constructor(label, collapsibleState) {
      this.label = label; this.collapsibleState = collapsibleState;
    }
  },
  TreeItemCollapsibleState: { None: 0, Collapsed: 1, Expanded: 2 },
  TreeItemCheckboxState: { Unchecked: 0, Checked: 1 },
  ProgressLocation: { Notification: 15, Window: 10 },
  ViewColumn: { Active: -1 },
  StatusBarAlignment: { Left: 1, Right: 2 },
  window: {
    createOutputChannel: () => ({ appendLine: mk('appendLine'), append: mk('append'), dispose() {} }),
    createStatusBarItem: (align, prio) => {
      calls.push(['createStatusBarItem', align, prio]);
      return { text: '', tooltip: '', command: '', show() {}, hide() {}, dispose() {} };
    },
    registerWebviewViewProvider: () => ({ dispose() {} }),
    createTreeView: (id, opts) => {
      calls.push(['createTreeView', id, opts.treeDataProvider]);
      return {
        dispose() {},
        get visible() { return viewState.treeVisible; },
        onDidChangeVisibility: (fn) => { calls.push(['onDidChangeVisibility', fn]); return { dispose() {} }; },
        onDidChangeCheckboxState: (fn) => { calls.push(['onDidChangeCheckboxState', fn]); return { dispose() {} }; },
      };
    },
    createWebviewPanel: (viewType, title, column, options) => {
      const panel = {
        viewType, title, column, options,
        webview: {},
        disposed: false,
        onDidDispose(fn) { this._onDispose = fn; return { dispose() {} }; },
        reveal() { calls.push(['reveal', viewType]); },
        dispose() { this.disposed = true; if (this._onDispose) this._onDispose(); },
      };
      panels.push(panel);
      calls.push(['createWebviewPanel', viewType, title]);
      return panel;
    },
    showErrorMessage: mk('showErrorMessage'),
    showWarningMessage: mk('showWarningMessage'),
    showInformationMessage: mk('showInformationMessage'),
    setStatusBarMessage: mk('setStatusBarMessage'),
    withProgress: async (opts, fn) => { calls.push(['withProgress', opts.title]); return fn(); },
    showQuickPick: async (items, opts) => {
      calls.push(['showQuickPick', opts && opts.title]);
      // Default to the first (preferred) option, as a user accepting the default
      // would, so the code path under test is the ordinary one.
      return items[0];
    },
    registerTreeDataProvider: () => ({ dispose() {} }),
  },
  commands: {
    registerCommand: (id, fn) => { calls.push(['registerCommand', id, fn]); return { dispose() {} }; },
    executeCommand: (id, ...args) => {
      calls.push(['executeCommand', id, ...args]);
      return undefined;
    },
  },
  // The project folder is the workspace: the extension code sits at its root,
  // so the scripts are found at <workspace>/scripts and the mock exercises the
  // same lookup the real extension uses.
  workspace: { workspaceFolders: [{ uri: { scheme: 'file', fsPath: path.resolve(__dirname) } }] },
};

const origResolve = Module._resolveFilename;
Module._resolveFilename = function (request, ...rest) {
  if (request === 'vscode') return 'vscode';
  return origResolve.call(this, request, ...rest);
};
require.cache['vscode'] = { id: 'vscode', filename: 'vscode', loaded: true, exports: vscodeMock };

const ext = require('./extension.js');

(async () => {
  const ctx = { subscriptions: [] };
  ext.activate(ctx);
  console.log('activate() OK, subscriptions:', ctx.subscriptions.length);

  // The tree provider is created inside activate; find it via the created view.
  const treeReg = calls.find(c => c[0] === 'registerTreeView');
  console.log('commands registered:',
    calls.filter(c => c[0] === 'registerCommand').map(c => c[1]).join(', '));

  // Drive the AVD commands the way the tree view would.
  const run = (cmd) => {
    const c = calls.find(x => x[0] === 'registerCommand' && x[1] === cmd);
    return c ? c[2] : null;
  };
  console.log('has selectAvd:', !!run('avdMirror.selectAvd'));
  console.log('has startAvd:', !!run('avdMirror.startAvd'));
  console.log('has stopAvd:', !!run('avdMirror.stopAvd'));

  // Exercise EVERY registered command. The previous version only called
  // selectAvd, which is why a misplaced vscode.* call in the stop path
  // (vscode.withProgress instead of vscode.window.withProgress) went unnoticed
  // until it was clicked in VS Code. A command that is never invoked is not
  // tested, and the mock deliberately defines only vscode.window.withProgress,
  // so calling vscode.withProgress throws exactly as it did in the extension
  // host.
  const failures = [];
  const call = async (cmd, arg) => {
    const fn = run(cmd);
    if (!fn) { console.log(`  ${cmd}: NOT REGISTERED`); failures.push(`${cmd}: not registered`); return; }
    try {
      await fn(arg);
      console.log(`  ${cmd}: ok`);
    } catch (e) {
      const msg = e && e.message ? e.message : String(e);
      if (/is not a function/.test(msg)) {
        console.log(`  ${cmd}: *** MISSING VS CODE API *** ${msg}`);
        failures.push(`${cmd}: ${msg}`);
      } else {
        console.log(`  ${cmd}: threw ${msg}`);
      }
    }
  };

  console.log('exercising commands:');
  await call('avdMirror.selectAvd', 'ai_dating');
  await call('avdMirror.refreshAvds');
  // The stop path is the one that was broken, so it is called for real.
  await call('avdMirror.stopAvd');
  await call('avdMirror.startAvd', 'ai_dating');
  // toggleHide is intentionally NOT invoked here: it talks to a live mirror
  // server, and on a machine where one is running it would move the user's real
  // emulator window. Registration is the part the harness can check safely.
  console.log('has toggleHide:', !!run('avdMirror.toggleHide'));

  // Argument shapes. VS Code hands different things to the same command
  // depending on where it was invoked from, and passing that straight through
  // is how "start failed - unknown AVD '[object Object]'" happened:
  //   view title bar     -> the TreeView
  //   item context menu  -> the tree item
  //   command palette    -> nothing
  // Each must resolve to the right AVD (or fall back to the selected one)
  // rather than to a stringified object.
  console.log('argument shapes:');
  const treeItem = { name: 'ai_dating', api: 'API 34', device: 'pixel_4' };
  const treeView = { selection: [], onDidChangeSelection: () => ({ dispose() {} }) };
  const shapes = [
    ['tree item object', treeItem],
    ['TreeView object', treeView],
    ['plain string', 'ai_dating'],
    ['undefined', undefined],
  ];
  for (const [label, arg] of shapes) {
    const before = calls.filter(c => c[0] === 'showWarningMessage').length;
    try {
      await run('avdMirror.selectAvd')(arg);
      const warned = calls.filter(c => c[0] === 'showWarningMessage').length > before;
      console.log(`  selectAvd(${label}): ok${warned ? ' (warned - no name resolved)' : ''}`);
    } catch (e) {
      const msg = e && e.message ? e.message : String(e);
      console.log(`  selectAvd(${label}): *** ${msg}`);
      failures.push(`selectAvd(${label}): ${msg}`);
    }
  }
  // The start path must not ask for "[object Object]" either. The emulator is
  // already running, so this resolves to an already-running AVD rather than a
  // full boot, but the name is what is being checked.
  {
    const before = calls.filter(c => c[0] === 'showErrorMessage').length;
    try {
      await run('avdMirror.startAvd')(treeView);
      const errs = calls.filter(c => c[0] === 'showErrorMessage').slice(before);
      const bad = errs.find(e => /\[object Object\]/.test(String(e[1])));
      if (bad) {
        console.log('  startAvd(TreeView): *** asked for "[object Object]" ***');
        failures.push('startAvd(TreeView): resolved to [object Object]');
      } else {
        console.log('  startAvd(TreeView): ok (no [object Object])');
      }
    } catch (e) {
      const msg = e && e.message ? e.message : String(e);
      console.log(`  startAvd(TreeView): *** ${msg}`);
      failures.push(`startAvd(TreeView): ${msg}`);
    }
  }

  // Build a tree item through the provider to check the icon/description path.
  const prov = calls.find(c => c[0] === 'createTreeView');
  console.log('tree view created:', !!prov);
  if (prov) {
    const tree = prov[2];
    const kids = await tree.getChildren();
    console.log('tree children:', kids.map(k => k.name).join(', ') || '(none)');
    for (const k of kids) {
      const item = tree.getTreeItem(k);
      console.log(`  item "${item.label}" desc="${item.description}" icon=${item.iconPath.id} color=${item.iconPath.color ? item.iconPath.color.id : 'none'} ctx=${item.contextValue}`);
    }

    // The surface switches are inline actions on the AVD row itself, so a row
    // has nothing to expand, and only the mirrored AVD's row carries them - its
    // context value gets a `Mirrored` suffix, which is what the menus gate on.
    const avd = kids.find(k => k && k.name);
    if (avd) {
      const avdItem = tree.getTreeItem(avd);
      const rows = await tree.getChildren(avd);
      console.log(`  ${avd.name} ctx=${avdItem.contextValue} collapsible=${avdItem.collapsibleState} children=${rows.length}`);
      if (avdItem.collapsibleState !== 0) failures.push(`${avd.name}: row still expands (${avdItem.collapsibleState})`);
      if (!/Mirrored$/.test(avdItem.contextValue)) failures.push(`${avd.name}: mirrored row not marked (ctx=${avdItem.contextValue})`);
      if (rows.length) failures.push(`${avd.name}: expected no child rows, got ${rows.length}`);
      const other = kids.find(k => k && k.name !== avd.name);
      if (other && /Mirrored$/.test(tree.getTreeItem(other).contextValue)) {
        failures.push(`${other.name}: marked as mirrored too - two rows would offer the switches`);
      }

      // The menu is what the user clicks, so check the contributions: the glyphs
      // are what make a switch look on or off, and a pair with one half missing
      // is an icon that never changes.
      const pkg = require(path.join(__dirname, 'package.json'));
      const entries = (pkg.contributes.menus['view/item/context'] || []).filter(m => /^inline@[2-9]/.test(m.group || ''));
      const icon = {};
      for (const c of pkg.contributes.commands || []) if (c.icon) icon[c.command] = c.icon;
      const want = [
        ['panel', 'Panel', 2, 'layout-panel', 'layout-panel-off'],
        ['editor', 'Editor', 3, 'screen-full', 'screen-normal'],
        ['browser', 'Browser', 4, 'globe', 'circle-slash'],
        ['embedded', 'Embedded', 5, 'browser', 'preview'],
      ];
      for (const [key, cap, group, onIcon, offIcon] of want) {
        const showId = `avdMirror.showIn${cap}`;
        const hideId = `avdMirror.hideFrom${cap}`;
        const show = entries.find(m => m.command === showId);
        const hide = entries.find(m => m.command === hideId);
        if (!show || !hide) { failures.push(`${key}: no inline show/hide pair`); continue; }
        if (show.group !== `inline@${group}` || hide.group !== show.group) {
          failures.push(`${key}: pair split across groups ${show.group}/${hide.group}`);
        }
        const when = (show.when || '') + ' ' + (hide.when || '');
        if (!/viewItem == avdRunningMirrored/.test(when) || !/viewItem == avdIdleMirrored/.test(when)) {
          failures.push(`${key}: not limited to the mirrored row (${when})`);
        }
        if (!/!avdMirror\.shown\./.test(show.when || '')) failures.push(`${key}: show not gated on the surface being off (${show.when})`);
        if (!/(^|[^!])avdMirror\.shown\./.test(hide.when || '')) failures.push(`${key}: hide not gated on the surface being on (${hide.when})`);
        if (icon[showId] !== '$(' + onIcon + ')') failures.push(`${key}: show icon ${icon[showId]} is not $(${onIcon})`);
        if (icon[hideId] !== '$(' + offIcon + ')') failures.push(`${key}: hide icon ${icon[hideId]} is not $(${offIcon})`);
      }

      // The AVDs title bar is down to Refresh: nothing that means one AVD lives
      // in the header, because a title-bar entry gets no item and can only act
      // on "whatever the mirror happens to show".
      const title = pkg.contributes.menus['view/title'] || [];
      const stray = title.filter(m => /avdMirror\.(showIn|hideFrom|startAvd|stopAvd|forceStopAvd)/.test(m.command || ''));
      if (stray.length) failures.push(`title bar still carries per-command buttons: ${stray.map(m => m.command).join(', ')}`);
      if (!title.some(m => m.command === 'avdMirror.refreshAvds')) failures.push('title bar lost avdMirror.refreshAvds');

      // Power is a button on the row, in the first inline slot, gated so a start
      // only appears on a stopped AVD and a stop only on a running one. Force
      // stop stays in the row menu: it is the rare, destructive one, and giving
      // it an icon beside the everyday stop invites the wrong click.
      const itemMenu = pkg.contributes.menus['view/item/context'] || [];
      const power = [
        ['avdMirror.startAvd', /viewItem == avdIdle/, 'starts only an AVD that is not running'],
        ['avdMirror.stopAvd', /viewItem == avdRunning/, 'stops only the running AVD'],
      ];
      for (const [cmd, gate, why] of power) {
        const m = itemMenu.find(x => x.command === cmd);
        if (!m) { failures.push(`${cmd}: not offered on the row`); continue; }
        if (m.group !== 'inline@1') failures.push(`${cmd}: expected inline@1, got ${m.group}`);
        if (!gate.test(m.when || '')) failures.push(`${cmd}: ${why}, but the gate is "${m.when}"`);
      }
      const force = itemMenu.find(x => x.command === 'avdMirror.forceStopAvd');
      if (force && /inline/.test(force.group || '')) failures.push(`forceStopAvd: inline (${force.group}) - too easy to hit next to Stop`);

      // Regression: the panel switch reported "hidden" whenever the Screen view
      // was not the active tab - i.e. every time the user could actually see the
      // switch - so flipping it looked like nothing happened. Both views share
      // the Panel container, so either one being visible means the panel is open.
      const ctxValue = (target = 'panel') => {
        const last = calls.filter(c => c[0] === 'executeCommand' && c[1] === 'setContext' && c[2] === `avdMirror.shown.${target}`).pop();
        return last ? last[3] : undefined;
      };
      // The context keys are written from getChildren(), so ask the tree to
      // render before reading them back.
      const sync = () => tree.getChildren();
      await sync();
      if (ctxValue() !== true) failures.push(`panel: expected avdMirror.shown.panel=true, got ${ctxValue()}`);
      viewState.treeVisible = false;
      await sync();
      if (ctxValue() !== false) failures.push(`panel: expected avdMirror.shown.panel=false once no view is visible, got ${ctxValue()}`);
      viewState.treeVisible = true;
      await sync();
      if (ctxValue() !== true) failures.push(`panel: expected the switch to come back, got ${ctxValue()}`);

      // Hiding blanks the mirror in place: it must not close the part, which
      // would take the AVDs view - and these switches - with it. Invoked with the
      // TreeView, as the title bar does.
      await run('avdMirror.hideFromPanel')(treeView);
      await sync();
      const closed = calls.filter(c => c[0] === 'executeCommand' && String(c[1]).startsWith('workbench.action.close'));
      if (closed.length) failures.push(`hideFromPanel: closed a part (${closed.map(c => c[1]).join(',')})`);
      if (!viewState.treeVisible) failures.push('hideFromPanel: the AVDs view was hidden with it');
      if (ctxValue() !== false) failures.push(`hideFromPanel: context still true`);

      // The row form acts on the AVD it names. A surface switched on for an AVD
      // the mirror is not showing would never appear, so it is refused instead of
      // left looking set.
      const warnedBefore = calls.filter(c => c[0] === 'showWarningMessage').length;
      await run('avdMirror.showInEditor')({ name: 'ghost_avd' });
      if (calls.filter(c => c[0] === 'showWarningMessage').length === warnedBefore) {
        failures.push('showInEditor(other AVD): not refused');
      }
      if (panels.some(p => p.viewType === 'avdMirror.editor' && !p.disposed)) {
        failures.push('showInEditor(other AVD): opened the tab anyway');
      }

      // The embedded browser is the one browser surface VS Code owns, so unlike
      // the external Browser switch it can be closed again - and it must close
      // only its own tab.
      await run('avdMirror.showInEmbedded')(treeView);
      await sync();
      const emb = panels.filter(p => p.viewType === 'avdMirror.embedded').pop();
      if (!emb) failures.push('showInEmbedded: no embedded panel');
      else {
        const html = emb.webview.html || '';
        if (!/iframe[^>]+src="http:\/\/127\.0\.0\.1:8777\//.test(html)) failures.push('showInEmbedded: the page is not framed from the server');
        if (!/frame-src[^;"]*127\.0\.0\.1:8777/.test(html)) failures.push('showInEmbedded: frame-src would block the page');
      }
      if (ctxValue('embedded') !== true) failures.push(`showInEmbedded: context not set (${ctxValue('embedded')})`);
      await run('avdMirror.hideFromEmbedded')(treeView);
      await sync();
      if (emb && !emb.disposed) failures.push('hideFromEmbedded: panel left open');
      if (ctxValue('embedded') !== false) failures.push('hideFromEmbedded: context still true');
    } else {
      failures.push('tree: no AVD row');
    }

    const pairs = [
      ['showInPanel', 'hideFromPanel'], ['showInEditor', 'hideFromEditor'],
      ['showInBrowser', 'hideFromBrowser'], ['showInEmbedded', 'hideFromEmbedded'],
    ];
    for (const [on, off] of pairs) {
      if (!run('avdMirror.' + on)) failures.push(`avdMirror.${on}: not registered`);
      if (!run('avdMirror.' + off)) failures.push(`avdMirror.${off}: not registered`);
    }
  }

  // And confirm the manager answers, which is what the tree reads. Its port is a
  // preference: 8779 when it is usable, otherwise the next free candidate, so a
  // port left behind by a dead process cannot masquerade as "no AVDs".
  const managerPorts = [8779, 8781, 8782, 8783];
  let managerPort = null;
  let health = '';
  for (const port of managerPorts) {
    health = await fetch(`http://127.0.0.1:${port}/health`).then(r => r.text())
      .catch(e => 'ERR ' + e.message);
    if (health === 'ok') { managerPort = port; break; }
  }
  console.log('manager health:', managerPort ? `ok on ${managerPort}` : health);
  if (!managerPort) failures.push('AVD manager: no candidate port answered');
  console.log('failures:', failures.length ? failures.join(' | ') : 'none');
  if (failures.length) { console.log('HARNESS FAILED'); process.exit(1); }
  ext.deactivate();
  console.log('deactivate() OK');
  // The tree polls on a timer; exit explicitly rather than waiting it out.
  process.exit(0);
})().catch(e => { console.error('FAILED:', e && e.stack ? e.stack : e); process.exit(1); });
