const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright-core');
const { createFreshEnvironment } = require('./fresh-install-environment.cjs');

(async () => {
  const installation = await createFreshEnvironment();
  const output = process.env.TEST_OUTPUT || path.resolve(__dirname, '../docs/test-results');
  let browser, page, token;
  const call = async (route, body) => {
    const response = await fetch(installation.apiBase + route, { method: body ? 'POST' : 'GET', headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) }, body: body ? JSON.stringify(body) : undefined });
    const data = await response.json(); assert.equal(response.status, 200, JSON.stringify(data)); return data;
  };
  try {
    token = (await call('/auth/login', installation.credentials)).token;
    const initial = await call('/bootstrap');
    assert.equal(initial.settings.currency, 'INR'); assert.equal(initial.invoices.length, 0);
    const bin = await call('/locations', { area: 'Fictional Counter', rack: 'A', shelf: '1', bin: '01', kind: 'sellable' });
    const part = await call('/products', { name: 'Fictional GST Part', sku: 'GST-UI-001', brand: 'Fictional', partNumber: 'GST-001', category: 'Parts', unit: 'Each', cost: 5000, retailPrice: 10000, wholesalePrice: 9000, taxRate: 1800, universal: true, hsnSac: '8708' });
    await call('/inventory/adjust', { productId: part.id, binId: bin.id, quantity: 3, reason: 'Fictional fresh GST UI fixture' });
    await call('/shifts/open', { openingCash: 0 });
    browser = await chromium.launch({ executablePath: process.env.BROWSER_PATH || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe', headless: true });
    page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
    page.setDefaultTimeout(15000);
    const errors = []; page.on('pageerror', error => errors.push(error.message));
    const dialog = page.locator('dialog');
    const button = name => page.getByRole('button', { name, exact: true });
    const nav = async name => { const [area, tab] = ({'Sales history':['Sales','Invoices'],Shifts:['Sales','Shifts'],Locations:['Inventory','Bins'],Reconciliation:['Settings','Sync & audit']})[name] || [name]; await page.getByRole('navigation').getByRole('button', { name: area, exact: true }).click(); if (tab) await page.getByRole('tab', { name: tab, exact: true }).click(); };
    const field = (name, value) => dialog.locator(`[name="${name}"]`).fill(value);
    const select = (name, value) => dialog.locator(`[name="${name}"]`).selectOption(value);
    const save = async () => {
      await dialog.locator('button[type="submit"]').click();
      await Promise.race([dialog.waitFor({ state: 'hidden' }), dialog.locator('.form-error').waitFor({ state: 'visible' }).then(async () => { throw new Error(await dialog.locator('.form-error').innerText()); })]);
    };
    await page.goto(installation.webBase);
    for (const [name, value] of Object.entries({ api: installation.apiBase, ...installation.credentials })) await page.locator(`[name="${name}"]`).fill(value);
    await button('Sign in').click(); await page.locator('.app-shell').waitFor();
    await nav('Settings'); await button('Business details').click();
    for (const [name, value] of Object.entries({ legalName: 'Fictional GST Acceptance Ltd', tradingName: 'Fictional GST Shop', address: 'Fictional Street\nFictional City', taxRegistrationId: '27ABCDE1234F1Z5', stateCode: '27', branchName: 'Fictional GST Counter', branchAddress: 'Fictional Maharashtra Counter', branchStateCode: '27', receiptFooter: 'Fictional fixture; no real tax transaction' })) await field(name, value);
    await save();
    await button('Edit settings').click(); await dialog.locator('summary').click();
    for (const [name, value] of Object.entries({ currency: 'INR', invoicePrefix: 'GST', creditNotePrefix: 'GCR', taxDisplayName: 'GST', taxRates: '0, 18' })) await field(name, value);
    for (const tender of ['Card', 'UPI']) await dialog.locator(`[name="tenderTypes"][value="${tender}"]`).uncheck();
    await select('taxMode', 'exclusive'); await select('taxScheme', 'india-gst'); await select('localTaxName', 'SGST'); await save();
    let data = await call('/bootstrap');
    assert.equal(data.settings.taxScheme, 'india-gst'); assert.equal(data.settings.localTaxName, 'SGST'); assert.equal(data.settings.business.stateCode, '27'); assert.equal(data.branch.stateCode, '27'); assert.equal(data.settings.business.taxRegistrationId, '27ABCDE1234F1Z5');
    fs.mkdirSync(output, { recursive: true });
    const invoices = [];
    for (const place of ['27', '29']) {
      await nav('Billing'); await button('Add Fictional GST Part').click(); await select('binId', bin.id); await save();
      await page.getByRole('button', { name: 'Checkout' }).click();
      assert.equal(await dialog.locator('[name="placeOfSupply"]').getAttribute('required'), '');
      await field('placeOfSupply', place); await dialog.locator('button[type="submit"]').click(); await dialog.locator('.receipt').waitFor();
      const receipt = await dialog.innerText();
      assert.match(receipt, /Fictional GST Acceptance Ltd/); assert.match(receipt, /27ABCDE1234F1Z5/); assert.match(receipt, /8708/); assert.match(receipt, new RegExp(`Place of supply: ${place}`)); assert.match(receipt, /118\.00/);
      const number = await dialog.locator('.receipt h2').innerText();
      if (place === '27') {
        assert.equal(await dialog.locator('dt').filter({ hasText: /^CGST$/ }).count(), 1);
        assert.equal(await dialog.locator('dt').filter({ hasText: /^SGST$/ }).count(), 1);
        assert.equal(await dialog.locator('dt').filter({ hasText: /^IGST$/ }).count(), 0);
      } else {
        assert.equal(await dialog.locator('dt').filter({ hasText: /^IGST$/ }).count(), 1);
        assert.equal(await dialog.locator('dt').filter({ hasText: /^CGST$/ }).count(), 0);
      }
      await page.screenshot({ path: path.join(output, `fresh-gst-${place === '27' ? 'same-state' : 'interstate'}.png`) });
      await button('Done').click();
      data = await call('/bootstrap'); const invoice = data.invoices.find(item => item.number === number); assert.ok(invoice);
      assert.equal(invoice.currency, 'INR'); assert.equal(invoice.total, 11800); assert.equal(invoice.tax, 1800); assert.equal(invoice.placeOfSupply, place); assert.equal(invoice.lines[0].hsnSac, '8708');
      assert.deepEqual(invoice.taxComponents, place === '27' ? [{ name: 'CGST', amount: 900 }, { name: 'SGST', amount: 900 }] : [{ name: 'IGST', amount: 1800 }]);
      invoices.push(invoice);
    }
    await nav('Settings'); await button('Edit settings').click(); await select('taxScheme', 'general'); await dialog.locator('summary').click(); await field('taxDisplayName', 'Revised generic tax'); await save();
    await button('Business details').click(); await field('legalName', 'Changed Later Fictional Company'); await save();
    await nav('Sales history');
    for (const invoice of invoices) {
      await page.getByRole('row').filter({ hasText: invoice.number }).getByRole('button', { name: 'Receipt', exact: true }).click();
      const text = await dialog.innerText(); assert.match(text, /Fictional GST Acceptance Ltd/); assert.doesNotMatch(text, /Changed Later|Revised generic tax/);
      for (const component of invoice.taxComponents) await dialog.locator('dt').filter({ hasText: new RegExp(`^${component.name}$`) }).waitFor();
      assert.match(text, new RegExp(`Place of supply: ${invoice.placeOfSupply}`)); await button('Done').click();
    }
    data = await call('/bootstrap');
    assert.equal(data.stock.find(item => item.productId === part.id && item.binId === bin.id).quantity, 1); assert.equal(data.invoices.length, 2); assert.deepEqual(errors, []);
    fs.writeFileSync(path.join(output, 'fresh-gst-ui.json'), JSON.stringify({ passed: true, environment: 'Fresh isolated production PostgreSQL, real Edge UI, fictional INR GST fixtures', businessAndTaxConfiguredInUi: true, requiredPlaceOfSupply: true, hsn: '8708', retailPrice: 10000, taxRateBasisPoints: 1800, sameState: { state: '27', total: 11800, components: [{ name: 'CGST', amount: 900 }, { name: 'SGST', amount: 900 }] }, interstate: { state: '29', total: 11800, components: [{ name: 'IGST', amount: 1800 }] }, historicalReceiptSnapshotsAfterSettingsChange: true, finalStock: 1, pageErrors: errors }, null, 2) + '\n');
    console.log('PASS fresh INR GST UI: configured profile/schema, required place of supply, CGST9+SGST9 vs IGST18, HSN, receipt and reprint snapshots.');
  } catch (error) {
    if (page) { fs.mkdirSync(output, { recursive: true }); await page.screenshot({ path: path.join(output, 'fresh-gst-failure.png') }).catch(() => {}); }
    throw error;
  } finally { if (browser) await browser.close(); await installation.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
