import 'package:flutter/material.dart';

import '../../main.dart';
import '../shell.dart';
import '../widgets.dart';

Future<void> showParked(BuildContext context, ShellController shell) async {
  final app = context.appRead;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => AppScope(
      state: app,
      child: Builder(builder: (context) {
        final holds = context.app.list('holds');
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: ListView(shrinkWrap: true, children: [
              Text('Parked sales', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 10),
              if (holds.isEmpty)
                const EmptyState(message: 'No parked sales. Use Hold to park a sale and reserve its stock.')
              else
                for (final hold in holds)
                  Card(
                    child: ListTile(
                      title: Text('${app.customerById('${hold['cart']['customerId']}')?['name'] ?? 'Walk-in customer'}'),
                      subtitle: Text(
                        '${(hold['cart']['lines'] as List).map((l) => '${l['qty']} × ${app.productName('${l['productId']}')}').join(', ')}\n'
                        'Parked ${formatDate(hold['createdAt'])} by ${app.userName('${hold['userId']}')}',
                      ),
                      isThreeLine: true,
                      trailing: Wrap(spacing: 6, children: [
                        IconButton(
                          tooltip: 'Discard',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            try {
                              await app.api('/holds/${hold['id']}', method: 'DELETE');
                              await app.sync();
                              app.toast('Parked sale discarded. Stock released.');
                            } catch (error) {
                              app.toast(errorText(error));
                            }
                          },
                        ),
                        FilledButton(
                          onPressed: () {
                            if ((app.cart['lines'] as List).isNotEmpty) {
                              app.toast('Hold or clear the current sale first.');
                              return;
                            }
                            app.replaceCart({...Map<String, dynamic>.from(hold['cart'] as Map), 'holdId': hold['id']});
                            Navigator.pop(sheet);
                            shell.open('billing');
                          },
                          child: const Text('Resume'),
                        ),
                      ]),
                    ),
                  ),
            ]),
          ),
        );
      }),
    ),
  );
}
