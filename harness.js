// Harness: exercise extension.js against a mock VS Code API so runtime errors
// in the AVD tree view / commands show up here instead of in the extension host.
const path = require('path');
const Module = require('module');
const fs = require('fs');
const crypto = require('crypto');

const calls = [];
const panels = [];
const mk = (name) => (...a) => { calls.push([name, ...a]); return undefined; };

// Whether the AVDs tree is on screen. The Panel switch is derived from this as
// well as from the Screen webview view, because both share the Panel container.
const viewState = { treeVisible: true };

// Scripted answers for the surface picker, one per invocation, so a test can tick
// exactly the surfaces it wants instead of accepting whatever comes first.
const quickPickAnswers = [];

// The FLAG_SECURE policy is a setting, so the mock has to hold one. update() only
// records the write: firing onDidChangeConfiguration from here would make the
// harness push the policy to whatever mirror server happens to be running, and
// flip the user's real switch.
const configStore = { 'avdMirror.honourFlagSecure': false };
const configUpdates = [];

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
  ConfigurationTarget: { Global: 1, Workspace: 2, WorkspaceFolder: 3 },
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
      calls.push(['showQuickPick', opts && opts.title, items]);
      // A scripted answer, for the multi-select picker: it receives the real
      // items and returns the ones a user would have ticked.
      if (quickPickAnswers.length) return quickPickAnswers.shift()(items);
      // Otherwise default to the first (preferred) option, as a user accepting
      // the default would, so the code path under test is the ordinary one.
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
  workspace: {
    workspaceFolders: [{ uri: { scheme: 'file', fsPath: path.resolve(__dirname) } }],
    getConfiguration: (section) => {
      const id = (key) => (section ? `${section}.${key}` : key);
      return {
        get: (key, dflt) => (id(key) in configStore ? configStore[id(key)] : dflt),
        update: async (key, value, target) => {
          configUpdates.push([id(key), value, target]);
          calls.push(['configUpdate', id(key), value, target]);
          configStore[id(key)] = value;
        },
      };
    },
    onDidChangeConfiguration: (fn) => {
      calls.push(['onDidChangeConfiguration', fn]);
      return { dispose() {} };
    },
  },
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
  console.log('has hideEmulatorWindow:', !!run('avdMirror.hideEmulatorWindow'));
  console.log('has showEmulatorWindow:', !!run('avdMirror.showEmulatorWindow'));

  // The emulator switch is the only command that moves a real window, so it runs
  // only in the direction that is already true: asking the server to "show" a
  // window it reports as shown is a no-op on screen, and still proves the round
  // trip, the answer being read back and the message path.
  const win = await fetch('http://127.0.0.1:8777/window?state=1', { cache: 'no-store' })
    .then(r => r.json()).catch(() => null);
  if (win && win.state === 'shown') {
    const errsBefore = calls.filter(c => c[0] === 'showErrorMessage').length;
    await call('avdMirror.showEmulatorWindow');
    if (calls.filter(c => c[0] === 'showErrorMessage').length > errsBefore) {
      failures.push('showEmulatorWindow: errored against a live server');
    }
    const msg = calls.filter(c => c[0] === 'setStatusBarMessage').pop();
    if (!msg || !/restored/.test(String(msg[1]))) {
      failures.push(`showEmulatorWindow: no "restored" message (${msg && msg[1]})`);
    }
  } else {
    console.log('showEmulatorWindow: skipped - server reports', win ? win.state : 'no answer');
  }

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

    // The surface switches are menu entries on the AVD row itself, so a row has
    // nothing to expand, and only the mirrored AVD's row offers them - its context
    // value gets a `Mirrored` suffix, which is what the menus gate on.
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

      // The menu is what the user clicks, so check the contributions. A context
      // menu row is a check span plus a plain text label: it can draw neither a
      // contributed icon nor a tick, which is why the four surfaces are one entry
      // that opens a picker instead of eight show/hide pairs whose icons and
      // state characters would never reach the screen.
      const pkg = require(path.join(__dirname, 'package.json'));
      const itemMenuAll = pkg.contributes.menus['view/item/context'] || [];
      const commands = pkg.contributes.commands || [];
      const picker = itemMenuAll.find(m => m.command === 'avdMirror.toggleDisplay');
      if (!picker) failures.push('the row menu lost the surface picker');
      else {
        if (picker.group !== '2_display@1') failures.push(`picker: expected group 2_display@1, got ${picker.group}`);
        const when = picker.when || '';
        if (!/viewItem == avdRunningMirrored/.test(when) || !/viewItem == avdIdleMirrored/.test(when)) {
          failures.push(`picker: not limited to the mirrored row (${when})`);
        }
      }
      // No per-surface entry is left, and no label carries a stand-in character:
      // a glyph in a label is a picture of an icon that VS Code would draw
      // properly anywhere else.
      const strays = itemMenuAll.filter(m => /^2_display@/.test(m.group || '')
        && m.command !== 'avdMirror.toggleDisplay');
      if (strays.length) failures.push(`per-surface entries back in the row menu: ${strays.map(m => m.command).join(', ')}`);
      for (const c of commands) {
        if (/[^\x20-\x7e]/.test(c.title || '')) failures.push(`${c.command}: label carries a glyph ("${c.title}")`);
      }
      // Two commands per surface existed only because a menu entry's icon could
      // not change with its state. The picker ticks instead, so they are gone.
      const pairs = commands.filter(c => /avdMirror\.(showIn|hideFrom)/.test(c.command));
      if (pairs.length) failures.push(`state-pair commands still contributed: ${pairs.map(c => c.command).join(', ')}`);

      // The AVDs title bar carries Refresh and nothing else: a title-bar button
      // gets no item, so it can only act on "whatever the mirror happens to
      // show". The window switch deliberately does not live there - the row it
      // applies to is two pixels away, and a header duplicate means one state
      // with two controls and no way to tell which one is current.
      const title = pkg.contributes.menus['view/title'] || [];
      const stray = title.filter(m => /avdMirror\.(startAvd|stopAvd|forceStopAvd|hideEmulatorWindow|showEmulatorWindow)/.test(m.command || ''));
      if (stray.length) failures.push(`title bar carries per-item buttons: ${stray.map(m => m.command).join(', ')}`);
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
      const inlineStrip = itemMenu.filter(m => /^inline@/.test(m.group || ''));
      if (inlineStrip.length !== 4 || inlineStrip.some(m => !/^avdMirror\.(start|stop)Avd$/.test(m.command)
        && !/^avdMirror\.(hide|show)EmulatorWindow$/.test(m.command))) {
        failures.push(`inline strip should hold only power and the window switch, has ${inlineStrip.map(m => m.command).join(', ')}`);
      }

      // The emulator's own window is an icon on the row - a context-menu row can
      // draw no codicon, which is the whole reason it moved there. The pair lists
      // only the direction that applies, so it must be gated on its own state key,
      // and only a running AVD has a window to move.
      const emu = [
        ['avdMirror.hideEmulatorWindow', /!avdMirror\.emulatorHidden/, '$(empty-window)', 'not-yet-hidden'],
        ['avdMirror.showEmulatorWindow', /(^|[^!])avdMirror\.emulatorHidden/, '$(window)', 'hidden'],
      ];
      for (const [cmd, gate, glyph, side] of emu) {
        const m = itemMenu.find(x => x.command === cmd);
        if (!m) { failures.push(`${cmd}: not offered on the row`); continue; }
        if (m.group !== 'inline@2') failures.push(`${cmd}: expected group inline@2, got ${m.group}`);
        if (!/viewItem == avdRunning/.test(m.when || '')) failures.push(`${cmd}: offered on an AVD with no window (${m.when})`);
        if (!gate.test(m.when || '')) failures.push(`${cmd}: not gated on the ${side} state (${m.when})`);
        const declared = (pkg.contributes.commands || []).find(c => c.command === cmd);
        if (!declared || declared.icon !== glyph) failures.push(`${cmd}: icon ${declared && declared.icon} is not ${glyph}`);
        const palette = (pkg.contributes.menus.commandPalette || []).find(x => x.command === cmd);
        if (!palette || palette.when !== 'false') failures.push(`${cmd}: listed in the palette - the state-aware pair belongs on a row, the palette keeps the toggle`);
      }
      if (!itemMenu.some(m => m.command === 'avdMirror.hideEmulatorWindow')) failures.push('the row lost the emulator window switch');

      // The icon pair is only as good as the key behind it: `avdMirror.emulatorHidden`
      // has to be set from the server's own answer, and only a boolean closes the
      // gate VS Code evaluates in `when`.
      const hiddenCtx = calls.filter(c => c[0] === 'executeCommand'
        && c[1] === 'setContext' && c[2] === 'avdMirror.emulatorHidden').pop();
      if (win && !hiddenCtx) {
        failures.push('avdMirror.emulatorHidden is never set - the Show icon would never appear');
      } else if (hiddenCtx && typeof hiddenCtx[3] !== 'boolean') {
        failures.push(`avdMirror.emulatorHidden is not a boolean (${JSON.stringify(hiddenCtx[3])})`);
      }

      // The picker is the only way in, so drive it the way a user does: it is
      // handed the real items and answers with the ones ticked. Its codicons and
      // ticks are checked on the way past, since a context-menu row can carry
      // neither.
      const row = { name: avd.name };
      const pick = async (arg, ...keys) => {
        quickPickAnswers.push(items => items.filter(i => keys.includes(i.key)));
        const seen = calls.filter(c => c[0] === 'showQuickPick').length;
        await run('avdMirror.toggleDisplay')(arg);
        const made = calls.filter(c => c[0] === 'showQuickPick')[seen];
        return made ? { title: made[1], items: made[2] } : { title: '', items: [] };
      };
      const sync = () => tree.getChildren();
      const errsBefore = calls.filter(c => c[0] === 'showErrorMessage').length;
      await sync();

      // Every surface is listed, with the icon a menu row cannot draw and a tick
      // that reports what is on screen right now.
      const opened = await pick(row, 'panel');
      if (opened.items.length !== 4) failures.push(`picker: expected 4 surfaces, got ${opened.items.length}`);
      if (!new RegExp(`show ${avd.name} in`).test(opened.title || '')) {
        failures.push(`picker: title does not name the row's AVD (${opened.title})`);
      }
      for (const item of opened.items) {
        if (!(item.iconPath instanceof vscodeMock.ThemeIcon)) failures.push(`picker: ${item.key} has no codicon`);
        if (typeof item.picked !== 'boolean') failures.push(`picker: ${item.key} carries no tick state`);
      }
      if (!opened.items.find(i => i.key === 'panel').picked) failures.push('picker: the open panel is not ticked');
      if (opened.items.find(i => i.key === 'editor').picked) failures.push('picker: the editor tab reads shown with no tab');

      // Turning the panel off blanks the mirror in place: it must not close the
      // part, which would take the AVDs view - and this menu - with it.
      const closed = calls.filter(c => c[0] === 'executeCommand' && String(c[1]).startsWith('workbench.action.close')).length;
      viewState.treeVisible = false;
      const blanked = await pick(row);
      viewState.treeVisible = true;
      if (blanked.items.find(i => i.key === 'panel').picked) failures.push('picker: the panel reads shown with no view visible');
      if (calls.filter(c => c[0] === 'executeCommand' && String(c[1]).startsWith('workbench.action.close')).length > closed) {
        failures.push('picker: turning the panel off closed a part');
      }
      if (!viewState.treeVisible) failures.push('picker: the AVDs view was hidden with the panel');

      // The row form acts on the AVD it names. A surface switched on for an AVD
      // the mirror is not showing would never appear, so it is refused instead of
      // left looking set.
      const warnedBefore = calls.filter(c => c[0] === 'showWarningMessage').length;
      const ghost = await pick({ name: 'ghost_avd' }, 'editor');
      if (calls.filter(c => c[0] === 'showWarningMessage').length === warnedBefore) {
        failures.push('picker(ghost_avd): not refused');
      }
      if (ghost.items.some(i => i.picked)) failures.push('picker(ghost_avd): listed another AVD\'s surfaces as shown');
      if (panels.some(p => p.viewType === 'avdMirror.editor' && !p.disposed)) {
        failures.push('picker(ghost_avd): opened the tab anyway');
      }

      // The embedded browser is the one browser surface VS Code owns, so unlike
      // the external Browser switch it can be closed again - and it must close
      // only its own tab.
      await pick(row, 'embedded');
      await sync();
      const emb = panels.filter(p => p.viewType === 'avdMirror.embedded' && !p.disposed).pop();
      if (!emb) failures.push('picker: ticked Embedded Browser and no tab appeared');
      else {
        const html = emb.webview.html || '';
        if (!/iframe[^>]+src="http:\/\/127\.0\.0\.1:8777\//.test(html)) failures.push('picker: the page is not framed from the server');
        if (!/frame-src[^;"]*127\.0\.0\.1:8777/.test(html)) failures.push('picker: frame-src would block the page');
      }
      await pick(row);
      await sync();
      if (emb && !emb.disposed) failures.push('picker: unticking Embedded Browser left the tab open');

      // Every surface above went through setDisplay(), whose failures are
      // swallowed into an error message - so an errored switch would otherwise
      // pass as long as it did not throw.
      const errs = calls.filter(c => c[0] === 'showErrorMessage').slice(errsBefore);
      if (errs.length) failures.push(`picker: switching surfaces errored (${errs.map(e => e[1]).join(' | ')})`);

      // FLAG_SECURE is a policy, not a property of one AVD, so it is not in the
      // row menu: it is a setting, and the palette opens the same ticked picker
      // the surfaces use. Two commands would need their own context key, and the
      // palette cannot draw a tick on either of them.
      const props = (pkg.contributes.configuration || {}).properties || {};
      const flag = props['avdMirror.honourFlagSecure'];
      if (!flag) failures.push('avdMirror.honourFlagSecure: not contributed');
      else {
        if (flag.type !== 'boolean') failures.push(`honourFlagSecure: type is ${flag.type}`);
        if (flag.default !== false) {
          failures.push(`honourFlagSecure: default is ${flag.default} - mirroring secure windows is the point of the extension`);
        }
      }
      if (!commands.some(c => c.command === 'avdMirror.chooseFlagSecure')) {
        failures.push('avdMirror.chooseFlagSecure: not contributed');
      }
      const flagMenu = itemMenuAll.find(m => m.command === 'avdMirror.chooseFlagSecure');
      if (flagMenu) failures.push('chooseFlagSecure: in the row menu - it is not a property of one AVD');
      if ((pkg.contributes.menus.commandPalette || []).some(m => m.command === 'avdMirror.chooseFlagSecure')) {
        failures.push('chooseFlagSecure: hidden from the palette, which is the only place it can be reached from');
      }
      if (!run('avdMirror.chooseFlagSecure')) failures.push('avdMirror.chooseFlagSecure: not registered');

      // Drive it: the value in force is the ticked row, the codicons are real,
      // and the answer is written back as the global setting the server reads.
      const picksBefore = calls.filter(c => c[0] === 'showQuickPick').length;
      configStore['avdMirror.honourFlagSecure'] = false;
      quickPickAnswers.push(items => items.find(i => i.value === true));
      await run('avdMirror.chooseFlagSecure')();
      const flagPick = calls.filter(c => c[0] === 'showQuickPick')[picksBefore];
      if (!flagPick) failures.push('chooseFlagSecure: opened no picker');
      else {
        const items = flagPick[2];
        if (items.length !== 2) failures.push(`chooseFlagSecure: expected 2 rows, got ${items.length}`);
        if (!items.every(i => i.iconPath instanceof vscodeMock.ThemeIcon)) {
          failures.push('chooseFlagSecure: a row has no codicon');
        }
        const off = items.find(i => i.value === false);
        if (!off || off.picked !== true) failures.push('chooseFlagSecure: the value in force (off) is not ticked');
      }
      const wrote = configUpdates.pop();
      if (!wrote || wrote[0] !== 'avdMirror.honourFlagSecure' || wrote[1] !== true
          || wrote[2] !== vscodeMock.ConfigurationTarget.Global) {
        failures.push(`chooseFlagSecure: wrote ${wrote ? wrote.join(',') : 'nothing'}`);
      }
    } else {
      failures.push('tree: no AVD row');
    }

    // The eight pair commands went with the menu entries that needed them: a
    // registered command with no contribution is a palette entry that opens a
    // surface the menu no longer offers.
    for (const gone of ['showInPanel', 'hideFromPanel', 'showInEditor', 'hideFromEditor',
      'showInBrowser', 'hideFromBrowser', 'showInEmbedded', 'hideFromEmbedded']) {
      if (run('avdMirror.' + gone)) failures.push(`avdMirror.${gone}: still registered after the picker replaced the pairs`);
    }
    if (!run('avdMirror.toggleDisplay')) failures.push('avdMirror.toggleDisplay: not registered');
  }

  // A server left behind by an older build answers /gsize exactly like a current
  // one, which is how "rebuild and reinstall" looked like a no-op: the new menu
  // ran against old capture and window code. Both sides hash the script and the
  // extension replaces a server whose hash differs - including one that has no
  // /build at all, which is by definition older than the handshake.
  const buildHash = (file) =>
    crypto.createHash('sha256').update(fs.readFileSync(path.join(__dirname, file))).digest('hex').slice(0, 12);
  for (const [label, file] of [['mirror', 'scripts/mirror.ps1'], ['AVD manager', 'scripts/avd.ps1']]) {
    const text = fs.readFileSync(path.join(__dirname, file), 'utf8');
    if (!/\$script:BuildId\s*=/.test(text)) failures.push(`${label}: no build id - a stale process would stay undetectable`);
    if (!/\$path -like '\/build\*'/.test(text)) failures.push(`${label}: no /build endpoint to report it`);
  }
  const extText = fs.readFileSync(path.join(__dirname, 'extension.js'), 'utf8');
  if (!/function scriptBuild\(/.test(extText)) failures.push('extension.js: no scriptBuild() to compare against');
  if (!/function listenerPid\(/.test(extText)) {
    failures.push('extension.js: no listenerPid() - a server older than the handshake reports no pid, so nothing could stop it');
  }
  if (!/killProcessByPid\(\(info && info\.pid\) \|\| listenerPid\(PORT\), 'mirror server'\)/.test(extText)) {
    failures.push('startServer: adopts a server of another build instead of replacing it');
  }
  if (!/killProcessByPid\(\(info && info\.pid\) \|\| listenerPid\(avdPort\), 'AVD manager'\)/.test(extText)) {
    failures.push('startAvdManager: adopts a manager of another build instead of replacing it');
  }
  if (!/if \(!want \|\| \(info && info\.build === want\)\) \{ avdPort = candidate; return candidate; \}/.test(extText)) {
    failures.push('pickAvdPort: adopts whatever answers on a candidate port without checking its build');
  }

  // FLAG_SECURE. The verdict has to come from the server, because the frames come
  // straight from the capturer on 8778: the page never asks the server for a
  // picture, so a server-side check alone could not stop one being shown, and a
  // page-side guess alone would have nothing to go on.
  const mirrorText = fs.readFileSync(path.join(__dirname, 'scripts/mirror.ps1'), 'utf8');
  if (!/\$path -like '\/secure\*'/.test(mirrorText)) failures.push('mirror.ps1: no /secure endpoint to carry the policy');
  if (!/function Test-FlagSecure/.test(mirrorText)) failures.push('mirror.ps1: no FLAG_SECURE detection');
  if (!/'shell', 'dumpsys', 'window'\)/.test(mirrorText)) {
    failures.push('mirror.ps1: FLAG_SECURE is not read from `dumpsys window` - the `windows` form prints no mCurrentFocus on Android 14');
  }
  const blanks = mirrorText.match(/if \(Test-FlagSecure\) \{ \$blank = 1 \}/g) || [];
  if (blanks.length < 2) failures.push('mirror.ps1: /rot and the rotate reply do not both report the verdict');
  if (!/id="secure"/.test(mirrorText)) failures.push('mirror.ps1: the page has no protected-content veil');
  if (!/setProtected\(parts\[3\]==='1'\)/.test(mirrorText)) failures.push('mirror.ps1: the page ignores the verdict');
  if (!/if\(!secureEl\.hidden\)/.test(mirrorText)) failures.push('mirror.ps1: the frame loop keeps fetching while protected');
  if (!/\(touch\|input\|gsize\|window\|rot\|secure\|frame\\\.jpg\)/.test(extText)) {
    failures.push('extension.js: the inlined page is not told where /rot and /secure live, so the panel cannot obey');
  }

  // And the live server, after activation had its chance to replace a stale one.
  // Silence is not a failure (the server may simply not be started yet), but a
  // wrong build is: that is the state where nothing new is actually running.
  let live = null;
  for (let tries = 0; tries < 60 && !live; tries++) {
    live = await fetch('http://127.0.0.1:8777/build', { cache: 'no-store' })
      .then(r => (r.ok ? r.json() : null)).catch(() => null);
    if (!live) await new Promise(r => setTimeout(r, 500));
  }
  if (!live) {
    console.log('mirror server build: no /build answer (not running, or predates the handshake)');
  } else {
    console.log(`mirror server build: ${live.build} pid ${live.pid} (repo: ${buildHash('scripts/mirror.ps1')})`);
    if (live.build !== buildHash('scripts/mirror.ps1')) {
      failures.push(`mirror server: running build ${live.build}, not the one in this checkout`);
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
  if (process.env.HARNESS_VERBOSE) {
    console.log('--- AVD Mirror output channel ---');
    for (const c of calls) if (c[0] === 'appendLine') console.log('  |', c[1]);
  }
  console.log('failures:', failures.length ? failures.join(' | ') : 'none');
  if (failures.length) { console.log('HARNESS FAILED'); process.exit(1); }
  ext.deactivate();
  console.log('deactivate() OK');
  // The tree polls on a timer; exit explicitly rather than waiting it out.
  process.exit(0);
})().catch(e => { console.error('FAILED:', e && e.stack ? e.stack : e); process.exit(1); });
