import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/field.dart';
import '../models/mission.dart';
import 'notification_service.dart';

/// Per-field stats for the fields dashboard (surveys, last activity, latest plan).
class FieldDashboardEntry {
  final Field field;
  final int surveyCount;
  final int completedSurveyCount;
  final DateTime? lastSurveyAt;
  /// Most recently created mission (used for Do survey / Schedule survey).
  final Mission? latestMission;

  const FieldDashboardEntry({
    required this.field,
    required this.surveyCount,
    required this.completedSurveyCount,
    this.lastSurveyAt,
    this.latestMission,
  });
}

class _Payload {
  final List<Field> fields;
  final List<Mission> missions;

  _Payload({required this.fields, required this.missions});

  factory _Payload.empty() => _Payload(fields: [], missions: []);

  Map<String, dynamic> toJson() => {
        'fields': fields.map((f) => f.toJson()).toList(),
        'missions': missions.map((m) => m.toJson()).toList(),
      };

  factory _Payload.fromJson(Map<String, dynamic> json) {
    final fl = (json['fields'] as List?) ?? [];
    final ml = (json['missions'] as List?) ?? [];
    return _Payload(
      fields: fl
          .map((e) => Field.fromJson(e as Map<String, dynamic>))
          .toList(),
      missions: ml
          .map((e) => Mission.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// Offline-first storage: [Field] → missions. Firebase:
/// `users/{uid}/fields/{fieldId}` and `users/{uid}/fields/{fieldId}/missions/{missionId}`.
class MissionStorage {
  static const String _fieldsCollection = 'fields';
  static const String _missionsSub = 'missions';
  static const String _usersCollection = 'users';
  /// Legacy flat list key (migrated once into [kPayloadKey]).
  static const String _legacyMissionsKey = 'cached_missions';
  static const String kPayloadKey = 'fields_payload_v1';
  /// Old Firebase missions collection (read-only merge when no fields exist).
  static const String _legacyFirebaseMissions = 'missions';

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final NotificationService _notificationService = NotificationService();

  String? get _uid => _auth.currentUser?.uid;

  Future<_Payload> _loadPayload() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(kPayloadKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        return _Payload.fromJson(json.decode(raw) as Map<String, dynamic>);
      } catch (e) {
        print('[STORAGE] Corrupt payload, resetting: $e');
      }
    }

    final legacyStr = prefs.getString(_legacyMissionsKey);
    if (legacyStr != null && legacyStr.isNotEmpty) {
      try {
        final List<dynamic> jsonList = json.decode(legacyStr);
        final migrated = jsonList
            .map((j) => Mission.fromJson(j as Map<String, dynamic>))
            .map((m) => m.copyWith(
                  fieldId: Field.kLegacyFieldId,
                  missionType: m.missionType.isNotEmpty ? m.missionType : 'inspection',
                ))
            .toList();
        final now = DateTime.now();
        final legacyField = Field(
          id: Field.kLegacyFieldId,
          name: 'Imported missions',
          boundary: const [],
          areaSquareMeters: 0,
          createdAt: now,
          updatedAt: now,
        );
        final payload = _Payload(fields: [legacyField], missions: migrated);
        await _persistPayload(payload);
        await prefs.remove(_legacyMissionsKey);
        print(
            '[STORAGE] Migrated ${migrated.length} missions into field "${legacyField.name}"');
        return payload;
      } catch (e) {
        print('[STORAGE] Legacy migration failed: $e');
      }
    }

    return _Payload.empty();
  }

  Future<void> _persistPayload(_Payload p) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kPayloadKey, json.encode(p.toJson()));
  }

  String? _fieldIdForMissionId(_Payload p, String missionId) {
    for (final m in p.missions) {
      if (m.id == missionId) return m.fieldId;
    }
    return null;
  }

  void _syncFieldToFirebaseAsync(Field field) {
    if (_uid == null) return;
    _firestore
        .collection(_usersCollection)
        .doc(_uid)
        .collection(_fieldsCollection)
        .doc(field.id)
        .set(field.toJson())
        .timeout(const Duration(seconds: 5))
        .then((_) => print('[STORAGE] Field synced: ${field.id}'))
        .catchError((e) => print('[STORAGE] Field sync failed: $e'));
  }

