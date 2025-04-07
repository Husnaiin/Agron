import 'package:flutter/material.dart';

class MissionControls extends StatefulWidget {
  const MissionControls({super.key});

  @override
  State<MissionControls> createState() => _MissionControlsState();
}

class _MissionControlsState extends State<MissionControls> {
  String _selectedMissionType = 'inspection';
  bool _isMissionActive = false;

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
                  onChanged: (value) {
                    if (value != null) {
                      setState(() => _selectedMissionType = value);
                    }
                  },
                ),
              ),
              const SizedBox(width: 16),
              ElevatedButton(
                onPressed: _isMissionActive ? null : _startMission,
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
                  onPressed: _pauseMission,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange,
                  ),
                  child: const Text('Pause'),
                ),
                const SizedBox(width: 16),
                ElevatedButton(
                  onPressed: _stopMission,
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

  void _startMission() {
    setState(() => _isMissionActive = true);
    // TODO: Implement mission start logic
  }

  void _pauseMission() {
    setState(() => _isMissionActive = false);
    // TODO: Implement mission pause logic
  }

  void _stopMission() {
    setState(() => _isMissionActive = false);
    // TODO: Implement mission stop logic
  }
} 