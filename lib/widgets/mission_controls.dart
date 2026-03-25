import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/drone_service.dart';
import 'emergency_puzzle.dart';

class MissionControls extends StatefulWidget {
  const MissionControls({super.key});

  @override
  State<MissionControls> createState() => _MissionControlsState();
}

class _MissionControlsState extends State<MissionControls> {
  bool _isPaused = false;

  @override
  Widget build(BuildContext context) {
    final droneService = Provider.of<DroneService>(context);
    final isMissionUploaded = droneService.isMissionUploaded;
    final isMissionActive = droneService.isMissionActive;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: droneService.selectedMissionType,
                  decoration: const InputDecoration(
                    labelText: 'Mission Type',
                    border: OutlineInputBorder(),
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                  isExpanded: true,
                  items: const [
                    DropdownMenuItem(
                      value: 'inspection',
                      child: Text('Inspection'),
                    ),
                    DropdownMenuItem(
                      value: 'spraying',
                      child: Text('Spraying'),
                    ),
                    DropdownMenuItem(
                      value: 'dense_inspection',
                      child: Text('Dense Inspection'),
                    ),
                    DropdownMenuItem(
                      value: 'dimr',
                      child: Text('DIMR (Dense + Resumption)'),
                    ),
                  ],
                  onChanged: isMissionActive
                      ? null
                      : (value) {
                          if (value != null) {
                            context
                                .read<DroneService>()
                                .setSelectedMissionType(value);
                          }
                        },
                ),
              ),
              const SizedBox(width: 10),
              ElevatedButton(
                onPressed: (isMissionActive || !isMissionUploaded)
                    ? null
                    : () => _startMission(droneService),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 12,
                  ),
                ),
                child: const Text('Start Mission'),
              ),
            ],
          ),
          if (isMissionActive) ...[
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton(
                  onPressed: () => _togglePause(droneService),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isPaused ? Colors.green : Colors.orange,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                  ),
                  child: Text(_isPaused ? 'Resume' : 'Pause'),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  onPressed: () => _showEmergencyPuzzle(droneService),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                  ),
                  child: const Text('Stop'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _startMission(DroneService droneService) async {
    final mission = droneService.currentMission;
    if (mission == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'Please save a mission first using the save button in the map controls')),
      );
      return;
    }

    try {
      final isResume = mission.progressPercentage > 0 &&
          mission.progressPercentage < 100;
      await droneService.startMission(mission, isResume: isResume);

      final message = isResume
          ? 'Mission resumed from ${mission.progressPercentage}%'
          : 'Mission started successfully';
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start mission: $e')),
        );
      }
    }
  }

  Future<void> _togglePause(DroneService droneService) async {
    if (_isPaused) {
      await droneService.resumeMission();
    } else {
      await droneService.pauseMission();
    }
    setState(() => _isPaused = !_isPaused);
  }

  void _showEmergencyPuzzle(DroneService droneService) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => EmergencyPuzzle(
        onPuzzleSolved: () async {
          await _stopMission(droneService);
          if (dialogContext.mounted) Navigator.of(dialogContext).pop();
        },
      ),
    );
  }

  Future<void> _stopMission(DroneService droneService) async {
    await droneService.stopMission();
    if (mounted) {
      setState(() {
        _isPaused = false;
      });
    }
  }
}
