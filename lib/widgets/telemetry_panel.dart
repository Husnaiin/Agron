import 'package:flutter/material.dart';

class TelemetryPanel extends StatelessWidget {
  const TelemetryPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 4,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildTelemetryItem(
            context,
            Icons.speed,
            'Speed',
            '0 m/s',
          ),
          _buildTelemetryItem(
            context,
            Icons.height,
            'Altitude',
            '0 m',
          ),
          _buildTelemetryItem(
            context,
            Icons.battery_full,
            'Battery',
            '100%',
          ),
          _buildTelemetryItem(
            context,
            Icons.water_drop,
            'Spray Fluid',
            '100%',
          ),
          _buildTelemetryItem(
            context,
            Icons.area_chart,
            'Progress',
            '0%',
          ),
        ],
      ),
    );
  }

  Widget _buildTelemetryItem(
    BuildContext context,
    IconData icon,
    String label,
    String value,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 24),
        const SizedBox(height: 4),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        Text(
          value,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
      ],
    );
  }
} 