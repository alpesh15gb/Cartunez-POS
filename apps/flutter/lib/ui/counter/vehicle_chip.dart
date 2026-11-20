import 'package:flutter/material.dart';

import '../../main.dart';

/// The vehicle the sale is for (fitment check). Listens only to the cart's
/// terms, so it updates when the vehicle changes and not on every scan.
class VehicleChip extends StatelessWidget {
  const VehicleChip({super.key, required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final cart = context.appRead.cartState;
    return ListenableBuilder(
      listenable: cart.terms,
      builder: (context, _) {
        final vehicle = cart.cart['vehicle'] as Map?;
        return ActionChip(
          avatar: const Icon(Icons.directions_car_outlined, size: 18),
          label: Text(vehicle == null ? 'Any vehicle' : '${vehicle['year']} ${vehicle['make']} ${vehicle['model']}'),
          onPressed: onTap,
        );
      },
    );
  }
}
