part of 'app_state.dart';

/// The cashier's shift and the drawer: the open shift, cash movements and the
/// cash expected at close. Notifies when the snapshot or signed-in cashier changes.
class ShiftState extends ChangeNotifier {
  ShiftState._(this._app);
  final AppState _app;

  void _touch() => notifyListeners();

  List<Json> get shifts => _app.syncState.list('shifts');

  Json? get openShift {
    for (final shift in shifts) {
      if (shift['closedAt'] == null && shift['userId'] == _app.session?.userId) return shift;
    }
    return null;
  }

  /// Paid in / paid out of the drawer during [shift].
  List<Json> cashMovements(Json shift) =>
      _app.syncState.list('cashMovements').where((m) => m['shiftId'] == shift['id']).toList();

  int expectedCash(Json shift) {
    final list = _app.syncState.list;
    var cash = (shift['openingCash'] ?? 0) as int;
    for (final sale in list('invoices').where((i) => i['shiftId'] == shift['id'])) {
      for (final t in sale['tenders'] as List) {
        if (t['type'] == 'Cash') cash += t['amount'] as int;
      }
      cash -= (sale['change'] ?? 0) as int;
    }
    for (final refund in [...list('returns'), ...list('coreReturns')]) {
      if (refund['shiftId'] == shift['id'] && (refund['refundType'] ?? 'Cash') == 'Cash') {
        // WS-B: an exchange credit note pays back only its refundTotal.
        cash -= (refund['refundTotal'] ?? refund['total'] ?? 0) as int;
      }
    }
    for (final movement in cashMovements(shift)) {
      final amount = movement['amount'] as int;
      cash += movement['direction'] == 'in' ? amount : -amount;
    }
    for (final payment in list('partyPayments').where((p) => p['shiftId'] == shift['id'] && p['mode'] == 'Cash' && p['voided'] != true)) {
      final amount = (payment['amount'] as num).toInt();
      cash += payment['direction'] == 'in' ? amount : -amount;
    }
    return cash;
  }
}
