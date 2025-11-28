import '../models/mission.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'notification_service.dart';

class MissionStorage {
  static const String _missionsCollection = 'missions';
  static const String _usersCollection = 'users';

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final NotificationService _notificationService = NotificationService();

  String? get _uid => _auth.currentUser?.uid;

  Future<void> saveMission(Mission mission) async {
    if (_uid == null) throw Exception('User not logged in');
    
    await _firestore
        .collection(_usersCollection)
        .doc(_uid)
        .collection(_missionsCollection)
        .doc(mission.id)
        .set(mission.toJson());

    // Schedule notification if mission is scheduled with reminder
    if (mission.isScheduled && mission.reminderEnabled) {
      await _notificationService.scheduleMissionReminder(mission);
    }
  }

  Future<List<Mission>> getMissions() async {
    if (_uid == null) throw Exception('User not logged in');
    final snapshot = await _firestore
        .collection(_usersCollection)
        .doc(_uid)
        .collection(_missionsCollection)
        .get();
    return snapshot.docs.map((doc) => Mission.fromJson(doc.data())).toList();
  }

  Future<List<Mission>> getScheduledMissions() async {
    if (_uid == null) throw Exception('User not logged in');
    final snapshot = await _firestore
        .collection(_usersCollection)
        .doc(_uid)
        .collection(_missionsCollection)
        .where('isScheduled', isEqualTo: true)
        .get();
    return snapshot.docs.map((doc) => Mission.fromJson(doc.data())).toList();
  }

  Future<void> deleteMission(String id) async {
    if (_uid == null) throw Exception('User not logged in');
    
    // Cancel notification before deleting
    await _notificationService.cancelMissionReminder(id);
    
    await _firestore
        .collection(_usersCollection)
        .doc(_uid)
        .collection(_missionsCollection)
        .doc(id)
        .delete();
  }

  Future<void> updateMissionSchedule(
    String id, 
    DateTime? scheduledAt, 
    bool isScheduled,
    bool reminderEnabled,
  ) async {
    if (_uid == null) throw Exception('User not logged in');
    
    final docRef = _firestore
        .collection(_usersCollection)
        .doc(_uid)
        .collection(_missionsCollection)
        .doc(id);
    
    await docRef.update({
      'scheduledAt': scheduledAt?.toIso8601String(),
      'isScheduled': isScheduled,
      'reminderEnabled': reminderEnabled,
      'status': isScheduled ? 'scheduled' : 'pending',
    });

    // Update notification
    if (isScheduled && reminderEnabled && scheduledAt != null) {
      final mission = Mission.fromJson((await docRef.get()).data()!);
      await _notificationService.scheduleMissionReminder(mission);
    } else {
      await _notificationService.cancelMissionReminder(id);
    }
  }

  Future<void> updateMissionStatus(String id, bool completed) async {
    if (_uid == null) throw Exception('User not logged in');
    final docRef = _firestore
        .collection(_usersCollection)
        .doc(_uid)
        .collection(_missionsCollection)
        .doc(id);
    await docRef.update({
      'completedAt': completed ? DateTime.now().toIso8601String() : null,
      'status': completed ? 'completed' : 'inProgress',
    });
  }

  Future<void> createUserProfile(String email) async {
    if (_uid == null) throw Exception('User not logged in');
    await _firestore.collection(_usersCollection).doc(_uid).set({
      'email': email,
      'createdAt': DateTime.now().toIso8601String(),
    }, SetOptions(merge: true));
  }

  Future<Map<String, dynamic>?> getUserProfile() async {
    if (_uid == null) throw Exception('User not logged in');
    final doc = await _firestore.collection(_usersCollection).doc(_uid).get();
    return doc.exists ? doc.data() : null;
  }
}