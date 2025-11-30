import '../models/mission.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'notification_service.dart';

/// Offline-first mission storage with Firebase sync
/// 
/// This service is designed to work seamlessly without internet connection:
/// - All read/write operations work on local cache (SharedPreferences)
/// - Firebase operations are non-blocking with 5-second timeouts
/// - Missions can be created, updated, and sent to drone while offline
/// - Firebase sync happens automatically in background when online
/// - Local cache takes precedence for progress updates
/// 
/// Usage:
/// - saveMission: Always succeeds locally, syncs to Firebase in background
/// - getMissions: Returns local cache immediately, updates from Firebase if online
/// - updateMissionProgress: Critical for flight tracking, never blocks on Firebase
/// - syncAllMissionsToFirebase: Manually trigger sync when internet becomes available
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
  
  /// Sync to Firebase (when online) - non-blocking background operation
  void _syncToFirebaseAsync(Mission mission) {
    if (_uid == null) return;
    
    // Fire and forget - don't await, don't block
    _firestore
        .collection(_usersCollection)
        .doc(_uid)
        .collection(_missionsCollection)
        .doc(mission.id)
        .set(mission.toJson())
        .timeout(const Duration(seconds: 5))
        .then((_) {
          print('[STORAGE] Firebase sync successful for mission ${mission.id}');
        })
        .catchError((e) {
          print('[STORAGE] Firebase sync failed: $e (will retry later)');
        });
  }
  
  Future<void> saveMission(Mission mission) async {
    // ALWAYS save to local cache first (this must succeed)
    await _saveToLocal(mission);
    print('[STORAGE] Mission saved to local cache: ${mission.id}');
    
    // Try to sync to Firebase in background (non-blocking, may fail if offline)
    _syncToFirebaseAsync(mission);

    // Schedule notification if mission is scheduled with reminder
    if (mission.isScheduled && mission.reminderEnabled) {
      try {
        await _notificationService.scheduleMissionReminder(mission);
      } catch (e) {
        print('[STORAGE] Notification scheduling failed: $e');
      }
    }
  }

  Future<List<Mission>> getMissions() async {
    // Always return from local cache (works offline)
    final localMissions = await _getLocalMissions();
    print('[STORAGE] Loaded ${localMissions.length} missions from local cache');
    
    // Try to fetch from Firebase and update cache (if online)
    if (_uid != null) {
      try {
        final snapshot = await _firestore
            .collection(_usersCollection)
            .doc(_uid)
            .collection(_missionsCollection)
            .get()
            .timeout(const Duration(seconds: 5));
        
        if (snapshot.docs.isNotEmpty) {
          final firebaseMissions = snapshot.docs.map((doc) => Mission.fromJson(doc.data())).toList();
          print('[STORAGE] Fetched ${firebaseMissions.length} missions from Firebase');
          
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
    // Get from local cache (works offline)
    final allMissions = await _getLocalMissions();
    final scheduledMissions = allMissions.where((m) => m.isScheduled).toList();
    
    // Try to fetch from Firebase and update cache (if online)
    if (_uid != null) {
      try {
        final snapshot = await _firestore
            .collection(_usersCollection)
            .doc(_uid)
            .collection(_missionsCollection)
            .where('isScheduled', isEqualTo: true)
            .get()
            .timeout(const Duration(seconds: 5));
        
        if (snapshot.docs.isNotEmpty) {
          final firebaseMissions = snapshot.docs.map((doc) => Mission.fromJson(doc.data())).toList();
          
          // Update local cache with Firebase data
          final allMissionsMap = <String, Mission>{};
          for (var m in allMissions) {
            allMissionsMap[m.id] = m;
          }
          for (var m in firebaseMissions) {
            allMissionsMap[m.id] = m;
          }
          
          final prefs = await SharedPreferences.getInstance();
          final jsonList = allMissionsMap.values.map((m) => m.toJson()).toList();
          await prefs.setString(_localMissionsKey, json.encode(jsonList));
          
          return firebaseMissions;
        }
      } catch (e) {
        print('[STORAGE] Firebase fetch scheduled missions failed: $e (using local cache)');
      }
    }
    
    return scheduledMissions;
  }

  Future<void> deleteMission(String id) async {
    // Cancel notification before deleting
    try {
      await _notificationService.cancelMissionReminder(id);
    } catch (e) {
      print('[STORAGE] Notification cancel failed: $e');
    }
    
    // Delete from local cache
    final missions = await _getLocalMissions();
    missions.removeWhere((m) => m.id == id);
    
    final prefs = await SharedPreferences.getInstance();
    final jsonList = missions.map((m) => m.toJson()).toList();
    await prefs.setString(_localMissionsKey, json.encode(jsonList));
    print('[STORAGE] Mission deleted from local cache: $id');
    
    // Delete from Firebase (non-blocking, if online)
    if (_uid != null) {
      _firestore
          .collection(_usersCollection)
          .doc(_uid)
          .collection(_missionsCollection)
          .doc(id)
          .delete()
          .timeout(const Duration(seconds: 5))
          .then((_) {
            print('[STORAGE] Mission deleted from Firebase: $id');
          })
          .catchError((e) {
            print('[STORAGE] Firebase delete failed: $e (will retry later)');
          });
    }
  }
  
  /// Manually sync all local missions to Firebase (call when internet becomes available)
  Future<void> syncAllMissionsToFirebase() async {
    final localMissions = await _getLocalMissions();
    print('[STORAGE] Syncing ${localMissions.length} missions to Firebase...');
    
    for (var mission in localMissions) {
      _syncToFirebaseAsync(mission);
    }
  }

  Future<void> updateMissionSchedule(
    String id, 
    DateTime? scheduledAt, 
    bool isScheduled,
    bool reminderEnabled,
  ) async {
    // Update in local cache first
    final missions = await _getLocalMissions();
    final index = missions.indexWhere((m) => m.id == id);
    if (index != -1) {
      final updatedMission = missions[index].copyWith(
        scheduledAt: scheduledAt,
        isScheduled: isScheduled,
        reminderEnabled: reminderEnabled,
        status: isScheduled ? MissionStatus.scheduled : MissionStatus.pending,
      );
      missions[index] = updatedMission;
      
      final prefs = await SharedPreferences.getInstance();
      final jsonList = missions.map((m) => m.toJson()).toList();
      await prefs.setString(_localMissionsKey, json.encode(jsonList));
      print('[STORAGE] Mission schedule updated in local cache');
      
      // Sync to Firebase (non-blocking)
      _syncToFirebaseAsync(updatedMission);
      
      // Update notification
      if (isScheduled && reminderEnabled && scheduledAt != null) {
        try {
          await _notificationService.scheduleMissionReminder(updatedMission);
        } catch (e) {
          print('[STORAGE] Notification scheduling failed: $e');
        }
      } else {
        await _notificationService.cancelMissionReminder(id);
      }
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
      
      // Sync to Firebase (non-blocking)
      _syncToFirebaseAsync(updatedMission);
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
      
      // Sync to Firebase (non-blocking)
      _syncToFirebaseAsync(updatedMission);
    }
  }

  /// Get mission by ID from local cache (works offline)
  Future<Mission?> getMissionById(String id) async {
    final missions = await _getLocalMissions();
    try {
      return missions.firstWhere((m) => m.id == id);
    } catch (e) {
      return null;
    }
  }

  Future<void> createUserProfile(String email) async {
    if (_uid == null) return;
    
    // Non-blocking Firebase operation
    _firestore.collection(_usersCollection).doc(_uid).set({
      'email': email,
      'createdAt': DateTime.now().toIso8601String(),
    }, SetOptions(merge: true))
    .timeout(const Duration(seconds: 5))
    .then((_) {
      print('[STORAGE] User profile created');
    })
    .catchError((e) {
      print('[STORAGE] User profile creation failed: $e');
    });
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