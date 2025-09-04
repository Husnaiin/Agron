import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:latlong2/latlong.dart';
import 'package:intl/intl.dart';
import 'package:agron_gcs/services/mission_storage.dart';
import 'package:agron_gcs/services/drone_service.dart';
import 'package:agron_gcs/models/mission.dart';

class MissionScreen extends StatefulWidget {
  const MissionScreen({super.key});

  @override
  State<MissionScreen> createState() => _MissionScreenState();
}

class _MissionScreenState extends State<MissionScreen> {
  final MissionStorage _missionStorage = MissionStorage();
  late Future<List<Mission>> _missionsFuture;

  @override
  void initState() {
    super.initState();
    _missionsFuture = _missionStorage.getMissions();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mission History'),
      ),
      body: FutureBuilder<List<Mission>>(
        future: _missionsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }

          final missions = snapshot.data ?? [];
          if (missions.isEmpty) {
            return const Center(child: Text('No missions found'));
          }

          return ListView.builder(
            itemCount: missions.length,
            itemBuilder: (context, index) {
              final mission = missions[index];
              final area = _calculateArea(
                  mission.waypoints.map((w) => w.position).toList());
              final acres = area / 4046.86; // Convert square meters to acres

              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: ListTile(
                  title: Text(mission.name),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          'Created: ${DateFormat.yMMMd().add_jm().format(mission.createdAt)}'),
                      Text(
                          'Status: ${mission.status.toString().split('.').last}'),
                      Text('Area: ${acres.toStringAsFixed(2)} acres'),
                      Text('Waypoints: ${mission.waypoints.length}'),
                    ],
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.play_arrow),
                        onPressed: () => _startMission(mission),
                        tooltip: 'Start Mission',
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete),
                        onPressed: () => _deleteMission(mission),
                        tooltip: 'Delete Mission',
                      ),
                    ],
                  ),
                  onTap: () {
                    _showMissionInfo(context, mission);
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }

  double _calculateArea(List<LatLng> points) {
    if (points.length < 3) return 0;

    double area = 0;
    for (int i = 0; i < points.length; i++) {
      int j = (i + 1) % points.length;
      area += points[i].latitude * points[j].longitude;
      area -= points[j].latitude * points[i].longitude;
    }
    area = area.abs() * 111319.9 * 111319.9 / 2;
    return area;
  }

  void _startMission(Mission mission) {
    final droneService = context.read<DroneService>();
    droneService.setMission(mission);
    Navigator.pushReplacementNamed(context, '/home');
  }

  void _showMissionInfo(BuildContext context, Mission mission) {
    final area =
        _calculateArea(mission.waypoints.map((w) => w.position).toList());
    final acres = area / 4046.86;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(mission.name),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    'Created: ${DateFormat.yMMMd().add_jm().format(mission.createdAt)}'),
                const SizedBox(height: 8),
                Text('Area: ${acres.toStringAsFixed(2)} acres'),
                const SizedBox(height: 12),
                const Text('Waypoints:',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                ...mission.waypoints.asMap().entries.map((e) {
                  final i = e.key + 1;
                  final p = e.value.position;
                  return Text(
                      '$i) ${p.latitude.toStringAsFixed(6)}, ${p.longitude.toStringAsFixed(6)}');
                }).toList(),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteMission(Mission mission) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Mission'),
        content: const Text('Are you sure you want to delete this mission?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _missionStorage.deleteMission(mission.id);
      setState(() {
        _missionsFuture = _missionStorage.getMissions();
      }); // Refresh the list
    }
  }

  // Removed unused details dialog to avoid linter warning; selection loads mission on map
}
