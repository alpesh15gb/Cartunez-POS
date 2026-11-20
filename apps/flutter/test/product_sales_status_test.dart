import 'package:cartunez_pos/core/billing.dart';
import 'package:cartunez_pos/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('stopped parts remain scannable for inventory and block stale cart checkout', () {
    final app = AppState();
    final stopped = {'id': 'one', 'sku': 'ONE', 'barcodes': ['036000291452'], 'salesStopped': true};
    final available = {'id': 'two', 'sku': 'TWO', 'barcodes': ['active'], 'supplierReferences': ['0036000291452', 'ONE']};
    app.snapshot['products'] = [stopped, available];
    expect(app.saleProducts, [available]);
    expect(app.findByCode('0036000291452'), [stopped]);
    expect(app.findByCode('0036000291452', forSale: true), isEmpty);
    expect(app.findByCode('ONE', forSale: true), isEmpty);
    expect(app.findByCode('active', forSale: true), [available]);
    final cart = {'lines': [{'productId': 'one', 'qty': 1}]};
    expect(() => quote(cart, app.products), throwsA(isA<BillingError>()));
    stopped.remove('salesStopped');
    expect(app.findByCode('036000291452', forSale: true), [stopped]);
    expect(quote(cart, app.products).lines, hasLength(1));
    app.dispose();
  });
}