  void _syncMissionToFirebaseAsync(String fieldId, Mission mission) {
    if (_uid == null) return;
    _firestore
        .collection(_usersCollection)
        .doc(_uid)
        .collection(_fieldsCollection)
        .doc(fieldId)
        .collection(_missionsSub)
        .doc(mission.id)
        .set(mission.toJson())
        .timeout(const Duration(seconds: 5))
        .then((_) => print('[STORAGE] Mission synced: ${mission.id}'))
        .catchError((e) => print('[STORAGE] Mission sync failed: $e'));
  }

  Future<void> saveField(Field field) async {
    final p = await _loadPayload();
    p.fields.removeWhere((f) => f.id == field.id);
    p.fields.add(field);
    await _persistPayload(p);
    _syncFieldToFirebaseAsync(field);
  }

  Future<void> saveMission(Mission mission) async {
    final p = await _loadPayload();
    p.missions.removeWhere((m) => m.id == mission.id);
    p.missions.add(mission);
    await _persistPayload(p);
    print('[STORAGE] Mission saved locally: ${mission.id} (field ${mission.fieldId})');
    _syncMissionToFirebaseAsync(mission.fieldId, mission);

    if (mission.isScheduled && mission.reminderEnabled) {
      try {
        await _notificationService.scheduleMissionReminder(mission);
      } catch (e) {
        print('[STORAGE] Notification scheduling failed: $e');
      }
    }
  }

  /// Convex hull outline area (m²) — same formula as mission_screen.
  static double computeOutlineAreaM2(List<LatLng> hull) {
    if (hull.length < 3) return 0;
    double area = 0;
    for (int i = 0; i < hull.length; i++) {
      final j = (i + 1) % hull.length;
      area += hull[i].latitude * hull[j].longitude;
      area -= hull[j].latitude * hull[i].longitude;
    }
    return area.abs() * 111319.9 * 111319.9 / 2;
  }

  Future<List<Field>> getFields() async {
    var p = await _loadPayload();
    await _mergeFromFirebase(p);
    p = await _loadPayload();
    final list = List<Field>.from(p.fields);
    list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    await reconcileMissionNotificationReminders();
    return list;
  }

  /// Fields list with survey stats; syncs from Firestore then aligns local
  /// reminder alarms with mission schedule fields stored in the database.
  Future<List<FieldDashboardEntry>> getFieldDashboardEntries() async {
    final fields = await getFields();
    final p = await _loadPayload();
    final byField = <String, List<Mission>>{};
    for (final m in p.missions) {
      byField.putIfAbsent(m.fieldId, () => []).add(m);
    }
    return fields.map((f) {
      final missions = List<Mission>.from(byField[f.id] ?? []);
      missions.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      final surveyCount = missions.length;
      final completedSurveyCount = missions
          .where((m) =>
              m.status == MissionStatus.completed ||
              m.progressPercentage >= 100)
          .length;
      DateTime? lastSurveyAt;
      for (final m in missions) {
        final t = m.completedAt ?? m.createdAt;
        if (lastSurveyAt == null || t.isAfter(lastSurveyAt)) {
          lastSurveyAt = t;
        }
      }
      return FieldDashboardEntry(
        field: f,
        surveyCount: surveyCount,
        completedSurveyCount: completedSurveyCount,
        lastSurveyAt: lastSurveyAt,
        latestMission: missions.isNotEmpty ? missions.first : null,
      );
    }).toList();
  }

  /// Local notification alarms reflect [Mission.isScheduled] / [Mission.scheduledAt]
  /// / [Mission.reminderEnabled] from the merged payload (same as Firestore when synced).
  Future<void> reconcileMissionNotificationReminders() async {
    try {
      await _notificationService.initialize();
    } catch (e) {
      print('[STORAGE] Notification init failed: $e');
      return;
    }
    final p = await _loadPayload();
    for (final m in p.missions) {
      try {
        if (m.isScheduled &&
            m.scheduledAt != null &&
            m.reminderEnabled) {
          await _notificationService.scheduleMissionReminder(m);
        } else {
          await _notificationService.cancelMissionReminder(m.id);
        }
      } catch (e) {
        print('[STORAGE] Reconcile reminder ${m.id}: $e');
      }
    }
  }

  Future<Field?> getFieldById(String id) async {
    final p = await _loadPayload();
    try {
      return p.fields.firstWhere((f) => f.id == id);
    } catch (_) {
      return null;
    }
  }

