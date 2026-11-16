const { app, BrowserWindow, protocol, net, ipcMain, dialog } = require('electron');
const fs = require('node:fs');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const initSqlJs = require('sql.js');

protocol.registerSchemesAsPrivileged([{ scheme: 'motorline', privileges: { standard: true, secure: true, supportFetchAPI: true, corsEnabled: true } }]);

if (process.env.MOTORLINE_TEST_PROFILE) app.setPath('userData', path.resolve(process.env.MOTORLINE_TEST_PROFILE));
const singleInstance = app.requestSingleInstanceLock();
if (!singleInstance) app.quit();
let window;
let database;
let databasePath;

function validKey(key) {
  if (typeof key !== 'string' || !key || key.length > 1024) throw new Error('Invalid workspace key.');
  return key;
}

function persist() {
  const destination = databasePath + '.pending';
  const handle = fs.openSync(destination, 'w', 0o600);
  try {
    fs.writeFileSync(handle, Buffer.from(database.export()));
    fs.fsyncSync(handle);
  } finally {
    fs.closeSync(handle);
  }
  fs.renameSync(destination, databasePath);
}

function validateCaller(event) {
  if (!event.senderFrame?.url.startsWith('motorline://app/')) throw new Error('Workspace storage is available to Motorline only.');
}

async function initializeStorage() {
  const SQL = await initSqlJs();
  fs.mkdirSync(app.getPath('userData'), { recursive: true });
  databasePath = path.join(app.getPath('userData'), 'workspace.sqlite');
  database = fs.existsSync(databasePath) ? new SQL.Database(fs.readFileSync(databasePath)) : new SQL.Database();
  database.run('CREATE TABLE IF NOT EXISTS workspace (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at TEXT NOT NULL)');
  persist();
  ipcMain.handle('workspace:get', (event, key) => {
    validateCaller(event);
    const statement = database.prepare('SELECT value FROM workspace WHERE key = ?');
    try {
      statement.bind([validKey(key)]);
      return statement.step() ? statement.getAsObject().value : null;
    } finally { statement.free(); }
  });
  function mutate(event, action) {
    validateCaller(event);
    const before = database.export();
    try { action(); persist(); } catch (error) {
      database.close();
      database = new SQL.Database(before);
      throw error;
    }
  }
  ipcMain.handle('workspace:set', (event, key, value) => {
    if (typeof value !== 'string' || Buffer.byteLength(value) > 64 * 1024 * 1024) throw new Error('Workspace is too large.');
    mutate(event, () => database.run('INSERT INTO workspace(key,value,updated_at) VALUES(?,?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at', [validKey(key), value, new Date().toISOString()]));
  });
  ipcMain.handle('workspace:remove', (event, key) => mutate(event, () => database.run('DELETE FROM workspace WHERE key=?', [validKey(key)])));
}

function createWindow() {
  window = new BrowserWindow({
    width: 1440, height: 1000, minWidth: 850, minHeight: 620, backgroundColor: '#f5f7f6',
    show: !process.argv.includes('--smoke-test'),
    webPreferences: { preload: path.join(__dirname, 'preload.cjs'), contextIsolation: true, nodeIntegration: false, sandbox: true },
  });
  window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  window.webContents.on('will-navigate', (event, url) => {
    if (!url.startsWith('motorline://app/')) event.preventDefault();
  });
  window.loadURL('motorline://app/');
  return window;
}

app.on('second-instance', () => { if (window) { window.restore(); window.focus(); } });
app.on('window-all-closed', () => app.quit());
app.whenReady().then(async () => {
  const root = path.resolve(app.isPackaged ? path.join(process.resourcesPath, 'web') : path.join(__dirname, '../web/out'));
  protocol.handle('motorline', request => {
    const url = new URL(request.url);
    if (url.host !== 'app') return new Response('Forbidden', { status: 403 });
    let relative = decodeURIComponent(url.pathname);
    if (relative.endsWith('/')) relative += 'index.html';
    const file = path.resolve(root, '.' + relative);
    if (!file.startsWith(root + path.sep)) return new Response('Forbidden', { status: 403 });
    return net.fetch(pathToFileURL(file).href);
  });
  await initializeStorage();
  ipcMain.handle('receipt:print', event => {
    validateCaller(event);
    return new Promise((resolve, reject) => event.sender.print({ printBackground: true }, (success, failure) => success ? resolve() : reject(new Error(failure))));
  });
  ipcMain.handle('receipt:pdf', async event => {
    validateCaller(event);
    const destination = await dialog.showSaveDialog(window, { defaultPath: 'Motorline-receipt.pdf', filters: [{ name: 'PDF', extensions: ['pdf'] }] });
    if (destination.canceled) return null;
    const bytes = await event.sender.printToPDF({ printBackground: true, pageSize: 'A4' });
    fs.writeFileSync(destination.filePath, bytes);
    return destination.filePath;
  });
  createWindow();
  if (process.argv.includes('--smoke-test')) {
    const output = process.env.MOTORLINE_TEST_OUTPUT || path.join(app.getPath('userData'), 'smoke-result.json');
    window.webContents.once('did-finish-load', async () => {
      try {
        await new Promise(resolve => setTimeout(resolve, 750));
        const result = await window.webContents.executeJavaScript(`(async () => {
          const previous = await window.motorlineNative.get('smoke:pending-outbox');
          if (!previous) await window.motorlineNative.set('smoke:pending-outbox', JSON.stringify({id:'stable-transaction',status:'pending'}));
          return { title: document.title, body: document.body.innerText.slice(0,500), bridge: !!window.motorlineNative, previous, current: await window.motorlineNative.get('smoke:pending-outbox') };
        })()`);
        if (process.env.MOTORLINE_TEST_SCREENSHOT) {
          const capture = await window.webContents.capturePage();
          fs.writeFileSync(process.env.MOTORLINE_TEST_SCREENSHOT, capture.toPNG());
        }
        fs.writeFileSync(output, JSON.stringify({ ...result, sqlite: databasePath, packaged: app.isPackaged, electron: process.versions.electron }, null, 2));
        app.exit(0);
      } catch (error) { fs.writeFileSync(output, JSON.stringify({ error: error.message })); app.exit(1); }
    });
    setTimeout(() => app.exit(2), 30000);
  }
}).catch(error => { console.error(error); app.exit(1); });
