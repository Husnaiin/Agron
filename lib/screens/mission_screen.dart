import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:latlong2/latlong.dart';
import 'package:intl/intl.dart';
import 'package:agron_gcs/services/mission_storage.dart';
import 'package:agron_gcs/services/drone_service.dart';
import 'package:agron_gcs/models/mission.dart';
import 'package:agron_gcs/screens/ai_mission_input_screen.dart';

class MissionScreen extends StatefulWidget {
  const MissionScreen({super.key});

  @override
  State<MissionScreen> createState() => _MissionScreenState();
}

class _MissionScreenState extends State<MissionScreen> with SingleTickerProviderStateMixin {
  final MissionStorage _missionStorage = MissionStorage();
  late Future<List<Mission>> _missionsFuture;
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _missionsFuture = _missionStorage.getMissions();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Missions'),
        actions: [
          IconButton(
            icon: const Icon(Icons.auto_awesome),
            onPressed: _openAIMissionPlanner,
            tooltip: 'AI Mission Planning',
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.history), text: 'All Missions'),
            Tab(icon: Icon(Icons.schedule), text: 'Scheduled'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildAllMissionsTab(),
          _buildScheduledMissionsTab(),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openAIMissionPlanner,
        icon: const Icon(Icons.auto_awesome),
        label: const Text('AI Create Mission'),
      ),
    );
  }

  Widget _buildAllMissionsTab() {
    return FutureBuilder<List<Mission>>(
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
          itemBuilder: (context, index) => _buildMissionCard(missions[index]),
        );
      },
    );
  }

  Widget _buildScheduledMissionsTab() {
    return FutureBuilder<List<Mission>>(
      future: _missionStorage.getScheduledMissions(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          return Center(child: Text('Error: ${snapshot.error}'));
        }

        final missions = snapshot.data ?? [];
        if (missions.isEmpty) {
          return const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.schedule, size: 64, color: Colors.grey),
                SizedBox(height: 16),
                Text('No scheduled missions', style: TextStyle(color: Colors.grey)),
              ],
            ),
          );
        }

        // Sort by scheduled date
        missions.sort((a, b) => a.scheduledAt!.compareTo(b.scheduledAt!));

        return ListView.builder(
          itemCount: missions.length,
          itemBuilder: (context, index) => _buildMissionCard(missions[index]),
        );
      },
    );
  }

  Widget _buildMissionCard(Mission mission) {
    final area = _calculateArea(mission.waypoints.map((w) => w.position).toList());
    final acres = area / 4046.86;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: ListTile(
        leading: mission.isScheduled
            ? const Icon(Icons.schedule, color: Colors.orange)
            : const Icon(Icons.check_circle_outline, color: Colors.grey),
        title: Text(mission.name),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (mission.isScheduled && mission.scheduledAt != null)
              Row(
                children: [
                  const Icon(Icons.calendar_today, size: 14, color: Colors.orange),
                  const SizedBox(width: 4),
                  Text(
                    'Scheduled: ${DateFormat.yMMMd().add_jm().format(mission.scheduledAt!)}',
                    style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.orange),
                  ),
                ],
              ),
            if (mission.reminderEnabled)
              const Row(
                children: [
                  Icon(Icons.notifications_active, size: 14, color: Colors.blue),
                  SizedBox(width: 4),
                  Text('Reminder enabled', style: TextStyle(color: Colors.blue, fontSize: 12)),
                ],
              ),
            Text('Created: ${DateFormat.yMMMd().add_jm().format(mission.createdAt)}'),
            if (mission.completedAt != null)
              Text('Completed: ${DateFormat.yMMMd().add_jm().format(mission.completedAt!)}'),
            Row(
              children: [
                Flexible(
                  child: Text(
                    'Status: ${mission.status.toString().split('.').last}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  '${mission.progressPercentage}%', 
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                    color: mission.progressPercentage >= 100 ? Colors.green : Colors.orange,
                  ),
                ),
              ],
            ),
            Text('Area: ${acres.toStringAsFixed(2)} acres'),
            Text('Waypoints: ${mission.waypoints.length}'),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: Icon(
                mission.isScheduled ? Icons.schedule : Icons.schedule_outlined,
                color: mission.isScheduled ? Colors.orange : null,
              ),
              onPressed: () => _scheduleMission(mission),
              tooltip: mission.isScheduled ? 'Edit Schedule' : 'Schedule Mission',
            ),
            if (mission.progressPercentage > 0 && mission.progressPercentage < 100)
              IconButton(
                icon: const Icon(Icons.play_circle_outline, color: Colors.green),
                onPressed: () => _resumeMission(mission),
                tooltip: 'Resume Mission (${mission.progressPercentage}%)',
              )
            else
              IconButton(
                icon: const Icon(Icons.play_arrow),
                onPressed: () => _startMission(mission, isResume: false),
                tooltip: 'Start Mission',
              ),
            IconButton(
              icon: const Icon(Icons.delete),
              onPressed: () => _deleteMission(mission),
              tooltip: 'Delete Mission',
            ),
          ],
        ),
        onTap: () => _showMissionInfo(context, mission),
      ),
    );
  }

  Future<void> _scheduleMission(Mission mission) async {
    DateTime? selectedDate;
    TimeOfDay? selectedTime;
    bool reminderEnabled = mission.reminderEnabled;

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(mission.isScheduled ? 'Edit Schedule' : 'Schedule Mission'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.calendar_today),
                  title: Text(selectedDate != null
                      ? DateFormat.yMMMd().format(selectedDate!)
                      : mission.scheduledAt != null
                          ? DateFormat.yMMMd().format(mission.scheduledAt!)
                          : 'Select Date'),
                  onTap: () async {
                    final date = await showDatePicker(
                      context: context,
                      initialDate: mission.scheduledAt ?? DateTime.now().add(const Duration(days: 1)),
                      firstDate: DateTime.now(),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                    );
                    if (date != null) {
                      setDialogState(() => selectedDate = date);
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.access_time),
                  title: Text(selectedTime != null
                      ? selectedTime!.format(context)
                      : mission.scheduledAt != null
                          ? TimeOfDay.fromDateTime(mission.scheduledAt!).format(context)
                          : 'Select Time'),
                  onTap: () async {
                    final time = await showTimePicker(
                      context: context,
                      initialTime: mission.scheduledAt != null
                          ? TimeOfDay.fromDateTime(mission.scheduledAt!)
                          : const TimeOfDay(hour: 9, minute: 0),
                    );
                    if (time != null) {
                      setDialogState(() => selectedTime = time);
                    }
                  },
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.notifications_active),
                  title: const Text('Enable Reminder'),
                  subtitle: const Text('30 minutes before mission'),
                  value: reminderEnabled,
                  onChanged: (value) {
                    setDialogState(() => reminderEnabled = value);
                  },
                ),
              ],
            ),
          ),
          actions: [
            if (mission.isScheduled)
              TextButton(
                onPressed: () async {
                  await _missionStorage.updateMissionSchedule(
                    mission.id,
                    null,
                    false,
                    false,
                  );
                  _refreshMissions();
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Mission unscheduled')),
                  );
                },
                child: const Text('Unschedule'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                final date = selectedDate ?? mission.scheduledAt ?? DateTime.now();
                final time = selectedTime ?? (mission.scheduledAt != null
                    ? TimeOfDay.fromDateTime(mission.scheduledAt!)
                    : const TimeOfDay(hour: 9, minute: 0));

                final scheduledDateTime = DateTime(
                  date.year,
                  date.month,
                  date.day,
                  time.hour,
                  time.minute,
                );

                if (scheduledDateTime.isBefore(DateTime.now())) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Cannot schedule in the past')),
                  );
                  return;
                }

                await _missionStorage.updateMissionSchedule(
                  mission.id,
                  scheduledDateTime,
                  true,
                  reminderEnabled,
                );

                _refreshMissions();
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      reminderEnabled
                          ? 'Mission scheduled with reminder'
                          : 'Mission scheduled',
                    ),
                    backgroundColor: Colors.green,
                  ),
                );
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  void _refreshMissions() {
    setState(() {
      _missionsFuture = _missionStorage.getMissions();
    });
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

  void _startMission(Mission mission, {bool isResume = false}) {
    final droneService = context.read<DroneService>();
    droneService.setMission(mission, fromHistory: true);
    if (Navigator.canPop(context)) {
      Navigator.pop(context);
    } else {
      Navigator.pushReplacementNamed(context, '/home');
    }
  }
  
  void _resumeMission(Mission mission) {
    final droneService = context.read<DroneService>();
    droneService.setMission(mission, fromHistory: true);
    
    // Show resume confirmation dialog
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Resume Mission'),
        content: Text(
          'Resume mission "${mission.name}" from ${mission.progressPercentage}% completion?\n\n'
          'Waypoint ${mission.lastCompletedWaypointIndex + 1} of ${mission.waypoints.length}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              if (Navigator.canPop(context)) {
                Navigator.pop(context);
              } else {
                Navigator.pushReplacementNamed(context, '/home');
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            child: const Text('Resume'),
          ),
        ],
      ),
    );
  }

  void _showMissionInfo(BuildContext context, Mission mission) {
    final area = _calculateArea(mission.waypoints.map((w) => w.position).toList());
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
                Text('Created: ${DateFormat.yMMMd().add_jm().format(mission.createdAt)}'),
                if (mission.scheduledAt != null)
                  Text(
                    'Scheduled: ${DateFormat.yMMMd().add_jm().format(mission.scheduledAt!)}',
                    style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.orange),
                  ),
                if (mission.completedAt != null)
                  Text('Completed: ${DateFormat.yMMMd().add_jm().format(mission.completedAt!)}'),
                const SizedBox(height: 8),
                Text('Area: ${acres.toStringAsFixed(2)} acres'),
                const SizedBox(height: 12),
                const Text('Waypoints:', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                ...mission.waypoints.asMap().entries.map((e) {
                  final i = e.key + 1;
                  final p = e.value.position;
                  return Text('$i) ${p.latitude.toStringAsFixed(6)}, ${p.longitude.toStringAsFixed(6)}');
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
      _refreshMissions();
    }
  }

  Future<void> _openAIMissionPlanner() async {
    final LatLng currentLocation = LatLng(31.5204, 74.3587);

    final mission = await Navigator.push<Mission>(
      context,
      MaterialPageRoute(
        builder: (context) => AIMissionInputScreen(currentLocation: currentLocation),
      ),
    );

    if (mission != null) {
      await _missionStorage.saveMission(mission);
      _refreshMissions();

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('AI Mission created successfully!'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }
}