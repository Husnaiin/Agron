import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz;
import '../models/mission.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;

    tz.initializeTimeZones();

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _notifications.initialize(initSettings);
    _initialized = true;
  }

  /// Schedule a reminder notification for a mission
  Future<void> scheduleMissionReminder(Mission mission) async {
    if (!mission.reminderEnabled || mission.scheduledAt == null) return;

    await initialize();

    // Schedule notification 30 minutes before mission
    final reminderTime = mission.scheduledAt!.subtract(const Duration(minutes: 30));
    
    // Don't schedule if reminder time is in the past
    if (reminderTime.isBefore(DateTime.now())) {
      print('⚠️ Reminder time is in the past, skipping notification');
      return;
    }

    final scheduledDate = tz.TZDateTime.from(reminderTime, tz.local);

    await _notifications.zonedSchedule(
      mission.id.hashCode, // Use mission ID as notification ID
      '🚁 Survey reminder',
      '"${mission.name}" starts in 30 minutes at ${_formatTime(mission.scheduledAt!)}',
      scheduledDate,
      NotificationDetails(
        android: AndroidNotificationDetails(
          'mission_reminders',
          'Survey reminders',
          channelDescription: 'Reminders for scheduled field surveys (from your synced plans)',
          importance: Importance.high,
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );

    print('✅ Reminder scheduled for ${mission.name} at $reminderTime');
  }

  /// Cancel a mission reminder
  Future<void> cancelMissionReminder(String missionId) async {
    await _notifications.cancel(missionId.hashCode);
    print('🗑️ Cancelled reminder for mission $missionId');
  }

  /// Show immediate notification (for testing)
  Future<void> showImmediateNotification(String title, String body) async {
    await initialize();

    await _notifications.show(
      DateTime.now().millisecondsSinceEpoch.remainder(100000),
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'immediate_notifications',
          'Immediate Notifications',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
      ),
    );
  }

  String _formatTime(DateTime dateTime) {
    final hour = dateTime.hour.toString().padLeft(2, '0');
    final minute = dateTime.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}
