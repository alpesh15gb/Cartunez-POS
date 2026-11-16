const assert = require('node:assert/strict');
const { randomUUID, createHash } = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { connectPage } = require('./android-bridge.cjs');

// Run against an installed test APK signed into the seeded owner's Pune branch.
// Fixtures and competing sync submissions use the API; conflict resolution uses
// only the installed Android application's actual Reconciliation screen.
const adb = process.argv[2];
const output = process.argv[3] || path.resolve(__dirname, '../docs/test-results');
const base = process.env.MOTORLINE_TEST_API || 'http://127.0.0.1:4000/api/v1';
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));

(async () => {
  let token;
  const api = async (route, body) => {
    const response = await fetch(base + route, {
      method: body ? 'POST' : 'GET',
      headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
      body: body ? JSON.stringify(body) : undefined,
    });
    const data = await response.json();
    if (!response.ok) throw new Error(`${route}: ${response.status} ${JSON.stringify(data)}`);
    return data;
  };
  const owner = await api('/auth/login', { organizationId: 'demo', branchId: 'pune', email: 'owner@motorline.local', password: 'MotorlineDemo123!' });
  token = owner.token;
  const original = await api('/bootstrap');
  const shift = original.shifts.find(item => item.userId === original.user.id && !item.closedAt);
  assert.ok(shift, 'The seeded owner must have an open shift before this targeted test.');
  const suffix = randomUUID();
  const part = await api('/products', {
    name: `Android reconciliation fixture ${suffix}`, sku: `AND-CONFLICT-${suffix}`,
    brand: 'Fictional Acceptance', partNumber: `CONFLICT-${suffix}`, category: 'Parts', unit: 'ea',
    cost: 5000, retailPrice: 10000, wholesalePrice: 9000, taxRate: 0, universal: true,
  });
  await api('/inventory/adjust', { productId: part.id, binId: 'bin-a1', quantity: 1, reason: 'Isolated fictional Android concurrent-last-unit fixture' });
  const devices = [];
  for (const label of ['A', 'B']) devices.push(await api('/devices/enroll', {
    name: `Android reconciliation ${label} ${suffix}`, offlineAllowed: true, offlineHours: 24, tenders: ['Cash'], rangeSize: 10,
  }));
  assert.ok(devices[0].rangeEnd < devices[1].rangeStart || devices[1].rangeEnd < devices[0].rangeStart, 'Device invoice ranges must not overlap.');
  const cached = await api('/bootstrap');
  const quantity = data => data.stock.find(item => item.productId === part.id && item.binId === 'bin-a1')?.quantity;
  assert.equal(quantity(cached), 1);
  const transactions = devices.map(device => ({
    transactionId: randomUUID(), deviceId: device.id, invoiceNumber: device.rangeStart,
    offline: true, occurredAt: new Date().toISOString(), catalogRevision: cached.catalogRevision,
    shiftId: shift.id, priceLevel: 'retail', discount: 0,
    lines: [{ productId: part.id, qty: 1, binId: 'bin-a1' }],
    tenders: [{ type: 'Cash', amount: 10000, confirmed: true }],
  }));
  const submit = index => api('/sync', { deviceId: devices[index].id, transactions: [transactions[index]] });
  const outcomes = (await Promise.all([submit(0), submit(1)])).flatMap(result => result.results);
  assert.deepEqual(outcomes.map(result => result.status).sort(), ['accepted', 'conflict']);
  const conflict = outcomes.find(result => result.status === 'conflict');
  const before = await api('/bootstrap');
  assert.equal(quantity(before), 0, 'Only the accepted first sale may consume the last unit.');
  assert.equal(before.conflicts.find(item => item.id === conflict.conflictId).status, 'pending');
  assert.equal(before.invoices.filter(item => transactions.some(tx => tx.transactionId === item.transactionId)).length, 1);

  const page = await connectPage(adb);
  try {
    const wait = async expression => {
      for (let attempt = 0; attempt < 100; attempt++) {
        if (await page.evaluate(expression)) return;
        await pause(200);
      }
      throw new Error(`Android condition not reached: ${expression}`);
    };
    await page.call('Page.reload', { ignoreCache: true });
    await wait("Boolean(document.querySelector('.app-shell'))");
    assert.equal(await page.evaluate(`(async()=>{const session=JSON.parse(await window.motorlineNative.get('active-session'));return session?.user?.id===${JSON.stringify(original.user.id)} && session?.branchId==='pune';})()`), true, 'Installed Android app must be signed into the seeded owner and branch.');
    await page.evaluate("[...document.querySelectorAll('.nav-link')].find(button=>button.textContent==='Reconciliation').click()");
    const rowExpression = `[...document.querySelectorAll('tbody tr')].find(row=>row.textContent.includes(${JSON.stringify(conflict.conflictId)}))`;
    await wait(`Boolean(${rowExpression})`);
    await page.evaluate(`(() => {const row=${rowExpression};[...row.querySelectorAll('button')].find(button=>button.textContent==='Resolve').click();})()`);
    await wait("Boolean(document.querySelector('dialog[open] form'))");
    const reason = `Android manager verified oversold fictional stock; replenishment recorded ${suffix}`;
    for (const [name, value] of Object.entries({ action: 'accept', reason })) {
      await page.evaluate(`(() => {const element=document.querySelector('dialog [name="${name}"]');Object.getOwnPropertyDescriptor(Object.getPrototypeOf(element),'value').set.call(element,${JSON.stringify(value)});element.dispatchEvent(new Event('input',{bubbles:true}));element.dispatchEvent(new Event('change',{bubbles:true}));})()`);
    }
    await page.evaluate("document.querySelector('dialog[open] form').requestSubmit()");
    await wait("!document.querySelector('dialog[open]')");
    await wait(`Boolean((${rowExpression})?.textContent.includes('accepted'))`);
    assert.equal(await page.evaluate(`Boolean((${rowExpression})?.querySelector('button'))`), false, 'A resolved conflict must no longer offer Resolve.');
    await wait(`[...document.querySelectorAll('tbody tr')].some(row=>row.textContent.includes('conflict-resolution') && row.textContent.includes(${JSON.stringify(reason)}))`);

    let final = await api('/bootstrap');
    const resolved = final.conflicts.find(item => item.id === conflict.conflictId);
    assert.equal(resolved.status, 'accepted');
    assert.equal(resolved.reason, reason);
    assert.equal(resolved.resolvedBy, original.user.id);
    assert.equal(resolved.refundRequired, false);
    assert.equal(quantity(final), -1, 'Explicit manager acceptance records exactly one oversold unit.');
    const invoiceIds = transactions.map(tx => {
      const invoices = final.invoices.filter(item => item.transactionId === tx.transactionId);
      assert.equal(invoices.length, 1, 'Each competing transaction must have exactly one finalized invoice.');
      assert.equal(invoices[0].total, 10000);
      return invoices[0].id;
    });
    const audits = final.audit.filter(item => item.action === 'conflict-resolution' && item.subject === conflict.conflictId);
    assert.equal(audits.length, 1);
    assert.equal(audits[0].userId, original.user.id);
    assert.equal(audits[0].reason, reason);
    assert.equal(audits[0].details.action, 'accept');
    const replays = (await Promise.all([submit(0), submit(1)])).flatMap(result => result.results);
    assert.deepEqual(replays.map(item => item.status), ['accepted', 'accepted']);
    assert.deepEqual(replays.map(item => item.invoice.id), invoiceIds);
    final = await api('/bootstrap');
    assert.equal(quantity(final), -1, 'Retries must not repeat stock movement.');
    for (const tx of transactions) assert.equal(final.invoices.filter(item => item.transactionId === tx.transactionId).length, 1);
    assert.equal(final.audit.filter(item => item.action === 'conflict-resolution' && item.subject === conflict.conflictId).length, 1);
    fs.mkdirSync(output, { recursive: true });
    const apk = path.resolve(__dirname, '../release/android/Motorline-1.0.0-test.apk');
    const result = {
      passed: true,
      environment: 'Installed Android API 36 app; shared PostgreSQL API',
      apkSha256: createHash('sha256').update(fs.readFileSync(apk)).digest('hex').toUpperCase(),
      fixtureSubmission: 'API submits two concurrent offline transactions from separately enrolled devices using one cached catalog revision',
      managerResolution: 'Actual installed Android Reconciliation screen, decision and reason form, accepted status and audit row',
      productId: part.id, conflictId: conflict.conflictId,
      transactions: transactions.map((tx, index) => ({ transactionId: tx.transactionId, invoiceId: invoiceIds[index], invoiceNumber: tx.invoiceNumber })),
      concurrentOutcomes: outcomes.map(item => item.status).sort(),
      stockBefore: 1, stockBeforeResolution: 0, stockAfterResolutionAndReplay: -1,
      invoiceCountPerTransaction: [1, 1], resolutionAuditCount: 1, replayIdempotency: true,
    };
    fs.writeFileSync(path.join(output, 'android-reconciliation.json'), JSON.stringify(result, null, 2) + '\n');
    const screenshot = await page.call('Page.captureScreenshot', { format: 'png' });
    fs.writeFileSync(path.join(output, 'android-reconciliation.png'), Buffer.from(screenshot.data, 'base64'));
    console.log('PASS Android manager reconciliation UI: two devices race for one unit; accepted+conflict; audited acceptance; stock -1; one invoice per transaction; retry idempotency.');
  } finally { page.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
