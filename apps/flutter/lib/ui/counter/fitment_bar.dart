import 'package:flutter/material.dart';

import '../../main.dart';
import '../shell.dart';
import 'counter_actions.dart';
import 'vehicle_chip.dart';

/// Counter header: title, vehicle (fitment) chip, shift hint and category chips.
/// The part search itself lives in the shell's top bar ([ShellController.search]).
class FitmentBar extends StatelessWidget {
  const FitmentBar({super.key, required this.categories, required this.current, required this.onCategory});
  final List<String> categories;
  final String current;
  final ValueChanged<String> onCategory;

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
      Text(app.openShift == null ? 'Open a shift to start selling.' : 'Scan or pick parts, then take payment.',
          style: Theme.of(context).textTheme.bodySmall),
      if (app.openShift == null)
        Align(alignment: Alignment.centerLeft, child: TextButton.icon(
          onPressed: () => shell.open('shifts'), icon: const Icon(Icons.point_of_sale), label: const Text('Go to shifts'),
        )),
      const SizedBox(height: 16),
      SizedBox(
        height: 38,
        child: ListView(scrollDirection: Axis.horizontal, children: [
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
