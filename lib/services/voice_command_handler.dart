// ...existing code...
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../main.dart'; // for appNavigatorKey
import 'drone_service.dart';
import '../providers/auth_provider.dart';
import '../models/mission.dart';
 
class VoiceCommandHandler {
  VoiceCommandHandler._private();
  static final VoiceCommandHandler instance = VoiceCommandHandler._private();
 
  BuildContext? get _ctx => appNavigatorKey.currentContext;
 
  Future<String> executeIntent(Map<String, dynamic> intent) async {
    final ctx = _ctx;
    if (ctx == null) return 'App not ready';
 
    final auth = Provider.of<AuthProvider>(ctx, listen: false);
    if (!auth.isAuthenticated) return 'Please log in first';
 
    final drone = Provider.of<DroneService>(ctx, listen: false);
 
    final action = (intent['action'] as String?)?.toLowerCase();
    if (action == null) return 'No action provided';
 
    try {
      switch (action) {
        case 'connect':
        case 'connect_drone':
          final ip = intent['ip'] as String? ?? intent['address'] as String?;
          if (ip == null || ip.isEmpty) return 'Please provide the drone IP address';
          await drone.connectToDrone(ip);
          return drone.isConnected ? 'Connected to drone at $ip' : 'Failed to connect to $ip';
 
        case 'connect_telemetry':
        case 'connect_ws':
          final addr = intent['address'] as String? ?? intent['url'] as String?;
          if (addr == null || addr.isEmpty) return 'Please provide telemetry address or URL';
          await drone.connectToTelemetryWs(addr);
          return drone.isConnected ? 'Telemetry connected' : 'Failed to connect telemetry';
 
        case 'disconnect':
        case 'disconnect_drone':
          await drone.disconnectFromDrone();
          return 'Disconnected from drone';
 
        case 'upload_mission':
          final rawMission = intent['mission'];
          final mission = await _toMission(rawMission) ?? drone.currentMission;
          if (mission == null) return 'No mission available to upload. Provide a mission first.';
          await drone.uploadMissionToAutopilot(mission);
          return 'Mission uploaded to autopilot';
 
        case 'start_mission':
        case 'takeoff':
          final rawMissionArg = intent['mission'];
          final missionToStart = await _toMission(rawMissionArg) ?? drone.currentMission;
          if (missionToStart == null) return 'No mission available to start';
          final okStart = await _confirmIfRequired(
              ctx, 'Confirm start mission${rawMissionArg != null ? '' : ' (current mission)'}?');
          if (!okStart) return 'Start mission cancelled';
          await drone.startMission(missionToStart);
          return 'Mission started';
 
        case 'pause_mission':
        case 'pause':
          await drone.pauseMission();
          return 'Mission paused';
 
        case 'resume_mission':
        case 'resume':
          await drone.resumeMission();
          return 'Mission resumed';
 
        case 'stop_mission':
        case 'stop':
          await drone.stopMission();
          return 'Mission stopped';
 
        case 'emergency_return':
        case 'return_home':
          final ok = await _confirmIfRequired(ctx, 'Trigger emergency return?');
          if (!ok) return 'Emergency return cancelled';
          await drone.triggerEmergencyReturn();
          return 'Emergency return triggered';
 
        case 'capture_image':
        case 'capture':
        case 'take_photo':
          final cmd = intent['command'] as String? ?? 'capture_image';
          await drone.sendCaptureCommand(cmd);
          return 'Capture command sent';
 
        case 'custom_command':
        case 'send_command':
          final cmdName = intent['command'] as String?;
          if (cmdName == null) return 'No command specified';
          await drone.sendCaptureCommand(cmdName);
          return 'Command "$cmdName" sent';
 
        default:
          return 'Unknown action: $action';
      }
    } catch (e) {
      return 'Error performing $action: $e';
    }
  }
 
  Future<Mission?> _toMission(dynamic raw) async {
    if (raw == null) return null;
    if (raw is Mission) return raw;
    try {
      if (raw is Map<String, dynamic>) {
        return Mission.fromJson(raw);
      }
      if (raw is String) {
        final decoded = json.decode(raw);
        if (decoded is Map<String, dynamic>) return Mission.fromJson(decoded);
      }
    } catch (e) {
      debugPrint('Failed to parse mission: $e');
    }
    return null;
  }
 
  Future<bool> _confirmIfRequired(BuildContext ctx, String message) async {
    final res = await showDialog<bool>(
      context: ctx,
      builder: (_) => AlertDialog(
        title: const Text('Confirm'),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Yes')),
        ],
      ),
    );
    return res ?? false;
  }
}
 
// ...existing code...