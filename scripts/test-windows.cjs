const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { _electron: electron } = require('playwright-core');
const root = path.resolve(__dirname, '..');
const output = path.join(root, 'test-results', `windows-${Date.now()}`);
fs.mkdirSync(output, { recursive: true });
const api = process.env.MOTORLINE_TEST_API || 'http://127.0.0.1:4000/api/v1';
const password = process.env.MOTORLINE_DEMO_PASSWORD || 'MotorlineDemo123!';
async function apiCall(endpoint, body, token) {
  const response = await fetch(api + endpoint, { method: body ? 'POST' : 'GET', headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) }, body: body ? JSON.stringify(body) : undefined });
  const value = await response.json();
  assert.ok(response.ok, JSON.stringify(value));
  return value;
}

async function launch(profile) {
  const application = await electron.launch({
    executablePath: process.env.MOTORLINE_INSTALLED_EXE || path.join(root, 'release/windows/win-unpacked/Motorline POS.exe'),
    env: { ...process.env, MOTORLINE_TEST_PROFILE: profile },
    args: [],
  });
  const page = await application.firstWindow();
  page.setDefaultTimeout(15000);
  return { application, page };
}

(async () => {
  const owner = await apiCall('/auth/login', { email: 'owner@motorline.local', password, branchId: 'pune' });
  const email = `windows-${Date.now()}@example.test`;
  await apiCall('/users', { name: 'Windows release verification', email, password, role: 'manager', branchIds: ['pune'] }, owner.token);
  const profile = path.join(output, 'profile');
  let { application, page } = await launch(profile);
  const results = [];
  try {
    await page.getByLabel('Server API').fill(api);
    await page.getByLabel('Organization code').fill('demo');
    await page.getByLabel('Branch code').fill('pune');
    await page.getByLabel('Email', { exact: true }).fill(email);
    await page.getByLabel('Password', { exact: true }).fill(password);
    await page.getByRole('button', { name: 'Sign in', exact: true }).click();
    await page.getByRole('heading', { name: 'Sales terminal' }).waitFor();
    results.push('Installed app signed into real PostgreSQL API');
    await page.getByRole('button', { name: 'Shifts', exact: true }).click();
    await page.getByRole('button', { name: 'Open shift', exact: true }).click();
    await page.getByLabel('Opening cash').fill('100');
    await page.locator('dialog button[type=submit]').click();
    await page.locator('dialog').waitFor({ state: 'hidden' });
    await page.getByRole('button', { name: 'Billing', exact: true }).click();
    await page.getByRole('button', { name: 'Add Synthetic Engine Oil', exact: true }).click();
    await page.getByRole('button', { name: 'Add to sale', exact: true }).click();
    await page.locator('dialog').waitFor({ state: 'hidden' });
    await page.getByRole('button', { name: 'Checkout', exact: false }).click();
    await page.getByRole('button', { name: 'Complete sale', exact: true }).click();
    await page.locator('.receipt').waitFor();
    const invoice = await page.locator('.receipt h2').innerText();
    assert.match(invoice, /ML-/);
    const pdf = await application.evaluate(async ({ BrowserWindow }) => {
      const output = await BrowserWindow.getAllWindows()[0].webContents.printToPDF({ printBackground: true });
      return output.toString('base64');
    });
    fs.writeFileSync(path.join(output, 'receipt.pdf'), Buffer.from(pdf, 'base64'));
    await page.screenshot({ path: path.join(output, 'sale.png') });
    results.push(`Cash sale finalized ${invoice} and PDF rendered`);
    await page.getByRole('button', { name: 'Done', exact: true }).click();
    await page.getByRole('button', { name: 'Reconciliation', exact: true }).click();
    await page.getByRole('button', { name: 'Enroll this counter', exact: true }).click();
    await page.getByLabel('Device name').fill('Windows acceptance counter');
    await page.getByRole('button', { name: 'Enroll device', exact: true }).click();
    await page.locator('dialog').waitFor({ state: 'hidden' });
    results.push('Offline counter enrolled with server-assigned invoice range');
    await page.route('**/api/v1/**', route => route.abort());
    await page.getByRole('button', { name: 'Synchronize now', exact: true }).click();
    await page.getByText('Offline · stock snapshot', { exact: false }).waitFor();
    await page.getByRole('button', { name: 'Billing', exact: true }).click();
    await page.getByRole('button', { name: 'Add Synthetic Engine Oil', exact: true }).click();
    await page.getByRole('button', { name: 'Add to sale', exact: true }).click();
    await page.locator('dialog').waitFor({ state: 'hidden' });
    await page.getByRole('button', { name: 'Checkout', exact: false }).click();
    await page.getByRole('button', { name: 'Save offline sale', exact: true }).click();
    await page.locator('.receipt').waitFor();
    await page.getByRole('button', { name: 'Done', exact: true }).click();
    assert.match(await page.locator('.sync-status').innerText(), /1 pending/);
    const saved = await page.evaluate(async () => {
      const session = JSON.parse(await window.motorlineNative.get('active-session'));
      const key = `server:${new URL(session.api).href.replace(/\/$/, '')}:org:${session.organizationId}:branch:${session.branchId}:user:${session.user.id}`;
      return { session, workspace: JSON.parse(await window.motorlineNative.get(key)) };
    });
    assert.equal(saved.workspace.pending.length, 1);
    results.push('Offline cash sale durably queued in SQLite');
    await application.close();
    ({ application, page } = await launch(profile));
    await page.getByRole('heading', { name: 'Sales terminal' }).waitFor();
    await page.getByRole('button', { name: 'Reconciliation', exact: true }).click();
    await page.getByRole('button', { name: 'Synchronize now', exact: true }).click();
    await page.waitForFunction(() => document.querySelector('.sync-status')?.textContent.includes('0 pending'));
    results.push('Installed app restarted with stored workspace and automatically synchronized pending sale');
    const transaction = saved.workspace.pending[0].transaction;
    const state = await apiCall('/bootstrap', undefined, saved.session.token);
    assert.equal(state.invoices.filter(item => item.transactionId === transaction.transactionId).length, 1);
    await apiCall('/sync', { deviceId: saved.workspace.device.id, transactions: [transaction] }, saved.session.token);
    const repeated = await apiCall('/bootstrap', undefined, saved.session.token);
    assert.equal(repeated.invoices.filter(item => item.transactionId === transaction.transactionId).length, 1);
    assert.deepEqual(repeated.stock, state.stock);
    results.push('Repeated synchronization produced exactly one invoice and no repeated stock deduction');
    fs.writeFileSync(path.join(output, 'results.json'), JSON.stringify({ passed: true, results }, null, 2));
    console.log(results.join('\n'));
  } catch (error) {
    console.error(error);
    await page.screenshot({ path: path.join(output, 'failure.png') }).catch(() => {});
    fs.writeFileSync(path.join(output, 'results.json'), JSON.stringify({ passed: false, results, error: error.message }, null, 2));
    process.exitCode = 1;
  } finally { await application.close().catch(() => {}); }
})();
