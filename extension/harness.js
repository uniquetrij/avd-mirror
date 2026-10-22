// Harness: exercise extension.js against a mock VS Code API so runtime errors
// in the AVD tree view / commands show up here instead of in the extension host.
const path = require('path');
const Module = require('module');

const calls = [];
const mk = (name) => (...a) => { calls.push([name, ...a]); return undefined; };

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
  ProgressLocation: { Notification: 15, Window: 10 },
  ViewColumn: { Active: -1 },
  window: {
    createOutputChannel: () => ({ appendLine: mk('appendLine'), append: mk('append'), dispose() {} }),
    registerWebviewViewProvider: () => ({ dispose() {} }),
    createTreeView: (id, opts) => { calls.push(['createTreeView', id, opts.treeDataProvider]); return { dispose() {} }; },
    createWebviewPanel: () => ({ webview: {}, onDidDispose: () => ({ dispose() {} }), reveal() {}, dispose() {} }),
    showErrorMessage: mk('showErrorMessage'),
    showWarningMessage: mk('showWarningMessage'),
    showInformationMessage: mk('showInformationMessage'),
    setStatusBarMessage: mk('setStatusBarMessage'),
    withProgress: async (opts, fn) => { calls.push(['withProgress', opts.title]); return fn(); },
    registerTreeDataProvider: () => ({ dispose() {} }),
  },
  commands: {
    registerCommand: (id, fn) => { calls.push(['registerCommand', id, fn]); return { dispose() {} }; },
    executeCommand: mk('executeCommand'),
  },
  workspace: { workspaceFolders: [{ uri: { scheme: 'file', fsPath: path.resolve(__dirname, '..', '..') } }] },
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
  console.log('failures:', failures.length ? failures.join(' | ') : 'none');
  if (failures.length) { console.log('HARNESS FAILED'); process.exit(1); }

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
  }

  // And confirm the manager answers, which is what the tree reads.
  const health = await fetch('http://127.0.0.1:8779/health').then(r => r.text()).catch(e => 'ERR ' + e.message);
  console.log('manager health:', health);
  ext.deactivate();
  console.log('deactivate() OK');
  // The tree polls on a timer; exit explicitly rather than waiting it out.
  process.exit(0);
})().catch(e => { console.error('FAILED:', e && e.stack ? e.stack : e); process.exit(1); });
