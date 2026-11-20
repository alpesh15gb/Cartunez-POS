import 'package:cartunez_pos/core/api.dart';
import 'package:cartunez_pos/core/billing.dart';
import 'package:cartunez_pos/main.dart';
import 'package:cartunez_pos/state/app_state.dart';
import 'package:cartunez_pos/ui/screens/catalog_import.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Shop extends AppState {
  bool conflict = false;
  int previews = 0;
  final saves = <Json>[];

  @override
  Future<dynamic> api(String path, {Object? body, String? method}) async {
    expect(path, '/products/import/preview');
    previews++;
    return {'rows': [
      {'row': 2, 'sku': 'A1', 'name': 'Oil filter',
        if ((body as Map)['csv'] == 'bad') 'error': 'Duplicate barcode.' else 'retailPrice': 1230},
    ]};
  }

  @override
  Future<dynamic> mutate(String path, Json body, [String? message]) async {
    expect(path, '/products/import');
    if (conflict) throw ApiError('Preview again', 409);
    saves.add(body);
    return {'imported': 1};
  }
}

void main() {
  testWidgets('catalog preview invalidates edited and stale rows before saving', (tester) async {
    final app = _Shop();
    await tester.pumpWidget(AppScope(state: app, child: MaterialApp(home: Builder(builder: (context) =>
      Scaffold(body: TextButton(onPressed: () => importCatalog(context), child: const Text('Parts')))))));
    await tester.tap(find.text('Parts'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Preview')).onPressed, isNull);
    final csv = find.widgetWithText(TextField, 'CSV contents');
    await tester.enterText(csv, 'bad');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Duplicate barcode.'), findsOneWidget);
    expect(find.text('Import 1 part'), findsNothing);

    await tester.enterText(csv, 'first');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();
    expect(find.text('Import 1 part'), findsOneWidget);
    await tester.enterText(csv, 'corrected');
    await tester.pumpAndSettle();
    expect(find.text('Import 1 part'), findsNothing);
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();
    app.conflict = true;
    await tester.tap(find.text('Import 1 part'));
    await tester.pumpAndSettle();
    expect(find.text('Preview again'), findsOneWidget);
    expect(find.text('Import 1 part'), findsNothing);
    app.conflict = false;
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import 1 part'));
    await tester.pumpAndSettle();
    expect(app.saves.single['csv'], 'corrected');
    expect(app.saves.single['transactionId'], isNotEmpty);
    expect(find.text('Import new parts'), findsNothing);
    app.dispose();
  });
}
