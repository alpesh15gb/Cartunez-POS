import {test} from 'node:test';
import assert from 'node:assert/strict';
import {quote} from '../app/storage';

const products=[{id:'part',retailPrice:10000,wholesalePrice:9000,taxRate:1800,coreCharge:0}];
const cart={lines:[{productId:'part',qty:1}],priceLevel:'retail',discount:0};
test('exclusive and inclusive prices keep exact tax and cash totals',()=>{
  const exclusive=quote(cart,products,1,'exclusive');
  assert.equal(exclusive.tax,1800);assert.equal(exclusive.total,11800);
  const inclusive=quote(cart,products,1,'inclusive');
  assert.equal(inclusive.tax,1525);assert.equal(inclusive.total,10000);
  const discounted=quote({...cart,discount:1180},[{...products[0],retailPrice:11800,coreCharge:500}],1,'inclusive');
  assert.equal(discounted.tax,1620);assert.equal(discounted.total,11120);
});
test('proportional discount allocation preserves the requested discount',()=>{
  const result=quote({...cart,lines:[{productId:'part',qty:1},{productId:'part',qty:2}],discount:101},products,100,'inclusive');
  assert.equal(result.lines.reduce((sum:number,line:any)=>sum+line.discount,0),101);
  assert.equal(result.total,29900);assert.equal(result.rounding,1);
});
test('out-of-range quantities and money fail before offline persistence',()=>{
  assert.throws(()=>quote({...cart,lines:[{productId:'part',qty:1.5}]},products),/whole number/);
  assert.throws(()=>quote({...cart,lines:[{productId:'part',qty:9999}]},[{...products[0],retailPrice:100000000000}]),/supported amount/);
  assert.throws(()=>quote(cart,products,0),/rounding/);
});
