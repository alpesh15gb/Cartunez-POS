const assert = require('node:assert/strict');
const fs = require('node:fs');
const { connectPage } = require('./android-bridge.cjs');
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const adb = process.argv[2];
const output = process.argv[3] || 'work/production-android';

(async () => {
  const page = await connectPage(adb);
  const evaluate = expression => page.evaluate(expression);
  const wait = async expression => {
    for (let attempt = 0; attempt < 100; attempt++) {
      if (await evaluate(expression)) return;
      await pause(200);
    }
    throw new Error(`Condition not reached: ${expression}\n${await evaluate('document.body.innerText')}`);
  };
  const click = async (text, selector = 'button') => {
    await evaluate(`(() => {const button = [...document.querySelectorAll(${JSON.stringify(selector)})].find(button => button.textContent.trim() === ${JSON.stringify(text)}); if(!button) throw new Error('Missing button ${text}'); button.click();})()`);
    await pause(100);
  };
  const fill = async (name, value) => evaluate(`(() => {const element = document.querySelector('[name="${name}"]'); Object.getOwnPropertyDescriptor(Object.getPrototypeOf(element),'value').set.call(element,${JSON.stringify(value)}); element.dispatchEvent(new Event('input',{bubbles:true})); element.dispatchEvent(new Event('change',{bubbles:true}));})()`);
  const submit = async () => {
    await evaluate("document.querySelector('dialog[open] form').requestSubmit()");
    await wait("!document.querySelector('dialog[open]') || Boolean(document.querySelector('.receipt'))");
  };
  const snapshot = () => evaluate("(async()=>{const s=JSON.parse(await window.motorlineNative.get('active-session'));return JSON.parse(await window.motorlineNative.get('server:'+new URL(s.api).href.replace(/[/]$/,'')+':org:'+s.organizationId+':branch:'+s.branchId+':user:'+s.user.id)).snapshot;})()");
  const scan = async code => {
    await evaluate(`(() => {const input = document.querySelector('#global-search'); Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(input,${JSON.stringify(code)});input.dispatchEvent(new Event('input',{bubbles:true}));})()`);
    await pause(100);
    await evaluate("document.querySelector('#global-search').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}))");
    await wait("Boolean(document.querySelector('dialog[open]'))");
  };
  const buttonInRow = async (match, button) => {
    await evaluate(`(() => {const row = [...document.querySelectorAll('tbody tr')].find(row=>row.textContent.includes(${JSON.stringify(match)}));if(!row) throw new Error('Missing row');[...row.querySelectorAll('button')].find(button=>button.textContent===${JSON.stringify(button)}).click();})()`);
    await pause(100);
  };
  try {
    await wait("Boolean(document.querySelector('.app-shell'))");
    const suffix = Date.now();
    const sku = `ANDROID-${suffix}`;
    const name = `Android Filter ${suffix}`;
    await click('Inventory', '.nav-link');
    await click('Add part');
    for (const [key, value] of Object.entries({name,sku,brand:'Fictional Parts',category:'Filters',partNumber:`AD ${suffix}-A`,barcodes:sku,cost:'50',retailPrice:'100',wholesalePrice:'90',taxRate:'18'})) await fill(key,value);
    await submit();
    const product = (await snapshot()).products.find(product => product.sku === sku);
    assert.ok(product);
    await click('Fitment','.nav-link');
    await click('Add fitment rule');
    for (const [key,value] of Object.entries({productId:product.id,make:'Maruti Suzuki',model:'Swift',engine:'1.2L',fuel:'Petrol',yearFrom:'2020',yearTo:'2025',source:'Fictional Android acceptance catalog'})) await fill(key,value);
    await submit();
    await click('Purchasing','.nav-link');
    await click('New purchase order');
    for (const [key,value] of Object.entries({supplierId:'supplier-1',productId:product.id,quantity:'10',cost:'50'})) await fill(key,value);
    await submit();
    const order = (await snapshot()).purchaseOrders.find(order=>order.lines.some(line=>line.productId===product.id));
    for (const [bin, quantity] of [['bin-a1','6'],['bin-a2','4']]) {
      await buttonInRow(order.number || order.id,'Receive stock');
      for (const [key,value] of Object.entries({productId:product.id,quantity,binId:bin})) await fill(key,value);
      await submit();
    }
    await click('Locations','.nav-link');
    await click('Move stock');
    for(const [key,value] of Object.entries({productId:product.id,quantity:'2',fromBinId:'bin-a2',toBinId:'bin-b1',reason:'Android acceptance shelf move'})) await fill(key,value);
    await submit();
    let data=await snapshot();
    assert.equal(data.stock.find(item=>item.productId===product.id && item.binId==='bin-b1').quantity,2);
    await click('Billing','.nav-link');
    await evaluate("document.querySelector('.vehicle-picker').click()");
    await fill('preset','swift');
    await submit();
    await scan('ML-SPARK-01');
    assert.match(await evaluate("document.querySelector('dialog').innerText"),/incompatible fitment/);
    await fill('overrideReason','Manager test of explicitly incompatible replacement');
    await submit();
    assert.match(await evaluate("document.querySelector('.cart-lines').innerText"),/incompatible.*override recorded/);
    await evaluate("document.querySelector('[aria-label=\"Remove Iridium Spark Plug\"]').click()");
    await scan('ML-BELT-01');
    assert.match(await evaluate("document.querySelector('dialog').innerText"),/unverified fitment/);
    await click('Cancel','dialog button');
    await scan(sku);
    await fill('binId','bin-b1');
    await submit();
    await click('Checkout ↗');
    await submit();
    await wait("Boolean(document.querySelector('.receipt'))");
    const invoiceNumber=await evaluate("document.querySelector('.receipt h2').textContent");
    assert.match(await evaluate("document.querySelector('.receipt').textContent"),/118\.00/);
    await click('Done');
    let invoice;
    for (let attempt = 0; attempt < 50 && !invoice; attempt++) {
      data=await snapshot();
      invoice=data.invoices.find(item=>item.number===invoiceNumber);
      if (!invoice) await pause(100);
    }
    assert.ok(invoice, `Finalized receipt ${invoiceNumber} must persist to native SQLite.`);
    assert.equal(data.stock.find(item=>item.productId===product.id && item.binId==='bin-b1').quantity,1);
    await click('Sales history','.nav-link');
    await buttonInRow(invoiceNumber,'Return');
    for(const [key,value] of Object.entries({lineId:invoice.lines[0].id,quantity:'1',condition:'damaged',binId:'bin-damaged',reason:'Android acceptance damaged item'})) await fill(key,value);
    await submit();
    data=await snapshot();
    assert.equal(data.stock.find(item=>item.productId===product.id && item.binId==='bin-damaged').quantity,1);
    const returned=data.returns.find(item=>item.invoiceId===invoice.id);
    assert.equal(returned.total,11800);
    await click('Reports','.nav-link');
    await click('Run report');
    await wait("[...document.querySelectorAll('button')].some(button=>button.textContent==='Export CSV')");
    fs.mkdirSync(output,{recursive:true});
    fs.writeFileSync(`${output}/operations.json`,JSON.stringify({passed:true,sku,invoiceNumber,returnId:returned.id,checks:['Create part','Manual fictional fitment','Purchase order','Two partial receipts into separate bins','Shelf move','Incompatible approved override','Distinct unverified fitment','Keyboard barcode search','Compatible bin pick and checkout','Damaged return bin and exact refund','Reporting drilldown']},null,2));
    console.log('PASS Android catalog, fitment, purchasing/partial receipts, bin move, approval statuses, sale, return and reports.');
  } finally {page.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
