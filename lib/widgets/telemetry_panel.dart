import 'package:flutter/material.dart';
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
        final speedText = telemetry != null
            ? '${telemetry.speed.toStringAsFixed(1)} m/s'
            : '--';
        final altitudeText = telemetry != null
            ? '${telemetry.altitude.toStringAsFixed(1)} m'
            : '--';

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
              _buildTelemetryItem(
                context,
                Icons.speed,
                'Speed',
                speedText,
              ),
              _buildTelemetryItem(
                context,
                Icons.height,
                'Altitude',
                altitudeText,
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

  Widget _buildTelemetryItem(
    BuildContext context,
    IconData icon,
    String label,
    String value,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 20),
        const SizedBox(height: 2),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11),
        ),
        Text(
          value,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
      ],
    );
  }
}
