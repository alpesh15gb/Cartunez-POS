const assert = require('node:assert/strict');
const { randomUUID, randomBytes } = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright-core');
const { createFreshEnvironment } = require('./fresh-install-environment.cjs');

(async () => {
  const installation = await createFreshEnvironment();
  const output = process.env.TEST_OUTPUT || path.resolve(__dirname, '../docs/test-results');
  let browser;
  let page;
  let token;
  const checks = [];
  const call = async (route, body, expected = 200, bearer = token) => {
    const response = await fetch(installation.apiBase + route, {
      method: body ? 'POST' : 'GET', headers: { 'Content-Type': 'application/json', ...(bearer ? { Authorization: `Bearer ${bearer}` } : {}) },
      body: body ? JSON.stringify(body) : undefined,
    });
    const data = await response.json();
    assert.equal(response.status, expected, `${route}: ${JSON.stringify(data)}`);
    return data;
  };
  const eventually = async predicate => {
    for (let attempt = 0; attempt < 80; attempt++) {
      const result = await predicate();
      if (result) return result;
      await new Promise(resolve => setTimeout(resolve, 200));
    }
    throw new Error('Expected fresh-install state did not arrive.');
  };
  try {
    const auth = await call('/auth/login', installation.credentials);
    token = auth.token;
    let state = await call('/bootstrap');
    assert.equal(state.organization.id, installation.credentials.organizationId);
    assert.equal(state.branches.length, 1);
    for (const key of ['products', 'locations', 'suppliers', 'customers', 'vehicles', 'invoices', 'stock', 'purchaseOrders', 'devices']) assert.equal(state[key].length, 0, `Production bootstrap must have no demo ${key}.`);
    await call('/auth/login', { organizationId: 'demo', branchId: 'pune', email: 'owner@motorline.local', password: 'MotorlineDemo123!' }, 401, null);
    checks.push('Real isolated PostgreSQL production bootstrap, first owner and empty data; demo login absent');

    browser = await chromium.launch({ executablePath: process.env.BROWSER_PATH || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe', headless: true });
    const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
    page = await context.newPage();
    page.setDefaultTimeout(15000);
    const pageErrors = [];
    page.on('pageerror', error => pageErrors.push(error.message));
    const dialog = page.locator('dialog');
    const nav = name => page.getByRole('navigation').getByRole('button', { name, exact: true }).click();
    const button = name => page.getByRole('button', { name, exact: true });
    const field = (name, value) => dialog.locator(`[name="${name}"]`).fill(value);
    const select = (name, value) => dialog.locator(`[name="${name}"]`).selectOption(value);
    const save = async () => {
      await dialog.locator('button[type="submit"]').click();
      await Promise.race([
        dialog.waitFor({ state: 'hidden' }),
        dialog.locator('.form-error').waitFor({ state: 'visible' }).then(async () => { throw new Error(`UI save rejected: ${await dialog.locator('.form-error').innerText()}`); }),
      ]);
    };
    const loginUi = async password => {
      for (const [name, value] of Object.entries({ api: installation.apiBase, organizationId: installation.credentials.organizationId, branchId: installation.credentials.branchId, email: installation.credentials.email, password })) await page.locator(`[name="${name}"]`).fill(value);
      await button('Sign in').click();
      await page.locator('.app-shell').waitFor();
      await nav('Billing');
      await page.getByRole('heading', { name: 'Sales terminal', exact: true }).waitFor();
    };
    await page.goto(installation.webBase);
    await loginUi(installation.credentials.password);
    await nav('Settings');
    await page.getByText('Complete your business details', { exact: true }).waitFor();
    await button('Edit settings').click();
    for (const [name, value] of Object.entries({ currency: 'USD', invoicePrefix: 'FRESH', nextInvoice: '101', taxDisplayName: 'Acceptance Tax', taxRates: '0, 18', tenderTypes: 'Cash, UPI', offlineTenders: 'Cash' })) await field(name, value);
    await select('taxMode', 'exclusive');
    await save();
    state = await call('/bootstrap');
    assert.equal(state.settings.currency, 'USD');
    assert.deepEqual(state.settings.tenderTypes, ['Cash', 'UPI']);
    await button('Add branch').click();
    for (const [name, value] of Object.entries({ id: 'annex', name: 'Fictional Annex', address: '2 Acceptance Lane' })) await field(name, value);
    await save();
    assert.equal((await call('/bootstrap')).branches.length, 2);
    checks.push('Real browser login, empty setup guidance, configured initial currency/tax/tenders and added branch');

    await nav('Locations');
    const bins = {};
    for (const [label, kind] of [['Counter', 'sellable'], ['Returns', 'damaged']]) {
      await button('Add location').click();
      for (const [name, value] of Object.entries({ area: label, rack: 'A', shelf: '1', bin: '01' })) await field(name, value);
      await select('kind', kind); await save();
      bins[kind] = (await call('/bootstrap')).locations.find(item => item.area === label).id;
    }
    await nav('Suppliers'); await button('Add supplier').click();
    for (const [name, value] of Object.entries({ name: 'Fictional First Supplier', email: 'supplier@example.test', address: '3 Acceptance Lane', taxRegistrationId: 'TEST-SUPPLIER-TAX' })) await field(name, value);
    await save();
    const supplier = (await call('/bootstrap')).suppliers[0];
    await nav('Inventory'); await button('Add part').click();
    for (const [name, value] of Object.entries({ name: 'Fresh Fictional Filter', sku: 'FRESH-FILTER', brand: 'Fictional Parts', category: 'Filters', partNumber: 'FRESH-001', barcodes: 'FRESH-001', hsnSac: 'TEST-HSN', cost: '50', retailPrice: '100', wholesalePrice: '90', taxRate: '18' })) await field(name, value);
    await select('universal', 'true'); await save();
    const part = (await call('/bootstrap')).products[0];
    await nav('Purchasing'); await button('New purchase order').click();
    await select('supplierId', supplier.id); await select('productId', part.id);
    await field('quantity', '4'); await field('cost', '50'); await save();
    await button('Receive stock').click();
    await select('productId', part.id); await select('binId', bins.sellable); await field('quantity', '4'); await save();
    const stockQuantity = data => data.stock.find(item => item.productId === part.id && item.binId === bins.sellable)?.quantity;
    assert.equal(stockQuantity(await call('/bootstrap')), 4);
    await nav('Shifts'); await button('Open shift').click(); await field('openingCash', '100'); await save();
    const shift = (await call('/bootstrap')).shifts.find(item => !item.closedAt);
    const saleBody = { transactionId: randomUUID(), shiftId: shift.id, lines: [{ productId: part.id, binId: bins.sellable, qty: 1 }], tenders: [{ type: 'Cash', amount: 11800, confirmed: true }] };
    const missingProfile = await call('/invoices', saleBody, 409);
    assert.match(missingProfile.error, /legal business name and address/i);
    checks.push('Created first bins, supplier, part, purchase receipt and shift through UI; invoicing blocked until business profile complete');

    await nav('Settings'); await button('Business details').click();
    const profile = { legalName: 'Fictional Acceptance Legal Ltd', tradingName: 'Fictional Acceptance Shop', address: '1 Acceptance Lane\nTest City', taxRegistrationId: 'TEST-TAX-001', stateCode: 'TEST', phone: '0000000000', email: 'shop@example.test', branchName: 'Fictional Counter', branchAddress: 'Counter 1, Test City', receiptFooter: 'Fictional acceptance receipt only' };
    for (const [name, value] of Object.entries(profile)) await field(name, value);
    await save();
    state = await call('/bootstrap');
    assert.equal(state.settings.business.legalName, profile.legalName);
    assert.equal(state.branch.name, profile.branchName);
    const missingReference = await call('/invoices', { ...saleBody, transactionId: randomUUID(), tenders: [{ type: 'UPI', amount: 11800, confirmed: true, reference: '' }] }, 400);
    assert.match(missingReference.error, /reference/i);
    const addOne = async () => {
      await nav('Billing'); await button('Add Fresh Fictional Filter').click(); await select('binId', bins.sellable); await save();
      await page.getByRole('button', { name: 'Checkout' }).click();
    };
    await addOne();
    assert.equal(await dialog.locator('[name="tender"] option[value="Card"]').count(), 0);
    await dialog.locator('button[type="submit"]').click(); await dialog.locator('.receipt').waitFor();
    const invoiceNumber = await dialog.locator('.receipt h2').innerText();
    assert.match(await dialog.innerText(), /Fictional Acceptance Legal Ltd/);
    assert.match(await dialog.innerText(), /TEST-TAX-001/);
    assert.match(await dialog.innerText(), /118\.00/);
    fs.mkdirSync(output, { recursive: true });
    await page.screenshot({ path: path.join(output, 'fresh-production-receipt.png') });
    await button('Done').click();
    state = await eventually(async () => { const data = await call('/bootstrap'); return data.invoices.length === 1 && data; });
    const firstInvoice = state.invoices[0];
    assert.equal(firstInvoice.number, invoiceNumber);
    assert.equal(firstInvoice.currency, 'USD'); assert.equal(firstInvoice.total, 11800); assert.equal(firstInvoice.tax, 1800);
    assert.equal(firstInvoice.business.legalName, profile.legalName); assert.equal(firstInvoice.branch.name, profile.branchName);
    assert.equal(firstInvoice.business.address, profile.address);
    assert.equal(stockQuantity(state), 3);
    await call('/settings', { currency: 'EUR' }, 409);
    checks.push('Configured business identity and tax registration in Settings; exclusive USD100 plus tax18 invoice; manual UPI requires a reference');

    await nav('Settings'); await button('Edit settings').click(); await select('taxMode', 'inclusive'); await save();
    await addOne(); await select('tender', 'UPI'); await select('confirmed', 'no'); await save();
    await nav('Reconciliation'); await button('Confirm payment').waitFor();
    state = await call('/bootstrap'); assert.equal(state.invoices.length, 1); assert.equal(stockQuantity(state), 3);
    await button('Confirm payment').click(); await field('reference', 'FICTIONAL-MANUAL-UPI-001'); await save();
    state = await eventually(async () => { const data = await call('/bootstrap'); return data.invoices.length === 2 && data; });
    const secondInvoice = state.invoices.find(item => item.id !== firstInvoice.id);
    assert.equal(secondInvoice.total, 10000); assert.equal(secondInvoice.tax, 1525); assert.equal(secondInvoice.taxMode, 'inclusive');
    assert.equal(secondInvoice.tenders[0].reference, 'FICTIONAL-MANUAL-UPI-001'); assert.equal(stockQuantity(state), 2);
    checks.push('Inclusive USD100 invoice includes tax15.25; manual UPI remains pending without invoice/stock effect until operator reference confirmation');

    await nav('Settings'); await button('Business details').click();
    await field('legalName', 'Renamed Fictional Legal Ltd'); await field('branchName', 'Renamed Fictional Counter'); await field('address', '99 New Fictional Address'); await field('receiptFooter', 'Revised fictional receipt footer'); await save();
    await nav('Sales history'); await page.getByRole('row').filter({ hasText: invoiceNumber }).getByRole('button', { name: 'Receipt', exact: true }).click();
    const historicalReceipt = await dialog.innerText();
    assert.match(historicalReceipt, /Fictional Acceptance Legal Ltd/); assert.match(historicalReceipt, /Fictional Counter/); assert.doesNotMatch(historicalReceipt, /Renamed Fictional/); assert.match(historicalReceipt, /118\.00/); assert.match(historicalReceipt, /Fictional acceptance receipt only/); assert.doesNotMatch(historicalReceipt, /Revised fictional receipt footer/);
    await button('Done').click();
    state = await call('/bootstrap'); assert.deepEqual(state.invoices.find(item => item.id === firstInvoice.id).business, firstInvoice.business);
    checks.push('Historical receipt retains original business, branch, currency and tax snapshot after Settings changes');

    const replacementPassword = randomBytes(24).toString('base64url');
    await nav('Settings');
    await page.getByRole('row').filter({ hasText: installation.credentials.email }).getByRole('button', { name: 'Edit user', exact: true }).click();
    await field('password', replacementPassword); await dialog.locator('button[type="submit"]').click();
    await button('Sign in').waitFor();
    await call('/bootstrap', undefined, 401);
    await loginUi(replacementPassword);
    await installation.restart();
    await call('/auth/login', installation.credentials, 401, null);
    token = (await call('/auth/login', { ...installation.credentials, password: replacementPassword }, 200, null)).token;
    state = await call('/bootstrap');
    assert.equal(state.invoices.length, 2); assert.equal(state.products.length, 1); assert.equal(stockQuantity(state), 2);
    assert.equal(state.settings.business.legalName, 'Renamed Fictional Legal Ltd');
    assert.ok(state.users.every(user => !('passwordHash' in user)));
    assert.deepEqual(pageErrors, []);
    checks.push('Owner password edit revokes old sessions; restart preserves new credentials, business settings, invoices and stock without reseeding');
    fs.writeFileSync(path.join(output, 'fresh-production.json'), JSON.stringify({ passed: true, environment: 'Isolated PostgreSQL 17, NODE_ENV=production, SEED_DEMO=false; real Edge UI', isolatedDatabase: true, demoDatabaseUntouched: true, checks, verifiedMoney: { currency: 'USD', exclusiveTotal: 11800, exclusiveTax: 1800, inclusiveTotal: 10000, inclusiveTax: 1525 }, finalInvoices: 2, finalStock: 2, pageErrors }, null, 2) + '\n');
    const failureScreenshot = path.join(output, 'fresh-production-failure.png');
    if (fs.existsSync(failureScreenshot)) fs.unlinkSync(failureScreenshot);
    console.log('PASS fresh production installation: empty bootstrap, real Settings and stock setup, exclusive/inclusive money, manual payment confirmation, immutable receipt, owner rotation and restart.');
  } catch (error) {
    if (page) {
      fs.mkdirSync(output, { recursive: true });
      await page.screenshot({ path: path.join(output, 'fresh-production-failure.png') }).catch(() => {});
    }
    throw error;
  } finally {
    if (browser) await browser.close();
    await installation.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
