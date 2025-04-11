import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/mission.dart';

class MissionStorage {
  static const String _missionsKey = 'saved_missions';

  Future<void> saveMission(Mission mission) async {
    final prefs = await SharedPreferences.getInstance();
    final missions = await getMissions();
    missions.add(mission);
    await prefs.setString(_missionsKey, jsonEncode(
      missions.map((m) => m.toJson()).toList(),
    ));
  }

  Future<List<Mission>> getMissions() async {
    final prefs = await SharedPreferences.getInstance();
    final missionsJson = prefs.getString(_missionsKey);
    if (missionsJson == null) return [];

    final List<dynamic> decoded = jsonDecode(missionsJson);
    return decoded.map((json) => Mission.fromJson(json)).toList();
  }

  Future<void> deleteMission(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final missions = await getMissions();
    missions.removeWhere((m) => m.id == id);
    await prefs.setString(_missionsKey, jsonEncode(
      missions.map((m) => m.toJson()).toList(),
    ));
  }

  Future<void> updateMissionStatus(String id, bool completed) async {
    final prefs = await SharedPreferences.getInstance();
    final missions = await getMissions();
    final index = missions.indexWhere((m) => m.id == id);
    if (index != -1) {
      final updatedMission = Mission(
        id: missions[index].id,
        name: missions[index].name,
        waypoints: missions[index].waypoints,
        defaultAltitude: missions[index].defaultAltitude,
        defaultSprayRate: missions[index].defaultSprayRate,
        createdAt: missions[index].createdAt,
        completedAt: completed ? DateTime.now() : null,
        status: completed ? MissionStatus.completed : MissionStatus.inProgress,
      );
      missions[index] = updatedMission;
      await prefs.setString(_missionsKey, jsonEncode(
        missions.map((m) => m.toJson()).toList(),
      ));
    }
  }
} 