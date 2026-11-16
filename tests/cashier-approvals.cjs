const {chromium}=require('playwright-core');
const assert=require('node:assert/strict');
const fs=require('node:fs');
(async()=>{
 const base=process.env.MOTORLINE_TEST_API || 'http://127.0.0.1:4000/api/v1';
 const call=async(path,body,token)=>{
  const response=await fetch(base+path,{method:body?'POST':'GET',headers:{'Content-Type':'application/json',Authorization:`Bearer ${token||''}`},body:body?JSON.stringify(body):undefined});
  const result=await response.json();if(!response.ok)throw Error(JSON.stringify(result));return result;
 };
 const owner=await call('/auth/login',{email:'owner@motorline.local',password:'MotorlineDemo123!',branchId:'pune'});
 const original=(await call('/bootstrap',null,owner.token)).settings;
 const email=`cashier-${Date.now()}@example.test`;
 await call('/users',{name:'Cashier Acceptance',email,password:'CashierTesting123!',role:'cashier',branchIds:['pune'],active:true},owner.token);
 const browser=await chromium.launch({executablePath:process.env.BROWSER_PATH||'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',headless:true});
 try{
  await call('/settings',{cashierDiscountLimit:500},owner.token);
  const page=await browser.newPage();const dialog=page.locator('dialog');
  await page.goto(process.env.MOTORLINE_TEST_WEB || 'http://127.0.0.1:3000');await page.getByLabel('Server API',{exact:true}).fill(base);await page.getByLabel('Organization code',{exact:true}).fill('demo');await page.getByLabel('Branch code',{exact:true}).fill('pune');await page.getByLabel('Email',{exact:true}).fill(email);await page.getByLabel('Password',{exact:true}).fill('CashierTesting123!');await page.getByRole('button',{name:'Sign in',exact:true}).click();await page.getByRole('heading',{name:'Sales terminal'}).waitFor();
  await page.getByRole('navigation').getByRole('button',{name:'Sales',exact:true}).click();await page.getByRole('tab',{name:'Shifts',exact:true}).click();await page.getByRole('button',{name:'Open shift',exact:true}).click();await dialog.locator('[name="openingCash"]').fill('500');await dialog.locator('[type="submit"]').click();await dialog.waitFor({state:'hidden'});
  await page.getByRole('navigation').getByRole('button',{name:'Billing',exact:true}).click();await page.getByRole('button',{name:'Add Synthetic Engine Oil',exact:true}).click();await dialog.locator('[type="submit"]').click();await dialog.waitFor({state:'hidden'});
  await page.getByRole('button',{name:'Discount',exact:true}).click();await dialog.locator('[name="discount"]').fill('5');await dialog.locator('[name="reason"]').fill('Authorized cashier allowance');await dialog.locator('[type="submit"]').click();await dialog.waitFor({state:'hidden'});
  await page.getByRole('button',{name:'Checkout'}).click();await dialog.locator('[type="submit"]').click();await dialog.getByRole('button',{name:'Done',exact:true}).waitFor();const invoice=await dialog.locator('h2').innerText();await dialog.getByRole('button',{name:'Done',exact:true}).click();
  await page.getByRole('navigation').getByRole('button',{name:'Sales',exact:true}).click();await page.getByRole('tab',{name:'Invoices',exact:true}).click();await page.getByRole('row').filter({hasText:invoice}).getByRole('button',{name:'Return',exact:true}).click();
  const match=(await dialog.innerText()).match(/Approval transaction ([\w-]+)/);assert.ok(match,'Cashier must be able to supply return transaction ID to manager.');
  const approval=await call('/approvals',{action:'return',transactionId:match[1],reason:'Return authorized after inspection'},owner.token);
  await dialog.locator('[name="lineId"]').selectOption({index:1});await dialog.locator('[name="binId"]').selectOption('bin-a1');await dialog.locator('[name="reason"]').fill('Wrong quantity');await dialog.locator('[name="approvalId"]').fill(approval.id);await dialog.locator('[type="submit"]').click();await dialog.waitFor({state:'hidden'});
  const data=await call('/bootstrap',null,owner.token);const sale=data.invoices.find(item=>item.number===invoice);assert.equal(sale.discount,500);assert.ok(data.returns.some(item=>item.invoiceId===sale.id));
  fs.mkdirSync('docs/test-results',{recursive:true});fs.writeFileSync('docs/test-results/cashier-approvals.txt','PASS configurable cashier discount allowance and manager-approved invoice return through actual browser UI.\n');console.log('PASS cashier discount and return approval UI.');
 }finally{await call('/settings',{cashierDiscountLimit:original.cashierDiscountLimit},owner.token);await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
