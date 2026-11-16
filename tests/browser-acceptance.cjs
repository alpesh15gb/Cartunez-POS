const { chromium } = require('playwright-core');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const output = process.env.TEST_OUTPUT || path.resolve('test-results/browser');
fs.mkdirSync(output,{recursive:true});

(async () => {
 const browser = await chromium.launch({ executablePath:process.env.BROWSER_PATH || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe', headless:true });
 const context = await browser.newContext({viewport:{width:1440,height:1000},ignoreHTTPSErrors:true});
 const page = await context.newPage();
 const errors=[];
 page.on('pageerror',error=>errors.push(error.message));
 const dialog=page.locator('dialog');
 const submit=()=>dialog.locator('button[type="submit"]').click();
 const nav=async name=>{const [area,tab]=({'Sales history':['Sales','Invoices'],Shifts:['Sales','Shifts'],Locations:['Inventory','Bins'],Reconciliation:['Settings','Sync & audit']})[name]||[name];await page.getByRole('navigation').getByRole('button',{name:area,exact:true}).click();if(tab)await page.getByRole('tab',{name:tab,exact:true}).click();};
 const field=(name,value)=>dialog.locator(`[name="${name}"]`).fill(value);
 try {
  await page.goto(process.env.MOTORLINE_TEST_WEB || 'http://127.0.0.1:3000');
  await page.getByLabel('Server API',{exact:true}).fill(process.env.MOTORLINE_TEST_API || 'http://127.0.0.1:4000/api/v1');
  await page.getByLabel('Organization code',{exact:true}).fill('demo');
  await page.getByLabel('Branch code',{exact:true}).fill('pune');
  await page.getByLabel('Email',{exact:true}).fill('owner@motorline.local');
  await page.getByLabel('Password',{exact:true}).fill('MotorlineDemo123!');
  await page.getByRole('button',{name:'Sign in',exact:true}).click();
  await page.getByRole('heading',{name:'Sales terminal'}).waitFor();
  await page.screenshot({path:path.join(output,'register.png')});
  await nav('Shifts');
  if(await page.getByRole('button',{name:'Close shift'}).count()===0){
   await page.getByRole('button',{name:'Open shift',exact:true}).click();await field('openingCash','1000');await submit();await dialog.waitFor({state:'hidden'});
  }
  await nav('Inventory');
  await page.getByRole('button',{name:'Add part',exact:true}).click();
  const sku=`E2E-${Date.now()}`;
  for(const [name,value] of Object.entries({name:'Acceptance Cabin Filter',sku,brand:'Fictional Parts',category:'Filters',partNumber:'CAB-100 A',barcodes:sku,cost:'50',retailPrice:'100',wholesalePrice:'90',taxRate:'18'}))await field(name,value);
  await dialog.locator('[name="universal"]').selectOption('true');
  await submit();await dialog.waitFor({state:'hidden'});
  await nav('Purchasing');
  await page.getByRole('button',{name:'New purchase order',exact:true}).click();
  await dialog.locator('[name="supplierId"]').selectOption('supplier-1');
  await dialog.locator('[name="productId"]').selectOption({label:`${sku} · Acceptance Cabin Filter`});
  await field('quantity','4');await field('cost','50');await submit();await dialog.waitFor({state:'hidden'});
  for(const bin of ['bin-a1','bin-a2']){
   await page.getByRole('row').filter({hasText:'Acceptance Cabin Filter'}).first().getByRole('button',{name:'Receive stock'}).click();
   await dialog.locator('[name="productId"]').selectOption({index:1});
   await field('quantity','2');await dialog.locator('[name="binId"]').selectOption(bin);await submit();await dialog.waitFor({state:'hidden'});
  }
  await nav('Inventory');
  await page.getByRole('button',{name:'Adjust stock',exact:true}).click();
  await dialog.locator('[name="productId"]').selectOption({label:`${sku} · Acceptance Cabin Filter`});
  await dialog.locator('[name="binId"]').selectOption('bin-a1');await field('quantity','10');await field('reason','Acceptance opening stock');await submit();await dialog.waitFor({state:'hidden'});
  await nav('Locations');await page.getByRole('button',{name:'Move stock',exact:true}).click();
  await dialog.locator('[name="productId"]').selectOption({label:`${sku} · Acceptance Cabin Filter`});
  await dialog.locator('[name="fromBinId"]').selectOption('bin-a1');await dialog.locator('[name="toBinId"]').selectOption('bin-a2');await field('quantity','3');await field('reason','Shelf move');await submit();await dialog.waitFor({state:'hidden'});
  await nav('Billing');await page.locator('#global-search').fill(sku);await page.locator('#global-search').press('Enter');
  await dialog.locator('[name="binId"]').selectOption('bin-a2');await submit();await dialog.waitFor({state:'hidden'});
  await page.getByRole('button',{name:'Checkout'}).click();await submit();
  await dialog.getByRole('button',{name:'Print / Save PDF'}).waitFor();
  assert.match(await dialog.innerText(),/118\.00/);
  const invoiceNumber=await dialog.locator('h2').innerText();
  await page.pdf({path:path.join(output,'receipt.pdf'),format:'A4'});
  await dialog.getByRole('button',{name:'Done',exact:true}).click();
  await nav('Sales history');
  await page.getByRole('row').filter({hasText:invoiceNumber}).getByRole('button',{name:'Return',exact:true}).click();
  await dialog.locator('[name="lineId"]').selectOption({index:1});
  await dialog.locator('[name="condition"]').selectOption('damaged');
  await dialog.locator('[name="binId"]').selectOption('bin-damaged');
  await field('reason','Damaged part acceptance test');await submit();await dialog.waitFor({state:'hidden'});
  await nav('Settings');await page.getByRole('button',{name:'Enroll counter',exact:true}).click();await submit();await dialog.waitFor({state:'hidden'});
  await nav('Billing');await page.locator('#global-search').fill(sku);await page.locator('#global-search').press('Enter');await submit();await dialog.waitFor({state:'hidden'});
  await context.setOffline(true);
  await page.waitForTimeout(200);
  await page.getByRole('button',{name:'Checkout'}).click();await submit();await dialog.getByRole('button',{name:'Done',exact:true}).click();
  await page.waitForTimeout(600);
  await page.reload();await page.getByRole('heading',{name:'Sales terminal'}).waitFor();
  assert.match(await page.locator('.sync-status').innerText(),/1 pending/);
  await context.setOffline(false);await nav('Reconciliation');await page.getByRole('button',{name:'Synchronize now',exact:true}).click();
  await page.waitForFunction(()=>document.querySelector('.sync-status').textContent.includes('0 pending'),{timeout:20000});
  await nav('Billing');
  await page.getByRole('button',{name:/Vehicle fitment/}).click();
  await dialog.locator('[name="preset"]').selectOption('swift');await submit();await dialog.waitFor({state:'hidden'});
  await page.locator('#global-search').fill('ML-SPARK-01');await page.locator('#global-search').press('Enter');
  assert.match(await dialog.innerText(),/incompatible fitment/i);
  await page.getByRole('button',{name:'Close dialog',exact:true}).click();
  await page.locator('#global-search').fill('ML-BELT-01');await page.locator('#global-search').press('Enter');
  assert.match(await dialog.innerText(),/unverified fitment/i);
  await page.getByRole('button',{name:'Close dialog',exact:true}).click();
  await nav('Reports');await page.getByRole('button',{name:'Run report',exact:true}).click();await page.getByRole('button',{name:'Export CSV',exact:true}).waitFor();
  await page.setViewportSize({width:390,height:844});
  await page.screenshot({path:path.join(output,'mobile.png'),fullPage:false});
  assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
  assert.deepEqual(errors,[]);
  const summary='PASS browser real PostgreSQL API: sign-in, shift, create part, purchase order/partial two-bin receipt, bin stock and move, scan, pick, checkout/receipt, invoice return to damaged bin, enrollment, offline checkout/reload, sync, incompatible/unverified fitment, report.\n';
  fs.writeFileSync(path.join(output,'result.txt'),summary);console.log(summary);
 } catch(error){await page.screenshot({path:path.join(output,'failure.png'),fullPage:true});console.error('PAGE',await page.locator('body').innerText());throw error;}
 finally {await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
