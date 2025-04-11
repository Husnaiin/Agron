import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import '../models/telemetry.dart';
import '../models/mission.dart';

class DroneService {
  static const String baseUrl = 'http://192.168.4.1:5000'; // Raspberry Pi hotspot IP
  late IO.Socket socket;
  final _random = Random();
  Timer? _telemetryTimer;
  final _telemetryController = StreamController<Telemetry>.broadcast();
  bool _isConnected = false;
  Mission? _currentMission;
  double _latitude = 0;
  double _longitude = 0;
  bool _isInitialized = false;
  int _missionProgress = 0;
  int _waypointIndex = 0;
  bool _isMissionActive = false;
  
  // Mock values for demonstration
  double _altitude = 100;
  double _speed = 0;
  double _heading = 0;
  int _batteryPercentage = 100;
  int _sprayLevel = 100;

  Stream<Telemetry> get telemetryStream => _telemetryController.stream;
  bool get isConnected => _isInitialized;
  Mission? get currentMission => _currentMission;
  bool get isMissionActive => _isMissionActive;

  Future<void> initialize() async {
    if (_isInitialized) return;
    _isInitialized = true;
  }

  void setMission(Mission mission) {
    _currentMission = mission;
    // Initialize position at first waypoint
    _latitude = mission.waypoints.first.position.latitude;
    _longitude = mission.waypoints.first.position.longitude;
    _missionProgress = 0;
    _waypointIndex = 0;
  }

  Future<void> startMission(Mission? mission) async {
    if (!_isInitialized) throw Exception('DroneService not initialized');
    
    final missionToStart = mission ?? _currentMission;
    if (missionToStart == null || missionToStart.waypoints.isEmpty) {
      throw Exception('No valid mission available');
    }
    
    _currentMission = missionToStart;
    _waypointIndex = 0;
    _missionProgress = 0;
    _latitude = missionToStart.waypoints.first.position.latitude;
    _longitude = missionToStart.waypoints.first.position.longitude;
    _isMissionActive = true;

    // Start mock telemetry updates
    _telemetryTimer?.cancel();
    _telemetryTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _updateMockTelemetry();
    });
  }

  Future<void> pauseMission() async {
    _telemetryTimer?.cancel();
  }

  Future<void> resumeMission() async {
    if (_currentMission != null && _isMissionActive) {
      _telemetryTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        _updateMockTelemetry();
      });
    }
  }

  Future<void> stopMission() async {
    _telemetryTimer?.cancel();
    _isMissionActive = false;
    _currentMission = null;
    _missionProgress = 0;
    _waypointIndex = 0;
    // Clear telemetry data
    _altitude = 0;
    _speed = 0;
    _heading = 0;
    _batteryPercentage = 0;
    _sprayLevel = 0;
    _latitude = 0;
    _longitude = 0;
    // Send a final telemetry update with cleared values
    _telemetryController.add(Telemetry(
      latitude: _latitude,
      longitude: _longitude,
      altitude: _altitude,
      speed: _speed,
      heading: _heading,
      batteryPercentage: _batteryPercentage,
      sprayLevel: _sprayLevel,
      missionProgress: _missionProgress,
      timestamp: DateTime.now(),
    ));
  }

  Future<void> triggerEmergencyReturn() async {
    await stopMission();
  }

  void _updateMockTelemetry() {
    if (_currentMission == null || !_isMissionActive) return;

    // Simulate random movement and progress
    _latitude += (_random.nextDouble() - 0.5) * 0.0001;
    _longitude += (_random.nextDouble() - 0.5) * 0.0001;
    
    // Update mission progress
    _missionProgress = min(100, _missionProgress + _random.nextInt(5));
    if (_missionProgress >= 100) {
      stopMission();
    }

    final telemetry = Telemetry(
      latitude: _latitude,
      longitude: _longitude,
      altitude: 30 + (_random.nextDouble() - 0.5) * 2,
      speed: 5 + (_random.nextDouble() - 0.5) * 2,
      heading: _random.nextDouble() * 360,
      batteryPercentage: 100,
      sprayLevel: 100,
      missionProgress: _missionProgress,
      timestamp: DateTime.now(),
    );

    _telemetryController.add(telemetry);
  }

  void connect() {
    socket = IO.io(baseUrl, <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': true,
    });

    socket.onConnect((_) {
      _isConnected = true;
      print('Connected to drone');
    });

    socket.onDisconnect((_) {
      _isConnected = false;
      print('Disconnected from drone');
    });

    socket.on('telemetry', (data) {
      final telemetry = Telemetry.fromJson(data);
      _telemetryController.add(telemetry);
    });
  }

  void dispose() {
    socket.disconnect();
    _telemetryTimer?.cancel();
    _telemetryController.close();
  }
} 