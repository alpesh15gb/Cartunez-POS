const { chromium } = require('playwright-core');
const assert = require('node:assert/strict');
const { randomUUID } = require('node:crypto');
const fs = require('node:fs');

(async () => {
  const api = process.env.MOTORLINE_TEST_API || 'http://127.0.0.1:4000/api/v1';
  const password = process.env.MOTORLINE_DEMO_PASSWORD || 'MotorlineDemo123!';
  let token;
  const call = async (path, body) => {
    const response = await fetch(api + path, {
      method: body ? 'POST' : 'GET',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token || ''}` },
      body: body ? JSON.stringify(body) : undefined,
    });
    const result = await response.json();
    assert.ok(response.ok, `${path}: ${JSON.stringify(result)}`);
    return result;
  };
  const login = await call('/auth/login', {email:'owner@motorline.local', password, branchId:'pune'});
  token = login.token;
  let state = await call('/bootstrap');
  const shift = state.shifts.find(item => item.userId === login.user.id && !item.closedAt)
    || await call('/shifts/open', {openingCash:0});
  const part = await call('/products', {
    name:'Fictional browser last-unit test', sku:`WEB-LAST-${randomUUID()}`, brand:'Fictional',
    partNumber:'LAST-UNIT', category:'Acceptance', unit:'Each', cost:5000,
    retailPrice:10000, wholesalePrice:10000, taxRate:1800, universal:true,
  });
  await call('/inventory/adjust', {productId:part.id, binId:'bin-a1', quantity:1, reason:'Isolated acceptance fixture'});
  const devices = [];
  for (let index=0; index<2; index++) devices.push(await call('/devices/enroll', {
    name:`Browser concurrency ${index}`, offlineAllowed:true, offlineHours:24, tenders:['Cash'], rangeSize:10,
  }));
  state = await call('/bootstrap');
  const sales = devices.map(device => ({
    transactionId:randomUUID(), deviceId:device.id, invoiceNumber:device.rangeStart,
    offline:true, occurredAt:new Date(Math.max(Date.now(), new Date(device.enrolledAt).getTime()+1000)).toISOString(), catalogRevision:state.catalogRevision,
    shiftId:shift.id, priceLevel:'retail', discount:0,
    lines:[{productId:part.id, qty:1, binId:'bin-a1'}],
    tenders:[{type:'Cash',amount:11800,confirmed:true}],
  }));
  const sync = sale => call('/sync', {deviceId:sale.deviceId, transactions:[sale]});
  const outcomes = (await Promise.all(sales.map(sync))).flatMap(item => item.results);
  assert.deepEqual(outcomes.map(item=>item.status).sort(), ['accepted','conflict']);
  const conflict = outcomes.find(item=>item.status==='conflict');
  const browser = await chromium.launch({
    executablePath:process.env.BROWSER_PATH || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe', headless:true,
  });
  try {
    const page = await browser.newPage();
    await page.goto(process.env.MOTORLINE_TEST_WEB || 'http://127.0.0.1:3000');
    await page.getByLabel('Server API', {exact:true}).fill(api);
    await page.getByLabel('Organization code', {exact:true}).fill('demo');
    await page.getByLabel('Branch code', {exact:true}).fill('pune');
    await page.getByLabel('Email', {exact:true}).fill('owner@motorline.local');
    await page.getByLabel('Password', {exact:true}).fill(password);
    await page.getByRole('button', {name:'Sign in',exact:true}).click();
    await page.getByRole('heading', {name:'Sales terminal'}).waitFor();
    await page.getByRole('navigation').getByRole('button', {name:'Reconciliation',exact:true}).click();
    const table = page.locator('table').filter({has:page.getByRole('columnheader',{name:'Conflict',exact:true})});
    const row = table.getByRole('row').filter({hasText:conflict.conflictId});
    await row.getByRole('button',{name:'Resolve',exact:true}).click();
    const dialog = page.locator('dialog');
    await dialog.locator('[name="action"]').selectOption('accept');
    await dialog.locator('[name="reason"]').fill('Physical count confirmed oversell; replenishment ordered.');
    await dialog.locator('[type="submit"]').click();
    await dialog.waitFor({state:'hidden'});
    assert.match(await row.innerText(), /accepted/);
    assert.equal(await row.getByRole('button',{name:'Resolve',exact:true}).count(), 0);
    const auditTable = page.locator('table').filter({has:page.getByRole('columnheader',{name:'Action',exact:true})});
    assert.ok((await auditTable.innerText()).includes('Physical count confirmed oversell; replenishment ordered.'));
    const retries = (await Promise.all(sales.map(sync))).flatMap(item=>item.results);
    assert.ok(retries.every(item=>item.status==='accepted'));
    state = await call('/bootstrap');
    assert.equal(state.stock.find(item=>item.productId===part.id && item.binId==='bin-a1').quantity,-1);
    for (const sale of sales) assert.equal(state.invoices.filter(item=>item.transactionId===sale.transactionId).length,1);
    assert.equal(state.audit.filter(item=>item.subject===conflict.conflictId && item.action==='conflict-resolution').length,1);
    fs.mkdirSync('docs/test-results',{recursive:true});
    fs.writeFileSync('docs/test-results/browser-conflict.json',JSON.stringify({
      passed:true, concurrentDevices:2, initialQuantity:1, initialOutcomes:['accepted','conflict'],
      managerDecisionThroughBrowser:'accepted', resolvedActionHidden:true,
      finalQuantity:-1, invoicesPerTransaction:1, resolutionAuditEntries:1,
    },null,2)+'\n');
    console.log('PASS browser manager reconciliation: two-counter last-unit conflict, audited acceptance, no repeated action, idempotent replay.');
  } finally { await browser.close(); }
})().catch(error=>{console.error(error);process.exitCode=1;});
