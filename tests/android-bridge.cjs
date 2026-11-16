const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

async function connectPage(adb, serial = 'emulator-5558') {
  const run = (...args) => execFileSync(adb, ['-s', serial, ...args], { encoding: 'utf8', windowsHide: true });
  run('shell', 'am', 'start', '-n', 'com.motorline.pos/.MainActivity');
  await new Promise(resolve => setTimeout(resolve, 2000));
  let target;
  for (let attempt = 0; attempt < 60 && !target; attempt++) {
    try {
      const pid = run('shell', 'pidof', 'com.motorline.pos').trim().split(' ')[0];
      const socket = run('shell', 'cat', '/proc/net/unix').split('\n').find(line => line.includes(`@webview_devtools_remote_${pid}`))?.split('@')[1]?.trim();
      if (socket) {
        run('forward', 'tcp:9338', `localabstract:${socket}`);
        target = (await (await fetch('http://127.0.0.1:9338/json/list', { signal: AbortSignal.timeout(2000) })).json()).find(item => item.type === 'page');
      }
    } catch {}
    if (!target) await new Promise(resolve => setTimeout(resolve, 250));
  }
  assert.ok(target, 'A debuggable Android WebView must be running.');
  const socket = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('WebView websocket handshake timed out.')), 5000);
    socket.onopen = () => { clearTimeout(timer); resolve(); };
    socket.onerror = event => { clearTimeout(timer); reject(event); };
  });
  let sequence = 0;
  const pending = new Map();
  socket.onmessage = event => {
    const message = JSON.parse(event.data);
    if (!pending.has(message.id)) return;
    const { resolve, reject, timer } = pending.get(message.id);
    pending.delete(message.id);
    clearTimeout(timer);
    if (message.error) reject(new Error(message.error.message));
    else resolve(message.result);
  };
  const call = (method, params = {}) => new Promise((resolve, reject) => {
    const id = ++sequence;
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`Timed out ${method}`)); }, 20000);
    pending.set(id, { resolve, reject, timer });
    socket.send(JSON.stringify({ id, method, params }));
  });
  const evaluate = async expression => {
    const result = await call('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
    if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails));
    return result.result.value;
  };
  return { run, call, evaluate, close() {
    socket.close();
    const forwards = run('forward', '--list');
    if (forwards.split('\n').some(line => line.startsWith(`${serial} tcp:9338 `))) run('forward', '--remove', 'tcp:9338');
  } };
}

async function inspectNativeBridge({ adb, serial = 'emulator-5558', output, verifyRestart = false }) {
  if (verifyRestart) execFileSync(adb, ['-s', serial, 'shell', 'am', 'force-stop', 'com.motorline.pos'], { windowsHide: true });
  const page = await connectPage(adb, serial);
  try {
    for (let attempt = 0; attempt < 40 && !await page.evaluate('Boolean(window.motorlineNative)'); attempt++) await new Promise(resolve => setTimeout(resolve, 200));
    assert.equal(await page.evaluate('Boolean(window.motorlineNative)'), true);
    const value = JSON.stringify({ transactionId: 'android-durable-outbox-test', pending: true });
    if (!verifyRestart) await page.evaluate(`window.motorlineNative.set('org-test:branch-test:outbox', ${JSON.stringify(value)})`);
    assert.equal(await page.evaluate("window.motorlineNative.get('org-test:branch-test:outbox')"), value);
    assert.equal(await page.evaluate("window.motorlineNative.get('different-org:branch-test:outbox')"), null);
    if (!verifyRestart) {
      assert.equal(await page.evaluate("(async()=>{const large='A'.repeat(3*1024*1024)+'😃';await window.motorlineNative.set('verification:large-catalog',large);const read=await window.motorlineNative.get('verification:large-catalog');await window.motorlineNative.remove('verification:large-catalog');return read===large;})()"), true, 'Catalogs larger than CursorWindow must round-trip.');
    }
    if (output) {
      fs.mkdirSync(output, { recursive: true });
      const image = await page.call('Page.captureScreenshot', { format: 'png' });
      fs.writeFileSync(path.join(output, 'android-native.png'), Buffer.from(image.data, 'base64'));
    }
    if (verifyRestart) await page.evaluate("window.motorlineNative.remove('org-test:branch-test:outbox')");
  } finally { page.close(); }
}

if (require.main === module) {
  const [adb, output] = process.argv.slice(2);
  inspectNativeBridge({ adb, output }).then(() => inspectNativeBridge({ adb, output, verifyRestart: true }))
    .then(() => console.log('PASS Android native SQLite read/write, organization key isolation, durable pending transaction after force-stop and restart.'))
    .catch(error => { console.error(error); process.exitCode = 1; });
}
module.exports = { inspectNativeBridge, connectPage };
