import '../models/mission.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'notification_service.dart';

class MissionStorage {
  static const String _missionsCollection = 'missions';
  static const String _usersCollection = 'users';
  static const String _localMissionsKey = 'cached_missions';

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final NotificationService _notificationService = NotificationService();

  String? get _uid => _auth.currentUser?.uid;

  /// Save mission to local cache
  Future<void> _saveToLocal(Mission mission) async {
    final prefs = await SharedPreferences.getInstance();
    final missions = await _getLocalMissions();
    
    // Update or add mission
    missions.removeWhere((m) => m.id == mission.id);
    missions.add(mission);
    
    // Save to local storage
    final jsonList = missions.map((m) => m.toJson()).toList();
    await prefs.setString(_localMissionsKey, json.encode(jsonList));
  }
  
  /// Get missions from local cache
  Future<List<Mission>> _getLocalMissions() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_localMissionsKey);
    if (jsonString == null) return [];
    
    final List<dynamic> jsonList = json.decode(jsonString);
    return jsonList.map((j) => Mission.fromJson(j as Map<String, dynamic>)).toList();
  }
  
  /// Sync to Firebase (when online)
  Future<void> _syncToFirebase(Mission mission) async {
    if (_uid == null) return;
    
    try {
      await _firestore
          .collection(_usersCollection)
          .doc(_uid)
          .collection(_missionsCollection)
          .doc(mission.id)
          .set(mission.toJson());
    } catch (e) {
      print('[STORAGE] Firebase sync failed: $e (will retry when online)');
    }
  }
  
  Future<void> saveMission(Mission mission) async {
    // Always save to local cache first
    await _saveToLocal(mission);
    
    // Try to sync to Firebase (may fail if offline)
    await _syncToFirebase(mission);

    // Schedule notification if mission is scheduled with reminder
    if (mission.isScheduled && mission.reminderEnabled) {
      await _notificationService.scheduleMissionReminder(mission);
    }
  }

  Future<List<Mission>> getMissions() async {
    // Always return from local cache (works offline)
    final localMissions = await _getLocalMissions();
    
    // Try to fetch from Firebase and update cache (if online)
    if (_uid != null) {
      try {
        final snapshot = await _firestore
            .collection(_usersCollection)
            .doc(_uid)
            .collection(_missionsCollection)
            .get();
        
        if (snapshot.docs.isNotEmpty) {
          final firebaseMissions = snapshot.docs.map((doc) => Mission.fromJson(doc.data())).toList();
          
          // Merge with local missions (local takes precedence for progress updates)
          final mergedMap = <String, Mission>{};
          for (var m in firebaseMissions) {
            mergedMap[m.id] = m;
          }
          for (var m in localMissions) {
            // Local mission takes precedence if it has more recent progress
            if (mergedMap.containsKey(m.id)) {
              final fbMission = mergedMap[m.id]!;
              if (m.progressPercentage > fbMission.progressPercentage) {
                mergedMap[m.id] = m;
              }
            } else {
              mergedMap[m.id] = m;
            }
          }
          
          // Update local cache with merged data
          final prefs = await SharedPreferences.getInstance();
          final jsonList = mergedMap.values.map((m) => m.toJson()).toList();
          await prefs.setString(_localMissionsKey, json.encode(jsonList));
          
          return mergedMap.values.toList();
        }
      } catch (e) {
        print('[STORAGE] Firebase fetch failed: $e (using local cache)');
      }
    }
    
    return localMissions;
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
    // Cancel notification before deleting
    await _notificationService.cancelMissionReminder(id);
    
    // Delete from local cache
    final missions = await _getLocalMissions();
    missions.removeWhere((m) => m.id == id);
    
    final prefs = await SharedPreferences.getInstance();
    final jsonList = missions.map((m) => m.toJson()).toList();
    await prefs.setString(_localMissionsKey, json.encode(jsonList));
    
    // Delete from Firebase (if online)
    if (_uid != null) {
      try {
        await _firestore
            .collection(_usersCollection)
            .doc(_uid)
            .collection(_missionsCollection)
            .doc(id)
            .delete();
      } catch (e) {
        print('[STORAGE] Firebase delete failed: $e');
      }
    }
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
    // Update in local cache
    final missions = await _getLocalMissions();
    final index = missions.indexWhere((m) => m.id == id);
    if (index != -1) {
      final updatedMission = missions[index].copyWith(
        completedAt: completed ? DateTime.now() : null,
        status: completed ? MissionStatus.completed : MissionStatus.inProgress,
      );
      missions[index] = updatedMission;
      
      final prefs = await SharedPreferences.getInstance();
      final jsonList = missions.map((m) => m.toJson()).toList();
      await prefs.setString(_localMissionsKey, json.encode(jsonList));
      
      // Sync to Firebase
      await _syncToFirebase(updatedMission);
    }
  }
  
  /// Update mission progress (waypoint completion)
  Future<void> updateMissionProgress(String id, int progressPercentage, int lastCompletedWaypointIndex) async {
    // Update in local cache
    final missions = await _getLocalMissions();
    final index = missions.indexWhere((m) => m.id == id);
    if (index != -1) {
      final status = progressPercentage >= 100 ? MissionStatus.completed : MissionStatus.inProgress;
      final updatedMission = missions[index].copyWith(
        progressPercentage: progressPercentage,
        lastCompletedWaypointIndex: lastCompletedWaypointIndex,
        status: status,
        completedAt: progressPercentage >= 100 ? DateTime.now() : null,
      );
      missions[index] = updatedMission;
      
      final prefs = await SharedPreferences.getInstance();
      final jsonList = missions.map((m) => m.toJson()).toList();
      await prefs.setString(_localMissionsKey, json.encode(jsonList));
      
      // Sync to Firebase
      await _syncToFirebase(updatedMission);
    }
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