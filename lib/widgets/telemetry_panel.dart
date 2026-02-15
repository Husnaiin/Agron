import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/drone_service.dart';
import '../models/telemetry.dart';

class TelemetryPanel extends StatelessWidget {
  final DroneService droneService;

  const TelemetryPanel({
    super.key,
    required this.droneService,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Telemetry>(
      stream: droneService.telemetryStream,
      builder: (context, snapshot) {
        final telemetry = snapshot.data;
        final droneServiceState = Provider.of<DroneService>(context);
        final targetSpeed = droneServiceState.targetSpeed;
        final targetAltitude = droneServiceState.targetAltitude;
        final isMissionActive = droneServiceState.isMissionActive;
         final isConnected = droneServiceState.isConnected;

        // Show ONLY actual drone values here. If not connected or no telemetry yet,
        // show placeholders ("--") instead of default/target values to avoid confusion.
        final hasTelemetry = isConnected && telemetry != null;
        final displaySpeed = hasTelemetry
            ? '${telemetry.speed.toStringAsFixed(1)} m/s'
            : '--';
        final displayAltitude = hasTelemetry
            ? '${telemetry.altitude.toStringAsFixed(1)} m'
            : '--';

        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(26),
                blurRadius: 4,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildEditableTelemetryItem(
                context,
                Icons.speed,
                'Speed',
                displaySpeed,
                isMissionActive
                    ? null
                    : (targetSpeed != null
                        ? '${targetSpeed.toStringAsFixed(1)} m/s'
                        : null),
                isMissionActive
                    ? null
                    : () => _showEditDialog(
                            context, 'Speed', targetSpeed ?? 5.0, (value) {
                          droneService.setTargetSpeed(value);
                        }),
              ),
              _buildEditableTelemetryItem(
                context,
                Icons.height,
                'Altitude',
                displayAltitude,
                isMissionActive
                    ? null
                    : (targetAltitude != null
                        ? '${targetAltitude.toStringAsFixed(1)} m'
                        : null),
                isMissionActive
                    ? null
                    : () => _showEditDialog(
                            context, 'Altitude', targetAltitude ?? 20.0,
                            (value) {
                          droneService.setTargetAltitude(value);
                        }),
              ),
              _buildTelemetryItem(
                context,
                Icons.battery_full,
                'Battery',
                telemetry != null ? '${telemetry.batteryPercentage}%' : '--',
              ),
              _buildTelemetryItem(
                context,
                Icons.water_drop,
                'Spray',
                telemetry != null ? '${telemetry.sprayLevel}%' : '--',
              ),
              _buildTelemetryItem(
                context,
                Icons.area_chart,
                'Progress',
                telemetry != null ? '${telemetry.missionProgress}%' : '--',
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildEditableTelemetryItem(
    BuildContext context,
    IconData icon,
    String label,
    String displayValue,
    String? targetValue,
    VoidCallback? onTap,
  ) {
    final widget = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 24, color: targetValue != null ? Colors.blue : null),
        const SizedBox(height: 4),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        Text(
          displayValue,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: targetValue != null ? Colors.blue : null,
              ),
        ),
        if (targetValue != null)
          Text(
            'Target',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontSize: 10,
                  color: Colors.blue,
                ),
          ),
      ],
    );

    if (onTap != null) {
      return GestureDetector(
        onTap: onTap,
        child: widget,
      );
    }
    return widget;
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

  void _showEditDialog(BuildContext context, String label, double currentValue,
      Function(double) onSave) {
    final controller =
        TextEditingController(text: currentValue.toStringAsFixed(1));
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Set $label'),
        content: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: label,
            suffixText: label == 'Speed' ? 'm/s' : 'm',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final value = double.tryParse(controller.text);
              if (value != null && value > 0) {
                onSave(value);
                Navigator.pop(context);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}
