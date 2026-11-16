const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const { _electron: electron } = require('playwright-core');

const root = path.resolve(__dirname, '..');
const output = path.join(root, 'test-results', `windows-reconciliation-${Date.now()}`);
fs.mkdirSync(output, { recursive: true });
const api = process.env.MOTORLINE_TEST_API || 'http://127.0.0.1:4000/api/v1';
const password = process.env.MOTORLINE_DEMO_PASSWORD || 'MotorlineDemo123!';
async function call(endpoint, body, token) {
  const response = await fetch(api + endpoint, {
    method: body === undefined ? 'GET' : 'POST',
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const value = await response.json();
  assert.ok(response.ok, `${endpoint}: ${JSON.stringify(value)}`);
  return value;
}

(async () => {
  const owner = await call('/auth/login', { email: 'owner@motorline.local', password, branchId: 'pune' });
  const email = `windows-reconciliation-${Date.now()}@example.test`;
  await call('/users', { name: 'Windows reconciliation verification', email, password, role: 'manager', branchIds: ['pune'] }, owner.token);
  const manager = await call('/auth/login', { email, password, branchId: 'pune' });
  const token = manager.token;
  const product = await call('/products', {
    name: 'Windows last-unit verification filter', sku: `WIN-CONFLICT-${randomUUID()}`,
    brand: 'Fictional', partNumber: 'RECONCILE-1', category: 'Filters', unit: 'Each',
    cost: 5000, retailPrice: 10000, wholesalePrice: 9000, taxRate: 1800, universal: true,
  }, token);
  await call('/inventory/adjust', { productId: product.id, binId: 'bin-a1', quantity: 1, reason: 'Isolated last-unit acceptance fixture' }, token);
  const shift = await call('/shifts/open', { openingCash: 0 }, token);
  const devices = [];
  for (const suffix of ['A', 'B']) devices.push(await call('/devices/enroll', {
    name: `Windows last-unit counter ${suffix}`, offlineAllowed: true, offlineHours: 24, tenders: ['Cash'], rangeSize: 1000,
  }, token));
  const snapshot = await call('/bootstrap', undefined, token);
  const sales = devices.map(device => ({
    transactionId: randomUUID(), deviceId: device.id, invoiceNumber: device.rangeStart,
    offline: true, occurredAt: new Date(Math.max(Date.now(), Date.parse(device.enrolledAt) + 1000)).toISOString(), catalogRevision: snapshot.catalogRevision,
    shiftId: shift.id, priceLevel: 'retail', discount: 0,
    lines: [{ productId: product.id, qty: 1, binId: 'bin-a1' }],
    tenders: [{ type: 'Cash', amount: 11800, confirmed: true }],
  }));
  const outcomes = await Promise.all(sales.map(sale => call('/sync', { deviceId: sale.deviceId, transactions: [sale] }, token)));
  assert.deepEqual(outcomes.map(value => value.results[0].status).sort(), ['accepted', 'conflict']);
  const conflictIndex = outcomes.findIndex(value => value.results[0].status === 'conflict');
  const conflictId = outcomes[conflictIndex].results[0].conflictId;
  const before = await call('/bootstrap', undefined, token);
  assert.equal(before.stock.find(value => value.productId === product.id && value.binId === 'bin-a1').quantity, 0);
  assert.equal(before.invoices.filter(value => sales.some(sale => sale.transactionId === value.transactionId)).length, 1);

  const application = await electron.launch({
    executablePath: process.env.MOTORLINE_INSTALLED_EXE || path.join(root, 'release/windows/win-unpacked/Motorline POS.exe'),
    env: { ...process.env, MOTORLINE_TEST_PROFILE: path.join(output, 'profile') }, args: [],
  });
  const page = await application.firstWindow();
  page.setDefaultTimeout(15000);
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  try {
    await page.getByLabel('Server API').fill(api);
    await page.getByLabel('Organization code').fill('demo');
    await page.getByLabel('Branch code').fill('pune');
    await page.getByLabel('Email', { exact: true }).fill(email);
    await page.getByLabel('Password', { exact: true }).fill(password);
    await page.getByRole('button', { name: 'Sign in', exact: true }).click();
    await page.getByRole('heading', { name: 'Sales terminal' }).waitFor();
    await page.getByRole('navigation').getByRole('button', { name: 'Reconciliation', exact: true }).click();
    const row = page.getByRole('row').filter({ hasText: conflictId });
    await row.getByRole('button', { name: 'Resolve', exact: true }).click();
    const dialog = page.locator('dialog');
    await dialog.getByLabel('Decision').selectOption('accept');
    const reason = 'Windows manager verified the physical oversell and ordered replenishment.';
    await dialog.locator('[name="reason"]').fill(reason);
    await dialog.locator('button[type="submit"]').click();
    await dialog.waitFor({ state: 'hidden' });
    await row.getByText('accepted', { exact: true }).waitFor();
    assert.equal(await row.getByRole('button', { name: 'Resolve', exact: true }).count(), 0);
    const auditRow = page.getByRole('row').filter({ hasText: 'conflict-resolution' }).filter({ hasText: reason });
    await auditRow.waitFor();
    await page.screenshot({ path: path.join(output, 'resolved.png'), fullPage: true });

    const resolved = await call('/bootstrap', undefined, token);
    const invoices = resolved.invoices.filter(value => sales.some(sale => sale.transactionId === value.transactionId));
    assert.equal(invoices.length, 2);
    const conflict = resolved.conflicts.find(value => value.id === conflictId);
    assert.equal(conflict.status, 'accepted');
    assert.equal(conflict.resolvedBy, manager.user.id);
    assert.equal(resolved.stock.find(value => value.productId === product.id && value.binId === 'bin-a1').quantity, -1);
    assert.equal(resolved.audit.filter(value => value.action === 'conflict-resolution' && value.subject === conflictId).length, 1);
    const movements = await call('/reports/stock-movement', undefined, token);
    const movementRows = Array.isArray(movements) ? movements : movements.rows;
    const ledgerBefore = movementRows.filter(value => value.productId === product.id);

    const replay = await call('/sync', { deviceId: sales[conflictIndex].deviceId, transactions: [sales[conflictIndex]] }, token);
    assert.equal(replay.results[0].status, 'accepted');
    assert.equal(replay.results[0].invoice.id, conflict.invoice.id);
    await call(`/conflicts/${conflictId}/resolve`, { action: 'accept', reason: 'Repeated request must be idempotent' }, token);
    const after = await call('/bootstrap', undefined, token);
    const movementsAfter = await call('/reports/stock-movement', undefined, token);
    assert.deepEqual((Array.isArray(movementsAfter) ? movementsAfter : movementsAfter.rows).filter(value => value.productId === product.id), ledgerBefore);
    assert.equal(after.invoices.filter(value => sales.some(sale => sale.transactionId === value.transactionId)).length, 2);
    assert.equal(after.stock.find(value => value.productId === product.id && value.binId === 'bin-a1').quantity, -1);
    assert.equal(after.audit.filter(value => value.action === 'conflict-resolution' && value.subject === conflictId).length, 1);
    assert.deepEqual(errors, []);
    const results = {
      passed: true, client: 'Installed Windows Electron 45.3.2', timestamp: new Date().toISOString(),
      separateDevices: devices.map(value => value.id), conflictId, invoiceIds: invoices.map(value => value.id),
      checks: ['Two enrolled counters concurrently submitted last unit: one accepted, one pending conflict',
        'Installed manager UI accepted conflict with recorded reason', 'Accepted row no longer offered Resolve',
        'Manager audit row visible and recorded once', 'Exactly two invoices and stock -1 after explicit manager oversell acceptance',
        'Sync replay and resolution retry created no new invoice, stock deduction, ledger entry or audit event'],
    };
    fs.writeFileSync(path.join(output, 'results.json'), JSON.stringify(results, null, 2));
    fs.mkdirSync(path.join(root, 'docs/test-results'), { recursive: true });
    fs.writeFileSync(path.join(root, 'docs/test-results/windows-reconciliation.json'), JSON.stringify(results, null, 2));
    console.log(JSON.stringify({ ...results, output }, null, 2));
  } catch (error) {
    await page.screenshot({ path: path.join(output, 'failure.png'), fullPage: true }).catch(() => {});
    throw error;
  } finally { await application.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
