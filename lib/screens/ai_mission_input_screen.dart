import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:agron_gcs/services/ai_mission_planner.dart';
import 'package:agron_gcs/models/mission.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

class AIMissionInputScreen extends StatefulWidget {
  final LatLng currentLocation;

  const AIMissionInputScreen({
    super.key,
    required this.currentLocation,
  });

  @override
  State<AIMissionInputScreen> createState() => _AIMissionInputScreenState();
}

class _AIMissionInputScreenState extends State<AIMissionInputScreen> {
  final TextEditingController _descriptionController = TextEditingController();
  final AIMissionPlanner _aiPlanner = AIMissionPlanner();
  final stt.SpeechToText _speech = stt.SpeechToText();
  
  bool _isGenerating = false;
  bool _isListening = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initSpeech();
  }

  Future<void> _initSpeech() async {
    await _speech.initialize();
  }

  Future<void> _startListening() async {
    setState(() {
      _isListening = true;
      _error = null;
    });

    await _speech.listen(
      onResult: (result) {
        setState(() {
          _descriptionController.text = result.recognizedWords;
        });
      },
    );
  }

  Future<void> _stopListening() async {
    await _speech.stop();
    setState(() => _isListening = false);
  }

  Future<void> _generateMission() async {
    final description = _descriptionController.text.trim();
    if (description.isEmpty) {
      setState(() => _error = 'Please describe your mission');
      return;
    }

    setState(() {
      _isGenerating = true;
      _error = null;
    });

    try {
      final waypoints = await _aiPlanner.generateWaypointsFromText(
        description: description,
        centerLocation: widget.currentLocation,
      );

      final missionType = await _aiPlanner.analyzeMissionType(description);
      final isSprayMission = missionType.toLowerCase().contains('spray');

      final mission = Mission(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: 'AI: $missionType',
        waypoints: waypoints.map((pos) => MissionWaypoint(
          position: pos,
          altitude: 50.0,
          sprayRate: isSprayMission ? 1.0 : 0.0,
          sprayEnabled: isSprayMission,
        )).toList(),
        createdAt: DateTime.now(),
        status: MissionStatus.pending,
        defaultAltitude: 50.0,
        defaultSprayRate: 1.0,
        defaultSpeed: 5.0,
      );

      setState(() => _isGenerating = false);
      _showMissionPreview(mission, description);
    } catch (e) {
      setState(() {
        _isGenerating = false;
        _error = 'AI Error: ${e.toString()}';
      });
    }
  }

  void _showMissionPreview(Mission mission, String description) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.auto_awesome, color: Colors.purple),
            SizedBox(width: 8),
            Text('AI Generated Mission'),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Your description:', style: TextStyle(fontWeight: FontWeight.bold)),
              Text('"$description"', style: const TextStyle(fontStyle: FontStyle.italic)),
              const SizedBox(height: 16),
              const Text('AI generated:', style: TextStyle(fontWeight: FontWeight.bold)),
              Text('Mission Type: ${mission.name}'),
              Text('Waypoints: ${mission.waypoints.length}'),
              Text('Spray Enabled: ${mission.waypoints.first.sprayEnabled ? "Yes" : "No"}'),
              Text('Speed: ${mission.defaultSpeed} m/s'),
              Text('Altitude: ${mission.defaultAltitude} m'),
              const SizedBox(height: 12),
              const Text('Waypoints:', style: TextStyle(fontWeight: FontWeight.bold)),
              ...mission.waypoints.asMap().entries.map((e) {
                final i = e.key + 1;
                final p = e.value.position;
                return Text('$i) ${p.latitude.toStringAsFixed(4)}, ${p.longitude.toStringAsFixed(4)}');
              }),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.pop(context, mission);
            },
            child: const Text('Use This Mission'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Mission Planning'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Describe your mission in natural language:',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Examples:\n'
              '• "Spray the northern 5 acres"\n'
              '• "Survey my corn field"\n'
              '• "Inspect the western boundary"',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _descriptionController,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: 'E.g., Spray pesticide on the eastern field...',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(
                    _isListening ? Icons.mic : Icons.mic_none,
                    color: _isListening ? Colors.red : null,
                  ),
                  onPressed: _isListening ? _stopListening : _startListening,
                  tooltip: 'Voice Input',
                ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _isGenerating ? null : _generateMission,
              icon: _isGenerating
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome),
              label: Text(_isGenerating ? 'AI is planning...' : 'Generate Mission with AI'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.all(16),
              ),
            ),
            const SizedBox(height: 24),
            const Divider(),
            const Text(
              'How it works:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              '1. AI analyzes your description\n'
              '2. Generates optimal waypoints\n'
              '3. Creates flight path automatically\n'
              '4. You review and approve',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    _speech.stop();
    super.dispose();
  }
}