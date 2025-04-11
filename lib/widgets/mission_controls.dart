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
  String _selectedMissionType = 'inspection';
  bool _isMissionActive = false;
  bool _isPaused = false;

  @override
  Widget build(BuildContext context) {
    final droneService = context.read<DroneService>();

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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _selectedMissionType,
                  decoration: const InputDecoration(
                    labelText: 'Mission Type',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'inspection',
                      child: Text('Inspection'),
                    ),
                    DropdownMenuItem(
                      value: 'spraying',
                      child: Text('Spraying'),
                    ),
                  ],
                  onChanged: _isMissionActive ? null : (value) {
                    if (value != null) {
                      setState(() => _selectedMissionType = value);
                    }
                  },
                ),
              ),
              const SizedBox(width: 16),
              ElevatedButton(
                onPressed: _isMissionActive ? null : () => _startMission(droneService),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 32,
                    vertical: 16,
                  ),
                ),
                child: const Text('Start Mission'),
              ),
            ],
          ),
          if (_isMissionActive) ...[
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton(
                  onPressed: () => _togglePause(droneService),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isPaused ? Colors.green : Colors.orange,
                  ),
                  child: Text(_isPaused ? 'Resume' : 'Pause'),
                ),
                const SizedBox(width: 16),
                ElevatedButton(
                  onPressed: () => _showEmergencyPuzzle(droneService),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
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
        const SnackBar(content: Text('Please save a mission first using the save button in the map controls')),
      );
      return;
    }

    try {
      setState(() => _isMissionActive = true);
      await droneService.startMission(mission);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Mission started successfully')),
      );
    } catch (e) {
      setState(() => _isMissionActive = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to start mission: $e')),
      );
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
          Navigator.of(dialogContext).pop(); // Close the puzzle dialog
        },
      ),
    );
  }

  Future<void> _stopMission(DroneService droneService) async {
    await droneService.stopMission();
    setState(() {
      _isMissionActive = false;
      _isPaused = false;
    });
  }
} 