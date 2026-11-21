// WS-C (workshop): kit (installation package) helpers for the part editor and lists.
import '../../core/billing.dart';
import '../../state/app_state.dart';
import '../widgets.dart';

bool isKit(Json? product) => (product?['components'] as List? ?? const []).isNotEmpty;

/// "ML-BRAKE-01 x1, ML-SERVICE-01 x1" for the part editor.
String kitComponentsText(AppState app, Json product) => [
      for (final c in (product['components'] as List? ?? const []))
        '${app.productById('${c['productId']}')?['sku'] ?? c['productId']} x${c['qty']}',
    ].join(', ');

/// Parses the editor text back into components; throws [FormProblem] with a plain message.
List<Json> parseKitComponents(AppState app, String value, String? selfId) {
  final result = <Json>[];
  for (final entry in value.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty)) {
    final match = RegExp(r'^(.+?)(?:\s*[x×*]\s*(\d+))?$', caseSensitive: false).firstMatch(entry);
    final code = match?.group(1)?.trim() ?? entry;
    final qty = int.tryParse(match?.group(2) ?? '1') ?? 0;
    if (qty < 1 || qty > 999) throw FormProblem('Use a quantity from 1 to 999 for $code.');
    final product = app.products.where((p) => normalize(p['sku']) == normalize(code)).firstOrNull ??
        app.findByCode(code).firstOrNull;
    if (product == null) throw FormProblem('No part with SKU or barcode $code. Check the kit components.');
    if (product['id'] == selfId) throw FormProblem('A kit cannot contain itself.');
    if (isKit(product)) throw FormProblem('${product['sku']} is a kit. List its parts directly.');
    if (product['serialTracked'] == true) throw FormProblem('${product['sku']} tracks serial numbers; sell it as its own line.');
    if (result.any((c) => c['productId'] == product['id'])) throw FormProblem('${product['sku']} is listed twice.');
    result.add({'productId': product['id'], 'qty': qty});
  }
  return result;
}

/// How many kits the components in stock can make (null when nothing in it is stocked).
int? kitAvailable(AppState app, Json kit) {
  int? result;
  for (final c in (kit['components'] as List? ?? const [])) {
    final part = app.productById('${c['productId']}');
    if (part == null || part['type'] == 'service') continue;
    final made = app.available('${c['productId']}') ~/ ((c['qty'] as num?)?.toInt() ?? 1);
    result = result == null ? made : (made < result ? made : result);
  }
  return result;
}
