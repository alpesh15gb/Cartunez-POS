import 'package:flutter/material.dart';

import '../../main.dart';
import '../shell.dart';
import '../shift/shift_dialogs.dart' show showOpenShiftDialog;
import 'counter_actions.dart';
import 'vehicle_chip.dart';

/// Counter header: title, vehicle (fitment) chip, shift hint and category chips.
/// The part search itself lives in the shell's top bar ([ShellController.search]).
class FitmentBar extends StatelessWidget {
  const FitmentBar({
    super.key,
    required this.categories,
    required this.current,
    required this.onCategory,
    this.hiddenByFitment = 0,
    this.showAllFitment = false,
    this.onToggleFitment,
  });
  final List<String> categories;
  final String current;
  final ValueChanged<String> onCategory;
  final int hiddenByFitment;
  final bool showAllFitment;
  final VoidCallback? onToggleFitment;

  @override
  Widget build(BuildContext context) {
    final app = context.appRead;
    final shell = ShellScope.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: Text('Sales terminal', style: Theme.of(context).textTheme.headlineMedium)),
        if (app.feature('fitment')) VehicleChip(onTap: () => chooseVehicle(context)),
      ]),
      const SizedBox(height: 4),
      // QA #6: the shift opens right here (no trip to Shifts); focus goes back to item search.
      ListenableBuilder(
        listenable: app,
        builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(app.openShift == null ? 'Open a shift to start selling.' : 'Scan or pick parts, then take payment.',
              style: Theme.of(context).textTheme.bodySmall),
          if (app.openShift == null && app.canSell)
            Align(alignment: Alignment.centerLeft, child: TextButton.icon(
              key: const ValueKey('counter-open-shift'),
              onPressed: app.online ? () => openShiftFromCounter(context, shell) : null,
              icon: const Icon(Icons.lock_open),
              label: const Text('Open shift'),
            )),
        ]),
      ),
      const SizedBox(height: 16),
      SizedBox(
        height: 38,
        child: ListView(scrollDirection: Axis.horizontal, children: [
          if ((hiddenByFitment > 0 || showAllFitment) && onToggleFitment != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: Text(showAllFitment ? 'Fits vehicle only' : 'Show all ($hiddenByFitment hidden)'),
                selected: showAllFitment,
                onSelected: (_) => onToggleFitment!(),
              ),
            ),
          for (final c in categories)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(c),
                selected: c == current,
                onSelected: (_) => onCategory(c),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 14),
    ]);
  }
}

/// Opens the shift inline from the Counter, then puts the cursor back in item search.
Future<bool> openShiftFromCounter(BuildContext context, ShellController shell) async {
  final opened = await showOpenShiftDialog(context);
  if (opened) shell.searchFocus.requestFocus();
  return opened;
}
