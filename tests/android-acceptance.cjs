const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const { connectPage } = require('./android-bridge.cjs');

const adb = process.argv[2];
const serial = 'emulator-5558';
const output = process.argv[3] || 'work/production-android';
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));

(async () => {
  let page = await connectPage(adb, serial);
  const evaluate = expression => page.evaluate(expression);
  const waitFor = async (expression, timeout = 20000) => {
    const end = Date.now() + timeout;
    while (Date.now() < end) {
      if (await evaluate(expression)) return;
      await pause(200);
    }
    throw new Error(`Condition not reached: ${expression}\n${await evaluate('document.body.innerText')}`);
  };
  const click = async (text, selector = 'button') => {
    await evaluate(`(() => { const button = [...document.querySelectorAll(${JSON.stringify(selector)})].find(item => item.textContent.trim() === ${JSON.stringify(text)}); if (!button) throw new Error('Missing button ' + ${JSON.stringify(text)}); button.click(); })()`);
    await pause(120);
  };
  const field = async (name, value) => {
    await evaluate(`(() => { const element = document.querySelector('[name="${name}"]'); if (!element) throw new Error('Missing field ${name}'); const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(element), 'value').set; setter.call(element, ${JSON.stringify(value)}); element.dispatchEvent(new Event('input', {bubbles:true})); element.dispatchEvent(new Event('change', {bubbles:true})); })()`);
  };
  const submit = async () => {
    await evaluate("document.querySelector('dialog[open] form').requestSubmit()");
    await waitFor("!document.querySelector('dialog[open]') || Boolean(document.querySelector('.receipt'))");
  };
  const snapshot = () => evaluate(`(async () => { const session = JSON.parse(await window.motorlineNative.get('active-session')); const key = 'server:' + new URL(session.api).href.replace(/[/]$/,'') + ':org:' + session.organizationId + ':branch:' + session.branchId + ':user:' + session.user.id; return JSON.parse(await window.motorlineNative.get(key)); })()`);

  try {
    await waitFor("Boolean(document.querySelector('.login-card')) || Boolean(document.querySelector('.app-shell'))");
    if (await evaluate("Boolean(document.querySelector('.login-card'))")) {
      for (const [name, value] of Object.entries({ api: 'http://10.0.2.2:4000/api/v1', email: 'owner@motorline.local', password: 'MotorlineDemo123!', branchId: 'pune' })) await field(name, value);
      if (await evaluate("Boolean(document.querySelector('[name=organizationId]'))")) await field('organizationId', 'demo');
      await evaluate("document.querySelector('.login-card').requestSubmit()");
    }
    await waitFor("Boolean(document.querySelector('.app-shell'))");
    await waitFor("document.querySelector('.sync-status').textContent.includes('Server connected')");
    let workspace = await snapshot();
    const initialInvoices = workspace.snapshot.invoices.length;

    await click('Reconciliation', '.nav-link');
    await click('Enroll this counter');
    await field('name', 'Android acceptance counter');
    await submit();
    await click('Shifts', '.nav-link');
    workspace = await snapshot();
    if (!workspace.snapshot.shifts.some(shift => !shift.closedAt && shift.userId === 'user-owner')) {
      await click('Open shift');
      await field('openingCash', '1000');
      await submit();
    }

    await click('Billing', '.nav-link');
    await evaluate("document.querySelector('.vehicle-picker').click()");
    await field('preset', 'swift');
    await submit();
    await evaluate("document.querySelector('[aria-label=\"Add Spin-On Oil Filter\"]').click()");
    await field('binId', 'bin-a2');
    await submit();
    assert.match(await evaluate("document.querySelector('.cart-lines').textContent"), /compatible/);
    await click('Checkout ↗');
    await submit();
    await waitFor("Boolean(document.querySelector('.receipt'))");
    assert.match(await evaluate("document.querySelector('.receipt').textContent"), /Finalized/);
    await click('Done');

    await page.call('Network.enable');
    await page.call('Network.emulateNetworkConditions', { offline: true, latency: 0, downloadThroughput: 0, uploadThroughput: 0 });
    await evaluate("window.dispatchEvent(new Event('offline'))");
    await waitFor("document.querySelector('.sync-status').textContent.includes('Offline')");
    await evaluate("document.querySelector('[aria-label=\"Add Synthetic Engine Oil\"]').click()");
    await submit();
    await click('Checkout ↗');
    await submit();
    await waitFor("Boolean(document.querySelector('.receipt'))");
    await click('Done');
    workspace = await snapshot();
    const pending = workspace.pending.find(item => item.transaction.offline);
    assert.ok(pending, 'Offline sale must be in native durable outbox.');
    const transactionId = pending.transaction.transactionId;
    execFileSync(adb, ['-s', serial, 'shell', 'svc', 'wifi', 'disable'], { windowsHide: true });
    execFileSync(adb, ['-s', serial, 'shell', 'svc', 'data', 'disable'], { windowsHide: true });
    await pause(1000);
    page.close();
    execFileSync(adb, ['-s', serial, 'shell', 'am', 'force-stop', 'com.motorline.pos'], { windowsHide: true });
    page = await connectPage(adb, serial);
    await waitFor("Boolean(document.querySelector('.app-shell'))");
    workspace = await snapshot();
    assert.ok(workspace.pending.some(item => item.transaction.transactionId === transactionId), 'Outbox survives force-stop while offline.');
    execFileSync(adb, ['-s', serial, 'shell', 'svc', 'wifi', 'enable'], { windowsHide: true });
    execFileSync(adb, ['-s', serial, 'shell', 'svc', 'data', 'enable'], { windowsHide: true });
    await evaluate("window.dispatchEvent(new Event('online'))");
    await waitFor("document.querySelector('.sync-status').textContent.includes('0 pending')", 60000);
    workspace = await snapshot();
    assert.equal(workspace.snapshot.invoices.filter(invoice => invoice.transactionId === transactionId).length, 1);
    assert.ok(workspace.snapshot.invoices.length >= initialInvoices + 2);

    fs.mkdirSync(output, { recursive: true });
    const screenshot = await page.call('Page.captureScreenshot', { format: 'png' });
    fs.writeFileSync(`${output}/android-register.png`, Buffer.from(screenshot.data, 'base64'));
    fs.writeFileSync(`${output}/results.json`, JSON.stringify({ passed: true, environment: 'Android API 36 x86_64 emulator, Capacitor 8.6.2, native SQLite', transactionId, finalizedInvoices: 2, checks: ['Native login to shared PostgreSQL API', 'Vehicle compatibility', 'Actual bin pick', 'Cash checkout', 'Offline cash checkout', 'Force-stop with pending sale', 'Offline local workspace reopen', 'Reconnect and exactly-once synchronization'] }, null, 2));
    console.log('PASS Android login, compatible part/bin pick, cash sale, offline checkout, native restart, reconnect and exactly-once invoice.');
  } finally {
    try { execFileSync(adb, ['-s', serial, 'shell', 'svc', 'wifi', 'enable'], { windowsHide: true }); } catch {}
    try { execFileSync(adb, ['-s', serial, 'shell', 'svc', 'data', 'enable'], { windowsHide: true }); } catch {}
    page.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
