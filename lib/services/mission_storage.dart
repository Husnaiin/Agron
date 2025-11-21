import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/mission.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class MissionStorage {
  static const String _missionsCollection = 'missions';
  static const String _usersCollection = 'users';

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  String? get _uid => _auth.currentUser?.uid;

  Future<void> saveMission(Mission mission) async {
    if (_uid == null) throw Exception('User not logged in');
    await _firestore
        .collection(_usersCollection)
        .doc(_uid)
        .collection(_missionsCollection)
        .doc(mission.id)
        .set(mission.toJson());
  }

  Future<List<Mission>> getMissions() async {
    if (_uid == null) throw Exception('User not logged in');
    final snapshot = await _firestore
        .collection(_usersCollection)
        .doc(_uid)
        .collection(_missionsCollection)
        .get();
    return snapshot.docs
        .map((doc) => Mission.fromJson(doc.data()))
        .toList();
  }

  Future<void> deleteMission(String id) async {
    if (_uid == null) throw Exception('User not logged in');
    await _firestore
        .collection(_usersCollection)
        .doc(_uid)
        .collection(_missionsCollection)
        .doc(id)
        .delete();
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

  // User profile support
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
