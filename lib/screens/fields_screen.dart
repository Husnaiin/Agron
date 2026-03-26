import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:agron_gcs/models/field.dart';
import 'package:agron_gcs/models/mission.dart';
import 'package:agron_gcs/services/mission_storage.dart';
import 'package:agron_gcs/services/drone_service.dart';
import 'package:agron_gcs/screens/field_missions_screen.dart';
import 'package:agron_gcs/screens/ai_mission_input_screen.dart';
import 'package:provider/provider.dart';

/// Single list of fields with survey stats and quick actions.
class FieldsScreen extends StatefulWidget {
  const FieldsScreen({super.key});

  @override
  State<FieldsScreen> createState() => _FieldsScreenState();
}

class _FieldsScreenState extends State<FieldsScreen> {
  final MissionStorage _storage = MissionStorage();
  late Future<List<FieldDashboardEntry>> _entriesFuture;
  int _fieldsListGeneration = 0;

  @override
  void initState() {
    super.initState();
    _entriesFuture = _storage.getFieldDashboardEntries();
  }

  void _refresh() {
    setState(() {
      _fieldsListGeneration++;
      _entriesFuture = _storage.getFieldDashboardEntries();
    });
  }

  Future<void> _confirmDeleteField(FieldDashboardEntry entry) async {
    final f = entry.field;
    final n = entry.surveyCount;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete field?'),
        content: Text(
          n == 0
              ? '“${f.name}” will be removed. This cannot be undone.'
              : '“${f.name}” and all $n survey plan${n == 1 ? '' : 's'} on it will be permanently removed. This cannot be undone.',
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
    await _storage.deleteField(f.id);
    _refresh();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Field “${f.name}” deleted')),
      );
    }
  }

  Future<void> _openAIMissionPlanner() async {
    const LatLng currentLocation = LatLng(31.5204, 74.3587);

    final mission = await Navigator.push<Mission>(
      context,
      MaterialPageRoute(
        builder: (context) =>
            AIMissionInputScreen(currentLocation: currentLocation),
      ),
    );

    if (mission == null || !mounted) return;

    final positions = mission.waypoints.map((w) => w.position).toList();
    if (positions.length < 3) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('AI mission needs at least 3 waypoints for a field'),
        ),
      );
      return;
    }

    final hull = convexHull(positions);
    if (hull.length < 3) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not build field outline')),
      );
      return;
    }

    final nameController = TextEditingController(
      text: 'Field ${DateTime.now().toIso8601String().split('T').first}',
    );
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Name this field'),
        content: TextField(
          controller: nameController,
          decoration: const InputDecoration(labelText: 'Field name'),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, nameController.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (name == null || name.isEmpty || !mounted) return;

    final fieldId = 'field_${DateTime.now().millisecondsSinceEpoch}';
    final now = DateTime.now();
    final area = MissionStorage.computeOutlineAreaM2(hull);

    await _storage.saveField(Field(
      id: fieldId,
      name: name,
      boundary: hull,
      areaSquareMeters: area,
      createdAt: now,
      updatedAt: now,
    ));

    final toSave = mission.copyWith(fieldId: fieldId);
    await _storage.saveMission(toSave);
    _refresh();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('AI mission saved under your new field'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  void _doSurvey(FieldDashboardEntry entry) {
    final m = entry.latestMission;
    if (m == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'No survey plan yet for "${entry.field.name}". Save one from the map or use AI.',
          ),
        ),
      );
      return;
    }
    context.read<DroneService>().setMission(m, fromHistory: true);
    if (Navigator.canPop(context)) {
      Navigator.pop(context);
    } else {
      Navigator.pushReplacementNamed(context, '/home');
    }
  }

  Future<void> _scheduleSurvey(FieldDashboardEntry entry) async {
    final m = entry.latestMission;
    if (m == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Add a survey plan first for "${entry.field.name}" (map or AI).',
          ),
        ),
      );
      return;
    }
    await _showScheduleSurveyDialog(m);
    if (mounted) _refresh();
  }

  Future<void> _showScheduleSurveyDialog(Mission mission) async {
    DateTime? selectedDate;
    TimeOfDay? selectedTime;
    bool reminderEnabled = mission.reminderEnabled;

    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            mission.isScheduled ? 'Edit scheduled survey' : 'Schedule survey',
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  mission.name,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.calendar_today),
                  title: Text(selectedDate != null
                      ? DateFormat.yMMMd().format(selectedDate!)
                      : mission.scheduledAt != null
                          ? DateFormat.yMMMd().format(mission.scheduledAt!)
                          : 'Select date'),
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
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.access_time),
                  title: Text(selectedTime != null
                      ? selectedTime!.format(context)
                      : mission.scheduledAt != null
                          ? TimeOfDay.fromDateTime(mission.scheduledAt!)
                              .format(context)
                          : 'Select time'),
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
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.notifications_active),
                  title: const Text('Reminder'),
                  subtitle: const Text(
                    'Local notification 30 min before (synced from your account data)',
                  ),
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
                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                },
                child: const Text('Clear schedule'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
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
                    const SnackBar(
                      content: Text('Pick a time in the future'),
                    ),
                  );
                  return;
                }

                await _storage.updateMissionSchedule(
                  mission.id,
                  scheduledDateTime,
                  true,
                  reminderEnabled,
                );

                if (dialogContext.mounted) Navigator.pop(dialogContext);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        reminderEnabled
                            ? 'Survey scheduled — reminder will notify you before'
                            : 'Survey time saved to your account',
                      ),
                    ),
                  );
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fieldCard(FieldDashboardEntry entry) {
    final f = entry.field;
    final theme = Theme.of(context);
    final acres = f.areaSquareMeters / 4046.86;
    final areaLine = f.areaSquareMeters <= 0
        ? 'Area not set'
        : '${acres.toStringAsFixed(2)} ac · ${NumberFormat.decimalPattern().format(f.areaSquareMeters.round())} m²';

    final lastLine = entry.lastSurveyAt != null
        ? 'Last activity: ${DateFormat.yMMMd().add_jm().format(entry.lastSurveyAt!.toLocal())}'
        : 'No surveys yet';

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: CircleAvatar(
              backgroundColor: theme.colorScheme.primaryContainer,
              foregroundColor: theme.colorScheme.onPrimaryContainer,
              child: const Icon(Icons.crop_square),
            ),
            title: Text(
              f.name,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${entry.surveyCount} survey${entry.surveyCount == 1 ? '' : 's'}'
                    ' · ${entry.completedSurveyCount} completed',
                  ),
                  const SizedBox(height: 4),
                  Text(areaLine),
                  const SizedBox(height: 4),
                  Text(
                    lastLine,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: Icon(
                    Icons.delete_outline,
                    color: theme.colorScheme.error,
                  ),
                  tooltip: 'Delete field',
                  onPressed: () => _confirmDeleteField(entry),
                ),
                Icon(
                  Icons.chevron_right,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
            onTap: () async {
              await Navigator.push<bool>(
                context,
                MaterialPageRoute(
                  builder: (context) => FieldMissionsScreen(fieldId: f.id),
                ),
              );
              if (mounted) _refresh();
            },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _doSurvey(entry),
                    icon: const Icon(Icons.play_arrow_outlined),
                    label: const Text('Do survey'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => _scheduleSurvey(entry),
                    icon: const Icon(Icons.schedule),
                    label: const Text('Schedule survey'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Fields'),
      ),
      body: FutureBuilder<List<FieldDashboardEntry>>(
        key: ValueKey<int>(_fieldsListGeneration),
        future: _entriesFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }
          final entries = snapshot.data ?? [];
          if (entries.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.crop_square_outlined,
                      size: 64,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'No fields yet',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Draw a boundary on the map and save, or create a field with AI.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () async => _refresh(),
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: entries.length,
              itemBuilder: (context, i) => _fieldCard(entries[i]),
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openAIMissionPlanner,
        icon: const Icon(Icons.auto_awesome),
        label: const Text('AI mission'),
      ),
    );
  }
}
