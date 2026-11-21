// WS-D: People › Staff — staff accounts (owner) and counter PINs (owner, manager).
import 'package:flutter/material.dart';

import '../../core/billing.dart';
import '../../main.dart';
import '../screens/settings.dart' show editUser;
import '../widgets.dart';
import 'pin_counter.dart';

/// Whether the signed-in person may set [user]'s PIN.
bool canSetPin(String role, String selfId, Json user) {
  if (user['role'] == 'owner' || user['active'] == false) return false;
  if (role == 'owner') return true;
  if (role != 'manager') return false;
  return user['role'] != 'manager' || user['id'] == selfId;
}

class StaffScreen extends StatefulWidget {
  const StaffScreen({super.key});
  @override
  State<StaffScreen> createState() => _StaffScreenState();
}

class _StaffScreenState extends State<StaffScreen> {
  Json? counter;

  @override
  void initState() {
    super.initState();
    _loadCounter();
  }

  Future<void> _loadCounter() async {
    try {
      final value = await PinCounter.load();
      if (mounted) setState(() => counter = value);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final here = counter != null && counter!['organizationId'] == app.session?.organizationId;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Card(
        child: ListTile(
          leading: const Icon(Icons.dialpad),
          title: Text(here ? 'PIN sign-in is on for this counter (${counter!['deviceName']})' : 'PIN sign-in is off for this counter'),
          subtitle: const Text('Counter staff tap their name and enter a PIN. Lock the counter with Switch user (Ctrl+L or F11).'),
          trailing: !app.isManager
              ? null
              : here
                  ? OutlinedButton(
                      onPressed: () async {
                        await turnOffPinCounter(context, counter!);
                        await _loadCounter();
                      },
                      child: const Text('Turn off'))
                  : FilledButton(
                      onPressed: app.online
                          ? () async {
                              await setUpPinCounter(context);
                              await _loadCounter();
                            }
                          : null,
                      child: const Text('Turn on')),
        ),
      ),
      const SizedBox(height: 12),
      if (app.isOwner)
        Toolbar([
          FilledButton.icon(onPressed: () => editUser(context, const {}), icon: const Icon(Icons.add), label: const Text('Add staff')),
        ]),
      DataList(
        rows: app.list('users'),
        empty: 'No staff yet.',
        onTap: (u) => app.isOwner
            ? editUser(context, u)
            : canSetPin(app.role, app.session?.userId ?? '', u)
                ? editPin(context, u)
                : null,
        columns: [
          Col('Name', (u) => Text('${u['name']}', style: const TextStyle(fontWeight: FontWeight.w700))),
          if (app.isOwner) Col('Email', (u) => Text('${u['email']}'), flex: 2),
          Col('Role', (u) => Text(titleCase('${u['role']}'))),
          Col('PIN', (u) => Text(u['role'] == 'owner' ? 'Email only' : u['hasPin'] == true ? 'Set' : '—')),
          Col('Status', (u) => StatusChip(u['active'] == true ? 'Active' : 'Disabled')),
        ],
        actionWidth: 190,
        actions: (u) => [
          if (canSetPin(app.role, app.session?.userId ?? '', u))
            OutlinedButton(onPressed: () => editPin(context, u), child: Text(u['hasPin'] == true ? 'Change PIN' : 'Set PIN')),
          if (canSetPin(app.role, app.session?.userId ?? '', u) && u['hasPin'] == true)
            TextButton(onPressed: () => removePin(context, u), child: const Text('Remove')),
        ],
      ),
    ]);
  }
}
