import {test} from 'node:test';
import assert from 'node:assert/strict';
import {barcodeFormat, gs1Valid, inStoreBarcode} from '../app/storage';

test('retail barcodes keep their packaging symbology', () => {
  assert.equal(gs1Valid('4006381333931'), true);
  assert.equal(gs1Valid('4006381333932'), false);
  assert.equal(barcodeFormat('4006381333931'), 'EAN13');
  assert.equal(barcodeFormat('036000291452'), 'UPC');
  assert.equal(barcodeFormat('96385074'), 'EAN8');
  assert.equal(barcodeFormat('4006381333932'), 'CODE128');
  assert.equal(barcodeFormat('ML-OIL-01'), 'CODE128');
});

test('in-store barcodes are valid, internal and unique', () => {
  const taken = new Set<string>();
  for (let index = 0; index < 500; index++) {
    const code = inStoreBarcode(taken);
    assert.match(code, /^2\d{12}$/);
    assert.equal(gs1Valid(code), true);
    assert.equal(taken.has(code), false);
    taken.add(code);
  }
});