  Future<List<Mission>> getMissionsForField(String fieldId) async {
    final p = await _loadPayload();
    final list =
        p.missions.where((m) => m.fieldId == fieldId).toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  /// All missions (e.g. scheduled scan).
  Future<List<Mission>> getAllMissions() async {
    final p = await _loadPayload();
    final list = List<Mission>.from(p.missions);
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  Future<List<Mission>> getMissions() => getAllMissions();

  Future<List<Mission>> getScheduledMissions() async {
    final p = await _loadPayload();
    return p.missions.where((m) => m.isScheduled).toList()
      ..sort((a, b) {
        final ta = a.scheduledAt ?? a.createdAt;
        final tb = b.scheduledAt ?? b.createdAt;
        return ta.compareTo(tb);
      });
  }

  Future<void> _mergeFromFirebase(_Payload local) async {
    if (_uid == null) return;
    try {
      final fieldsSnap = await _firestore
          .collection(_usersCollection)
          .doc(_uid)
          .collection(_fieldsCollection)
          .get()
          .timeout(const Duration(seconds: 5));

      if (fieldsSnap.docs.isNotEmpty) {
        final mergedFields = <String, Field>{};
        for (final f in local.fields) {
          mergedFields[f.id] = f;
        }
        final mergedMissions = <String, Mission>{};
        for (final m in local.missions) {
          mergedMissions[m.id] = m;
        }

        for (final doc in fieldsSnap.docs) {
          final field = Field.fromJson(doc.data());
          if (!mergedFields.containsKey(field.id) ||
              field.updatedAt.isAfter(mergedFields[field.id]!.updatedAt)) {
            mergedFields[field.id] = field;
          }
          final ms = await doc.reference
              .collection(_missionsSub)
              .get()
              .timeout(const Duration(seconds: 5));
          for (final md in ms.docs) {
            final m = Mission.fromJson(md.data());
            if (!mergedMissions.containsKey(m.id)) {
              mergedMissions[m.id] = m;
            } else {
              final loc = mergedMissions[m.id]!;
              if (m.progressPercentage > loc.progressPercentage) {
                mergedMissions[m.id] = m;
              }
            }
          }
        }

        await _persistPayload(_Payload(
          fields: mergedFields.values.toList(),
          missions: mergedMissions.values.toList(),
        ));
        return;
      }

      // Legacy Firebase flat missions
      final leg = await _firestore
          .collection(_usersCollection)
          .doc(_uid)
          .collection(_legacyFirebaseMissions)
          .get()
          .timeout(const Duration(seconds: 5));

      if (leg.docs.isEmpty) return;

      final now = DateTime.now();
      var p = await _loadPayload();
      if (!p.fields.any((f) => f.id == Field.kLegacyFieldId)) {
        p.fields.add(Field(
          id: Field.kLegacyFieldId,
          name: 'Imported missions',
          boundary: const [],
          areaSquareMeters: 0,
          createdAt: now,
          updatedAt: now,
        ));
      }
      for (final doc in leg.docs) {
        final m = Mission.fromJson(doc.data());
        if (p.missions.any((x) => x.id == m.id)) continue;
        p.missions.add(m.copyWith(fieldId: Field.kLegacyFieldId));
      }
      await _persistPayload(p);
    } catch (e) {
      print('[STORAGE] Firebase merge failed: $e');
    }
  }

  Future<void> deleteMission(String missionId) async {
    try {
      await _notificationService.cancelMissionReminder(missionId);
    } catch (e) {
      print('[STORAGE] Notification cancel failed: $e');
    }

    final p = await _loadPayload();
    final fieldId = _fieldIdForMissionId(p, missionId);
    p.missions.removeWhere((m) => m.id == missionId);
    await _persistPayload(p);
    print('[STORAGE] Mission deleted locally: $missionId');

    if (_uid != null && fieldId != null) {
      _firestore
          .collection(_usersCollection)
          .doc(_uid)
          .collection(_fieldsCollection)
          .doc(fieldId)
          .collection(_missionsSub)
          .doc(missionId)
          .delete()
          .timeout(const Duration(seconds: 5))
          .catchError((e) => print('[STORAGE] Firebase mission delete failed: $e'));
    }
  }

  Future<void> deleteField(String fieldId) async {
    final p = await _loadPayload();
    for (final m in p.missions.where((m) => m.fieldId == fieldId)) {
      try {
        await _notificationService.cancelMissionReminder(m.id);
      } catch (e) {
        print('[STORAGE] Cancel reminder on field delete: $e');
      }
    }
    p.fields.removeWhere((f) => f.id == fieldId);
    p.missions.removeWhere((m) => m.fieldId == fieldId);
    await _persistPayload(p);

    if (_uid != null) {
      final ref = _firestore
          .collection(_usersCollection)
          .doc(_uid)
          .collection(_fieldsCollection)
          .doc(fieldId);
      final subs = await ref.collection(_missionsSub).get();
      for (final d in subs.docs) {
        await d.reference.delete();
      }
      await ref.delete().catchError((e) => print('[STORAGE] Field delete FB: $e'));
    }
  }

  Future<void> syncAllMissionsToFirebase() async {
    final p = await _loadPayload();
    for (final f in p.fields) {
      _syncFieldToFirebaseAsync(f);
    }
    for (final m in p.missions) {
      _syncMissionToFirebaseAsync(m.fieldId, m);
    }
  }

  Future<void> updateMissionSchedule(
    String id,
    DateTime? scheduledAt,
    bool isScheduled,
    bool reminderEnabled,
  ) async {
    final p = await _loadPayload();
    final index = p.missions.indexWhere((m) => m.id == id);
    if (index == -1) return;

    final updated = p.missions[index].copyWith(
      scheduledAt: scheduledAt,
      isScheduled: isScheduled,
      reminderEnabled: reminderEnabled,
      status: isScheduled ? MissionStatus.scheduled : MissionStatus.pending,
    );
    p.missions[index] = updated;
    await _persistPayload(p);
    _syncMissionToFirebaseAsync(updated.fieldId, updated);

    if (isScheduled && reminderEnabled && scheduledAt != null) {
      try {
        await _notificationService.scheduleMissionReminder(updated);
      } catch (e) {
        print('[STORAGE] Notification scheduling failed: $e');
      }
    } else {
      await _notificationService.cancelMissionReminder(id);
    }
  }

  Future<void> updateMissionStatus(String id, bool completed) async {
    final p = await _loadPayload();
    final index = p.missions.indexWhere((m) => m.id == id);
    if (index == -1) return;

    final updated = p.missions[index].copyWith(
      completedAt: completed ? DateTime.now() : null,
      status: completed ? MissionStatus.completed : MissionStatus.inProgress,
    );
    p.missions[index] = updated;
    await _persistPayload(p);
    _syncMissionToFirebaseAsync(updated.fieldId, updated);
  }

  Future<void> updateMissionProgress(
      String id, int progressPercentage, int lastCompletedWaypointIndex) async {
    final p = await _loadPayload();
    final index = p.missions.indexWhere((m) => m.id == id);
    if (index == -1) return;

    final status = progressPercentage >= 100
        ? MissionStatus.completed
        : MissionStatus.inProgress;
    final updated = p.missions[index].copyWith(
      progressPercentage: progressPercentage,
      lastCompletedWaypointIndex: lastCompletedWaypointIndex,
      status: status,
      completedAt: progressPercentage >= 100 ? DateTime.now() : null,
    );
    p.missions[index] = updated;
    await _persistPayload(p);
    _syncMissionToFirebaseAsync(updated.fieldId, updated);
  }

  Future<Mission?> getMissionById(String id) async {
    final p = await _loadPayload();
    try {
      return p.missions.firstWhere((m) => m.id == id);
    } catch (_) {
      return null;
    }
  }

  Future<void> createUserProfile(String email) async {
    if (_uid == null) return;
    _firestore
        .collection(_usersCollection)
        .doc(_uid)
        .set({
          'email': email,
          'createdAt': DateTime.now().toIso8601String(),
        }, SetOptions(merge: true))
        .timeout(const Duration(seconds: 5))
        .then((_) => print('[STORAGE] User profile created'))
        .catchError((e) => print('[STORAGE] User profile creation failed: $e'));
  }

  Future<Map<String, dynamic>?> getUserProfile() async {
    if (_uid == null) return null;
    try {
      final doc = await _firestore
          .collection(_usersCollection)
          .doc(_uid)
          .get()
          .timeout(const Duration(seconds: 5));
      return doc.exists ? doc.data() : null;
    } catch (e) {
      print('[STORAGE] Get user profile failed: $e');
      return null;
    }
  }
}
