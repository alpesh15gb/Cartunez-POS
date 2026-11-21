import 'package:flutter/material.dart';

import '../../main.dart';
import '../workshop/vehicles.dart'; // WS-C

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
        // WS-C (workshop): registration number on the chip, and a picker by reg no.
        final reg = vehicle?['regNo'];
        return Row(mainAxisSize: MainAxisSize.min, children: [
          ActionChip(
            avatar: const Icon(Icons.directions_car_outlined, size: 18),
            label: Text(vehicle == null ? 'Any vehicle' : '${reg == null ? '' : '$reg · '}${vehicle['year']} ${vehicle['make']} ${vehicle['model']}'),
            onPressed: onTap,
          ),
          IconButton(
            tooltip: 'Find vehicle by registration number',
            icon: const Icon(Icons.manage_search),
            onPressed: () async {
              final app = context.appRead;
              final picked = await pickVehicle(context);
              if (picked == null) return;
              final lines = [
                for (final l in app.cart['lines'] as List) {...Map<String, dynamic>.from(l as Map), 'overrideReason': ''},
              ];
              app.updateCart({
                'vehicle': counterVehicle(picked),
                'approvalId': null,
                'lines': lines,
                if ('${app.cart['customerId'] ?? ''}'.isEmpty && picked['customerId'] != null) 'customerId': picked['customerId'],
              });
            },
          ),
        ]);
      },
    );
  }
}
