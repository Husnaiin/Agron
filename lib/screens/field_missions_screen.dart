import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:agron_gcs/models/field.dart';
import 'package:agron_gcs/models/mission.dart';
import 'package:agron_gcs/services/mission_storage.dart';
import 'package:agron_gcs/services/drone_service.dart';

/// Missions for a single [Field]; cards show mission type, not area.
class FieldMissionsScreen extends StatefulWidget {
  final String fieldId;

  const FieldMissionsScreen({super.key, required this.fieldId});

  @override
  State<FieldMissionsScreen> createState() => _FieldMissionsScreenState();
}

class _FieldMissionsScreenState extends State<FieldMissionsScreen> {
  final MissionStorage _storage = MissionStorage();
  late Future<List<Mission>> _missionsFuture;
  late Future<Field?> _fieldFuture;

  @override
  void initState() {
    super.initState();
    _missionsFuture = _storage.getMissionsForField(widget.fieldId);
    _fieldFuture = _storage.getFieldById(widget.fieldId);
  }

  void _reloadFutures() {
    _missionsFuture = _storage.getMissionsForField(widget.fieldId);
    _fieldFuture = _storage.getFieldById(widget.fieldId);
  }

  void _refresh() {
    setState(_reloadFutures);
  }

  Future<void> _confirmDeleteField(Field field) async {
    final missions = await _storage.getMissionsForField(widget.fieldId);
    if (!mounted) return;
    final n = missions.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete field?'),
        content: Text(
          n == 0
              ? '“${field.name}” will be removed. This cannot be undone.'
              : '“${field.name}” and all $n survey plan${n == 1 ? '' : 's'} will be permanently removed. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _storage.deleteField(field.id);
    if (mounted) {
      Navigator.pop(context, true);
    }
  }

  String _typeLabel(String t) {
    switch (t) {
      case 'dense_inspection':
        return 'Dense inspection';
      case 'dimr':
        return 'DIMR';
      case 'spraying':
        return 'Spraying';
      case 'inspection':
      default:
        return 'Inspection';
    }
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
                      initialDate: mission.scheduledAt ??
                          DateTime.now().add(const Duration(days: 1)),
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
                          ? TimeOfDay.fromDateTime(mission.scheduledAt!)
                              .format(context)
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
                  await _storage.updateMissionSchedule(
                    mission.id,
                    null,
                    false,
                    false,
                  );
                  _refresh();
                  if (context.mounted) Navigator.pop(context);
                },
                child: const Text('Unschedule'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                final date = selectedDate ??
                    mission.scheduledAt ??
                    DateTime.now();
                final time = selectedTime ??
                    (mission.scheduledAt != null
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

                await _storage.updateMissionSchedule(
                  mission.id,
                  scheduledDateTime,
                  true,
                  reminderEnabled,
                );

                _refresh();
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
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
    context.read<DroneService>().setMission(mission, fromHistory: true);
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Resume Mission'),
        content: Text(
          'Resume "${mission.name}" from ${mission.progressPercentage}%?',
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
            child: const Text('Resume'),
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
        content: const Text('Delete this mission?'),
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
      await _storage.deleteMission(mission.id);
      _refresh();
    }
  }

  void _showMissionInfo(Mission mission) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(mission.name),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Type: ${_typeLabel(mission.missionType)}'),
              Text(
                  'Created: ${DateFormat.yMMMd().add_jm().format(mission.createdAt)}'),
              if (mission.scheduledAt != null)
                Text(
                  'Scheduled: ${DateFormat.yMMMd().add_jm().format(mission.scheduledAt!)}',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, color: Colors.orange),
                ),
              if (mission.completedAt != null)
                Text(
                    'Completed: ${DateFormat.yMMMd().add_jm().format(mission.completedAt!)}'),
              Text(
                  'Status: ${mission.status.toString().split('.').last} · ${mission.progressPercentage}%'),
              Text('Waypoints: ${mission.waypoints.length}'),
            ],
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

  Widget _missionCard(Mission mission) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: ListTile(
        leading: mission.isScheduled
            ? const Icon(Icons.schedule, color: Colors.orange)
            : const Icon(Icons.flight_takeoff, color: Colors.grey),
        title: Text(mission.name),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Type: ${_typeLabel(mission.missionType)}'),
            if (mission.isScheduled && mission.scheduledAt != null)
              Text(
                'Scheduled: ${DateFormat.yMMMd().add_jm().format(mission.scheduledAt!)}',
                style: const TextStyle(
                    fontWeight: FontWeight.bold, color: Colors.orange),
              ),
            Text(
                'Created: ${DateFormat.yMMMd().add_jm().format(mission.createdAt)}'),
            Row(
              children: [
                Flexible(
                  child: Text(
                    mission.status.toString().split('.').last,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  ' ${mission.progressPercentage}%',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                    color: mission.progressPercentage >= 100
                        ? Colors.green
                        : Colors.orange,
                  ),
                ),
              ],
            ),
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
            ),
            if (mission.progressPercentage > 0 &&
                mission.progressPercentage < 100)
              IconButton(
                icon:
                    const Icon(Icons.play_circle_outline, color: Colors.green),
                onPressed: () => _resumeMission(mission),
              )
            else
              IconButton(
                icon: const Icon(Icons.play_arrow),
                onPressed: () => _startMission(mission, isResume: false),
              ),
            IconButton(
              icon: const Icon(Icons.delete),
              onPressed: () => _deleteMission(mission),
            ),
          ],
        ),
        onTap: () => _showMissionInfo(mission),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Field?>(
      future: _fieldFuture,
      builder: (context, fieldSnap) {
        final name = fieldSnap.data?.name ?? 'Field';
        return Scaffold(
          appBar: AppBar(
            title: Text(name),
            actions: [
              if (fieldSnap.data != null)
                IconButton(
                  icon: Icon(
                    Icons.delete_outline,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  tooltip: 'Delete field',
                  onPressed: () => _confirmDeleteField(fieldSnap.data!),
                ),
            ],
          ),
          body: FutureBuilder<List<Mission>>(
            future: _missionsFuture,
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return Center(child: Text('Error: ${snap.error}'));
              }
              final list = snap.data ?? [];
              if (list.isEmpty) {
                return const Center(child: Text('No missions in this field'));
              }
              return RefreshIndicator(
                onRefresh: () async => _refresh(),
                child: ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (context, i) => _missionCard(list[i]),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

List<LatLng> convexHull(List<LatLng> points) {
  if (points.length <= 3) return List<LatLng>.from(points);
  int compare(LatLng a, LatLng b) {
    if (a.longitude == b.longitude) {
      return a.latitude.compareTo(b.latitude);
    }
    return a.longitude.compareTo(b.longitude);
  }

  double cross(LatLng o, LatLng a, LatLng b) {
    return (a.longitude - o.longitude) * (b.latitude - o.latitude) -
        (a.latitude - o.latitude) * (b.longitude - o.longitude);
  }

  final sorted = List<LatLng>.from(points)..sort(compare);
  final lower = <LatLng>[];
  for (final p in sorted) {
    while (lower.length >= 2 &&
        cross(lower[lower.length - 2], lower.last, p) <= 0) {
      lower.removeLast();
    }
    lower.add(p);
  }
  final upper = <LatLng>[];
  for (int i = sorted.length - 1; i >= 0; i--) {
    final p = sorted[i];
    while (upper.length >= 2 &&
        cross(upper[upper.length - 2], upper.last, p) <= 0) {
      upper.removeLast();
    }
    upper.add(p);
  }
  lower.removeLast();
  upper.removeLast();
  return [...lower, ...upper];
}
