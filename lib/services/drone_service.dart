import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:flutter/foundation.dart';
import '../models/telemetry.dart';
import '../models/mission.dart';

class DroneService extends ChangeNotifier {
  static const String defaultBaseUrl = 'http://192.168.4.1:5000'; // Default Raspberry Pi hotspot IP
  String _baseUrl = defaultBaseUrl;
  IO.Socket? socket;
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
  bool _isConnecting = false;
  String? _connectionError;
  Timer? _reconnectTimer;
  
  // Mock values for demonstration (used only when not connected to Pi)
  double _altitude = 0;
  double _speed = 0;
  double _heading = 0;
  int _batteryPercentage = 0;
  int _sprayLevel = 0;

  Stream<Telemetry> get telemetryStream => _telemetryController.stream;
  bool get isConnected => _isConnected;
  bool get isConnecting => _isConnecting;
  String? get connectionError => _connectionError;
  String get baseUrl => _baseUrl;
  Mission? get currentMission => _currentMission;
  bool get isMissionActive => _isMissionActive;

  Future<void> initialize() async {
    if (_isInitialized) return;
    _isInitialized = true;
    notifyListeners();
  }

  void setMission(Mission mission) {
    _currentMission = mission;
    // Initialize position at first waypoint
    _latitude = mission.waypoints.first.position.latitude;
    _longitude = mission.waypoints.first.position.longitude;
    _missionProgress = 0;
    _waypointIndex = 0;
  }

  Future<void> connectToDrone(String ipAddress) async {
    if (_isConnecting) return;
    
    // Cancel any existing reconnect timer
    _reconnectTimer?.cancel();
    
    _isConnecting = true;
    _connectionError = null;
    notifyListeners();
    
    try {
      // Update base URL with the provided IP address
      _baseUrl = 'http://$ipAddress:5000';
      debugPrint('Attempting to connect to drone at $_baseUrl');
      
      // Test connection with a simple HTTP request
      debugPrint('Testing HTTP connection...');
      final response = await http.get(Uri.parse('$_baseUrl/status'))
          .timeout(const Duration(seconds: 5));
      
      debugPrint('HTTP response status: ${response.statusCode}');
      debugPrint('HTTP response body: ${response.body}');
      
      if (response.statusCode != 200) {
        throw Exception('Failed to connect to drone: ${response.statusCode}');
      }
      
      // Disconnect existing socket if any
      if (socket != null) {
        debugPrint('Disconnecting existing socket');
        socket!.disconnect();
        socket = null;
      }
      
      // Initialize socket connection with more robust options
      debugPrint('Initializing socket connection...');
      socket = IO.io(_baseUrl, <String, dynamic>{
        'transports': ['websocket'],
        'autoConnect': true,
        'reconnection': true,
        'reconnectionAttempts': 10,
        'reconnectionDelay': 1000,
        'reconnectionDelayMax': 5000,
        'timeout': 20000,
      });
      
      // Set up socket listeners
      _setupSocketListeners();
      
      // Wait for connection to establish or timeout
      debugPrint('Waiting for socket connection to establish...');
      await Future.delayed(const Duration(seconds: 5));
      
      if (!_isConnected) {
        throw Exception('Connection timeout');
      }
      
      debugPrint('Successfully connected to drone at $_baseUrl');
      
      // Initialize mock telemetry values
      _batteryPercentage = 100;
      _sprayLevel = 100;
    } catch (e) {
      _isConnected = false;
      _isConnecting = false;
      _connectionError = e.toString();
      notifyListeners();
      debugPrint('Error connecting to drone: $e');
      
      // Attempt to reconnect after a delay
      _reconnectTimer?.cancel();
      _reconnectTimer = Timer(const Duration(seconds: 5), () {
        if (!_isConnected && !_isConnecting) {
          debugPrint('Attempting to reconnect to drone...');
          connectToDrone(ipAddress);
        }
      });
    }
  }

  void _setupSocketListeners() {
    socket!.onConnect((_) {
      _isConnected = true;
      _isConnecting = false;
      _connectionError = null;
      notifyListeners();
      debugPrint('Socket connected to drone at $_baseUrl');
      
      // Cancel any reconnect timer
      _reconnectTimer?.cancel();
      
      // Send a test message to verify connection
      socket!.emit('test_connection', {'client': 'flutter_app'});
    });

    socket!.onDisconnect((_) {
      _isConnected = false;
      _isConnecting = false;
      notifyListeners();
      debugPrint('Socket disconnected from drone');
      
      // Attempt to reconnect after a delay
      _reconnectTimer?.cancel();
      _reconnectTimer = Timer(const Duration(seconds: 5), () {
        if (!_isConnected && !_isConnecting) {
          debugPrint('Attempting to reconnect to drone...');
          connectToDrone(_baseUrl.split(':').first);
        }
      });
    });

    socket!.onConnectError((error) {
      _isConnected = false;
      _isConnecting = false;
      _connectionError = 'Connection error: $error';
      notifyListeners();
      debugPrint('Socket connection error: $error');
    });

    socket!.on('connection_status', (data) {
      debugPrint('Connection status received: $data');
    });

    socket!.on('mission_status', (data) {
      debugPrint('Mission status received: $data');
      if (data['status'] == 'completed') {
        _isMissionActive = false;
        notifyListeners();
      }
    });

    socket!.on('telemetry', (data) {
      debugPrint('Raw telemetry received: $data');
      try {
        if (data != null) {
          // Convert data to Map<String, dynamic> if it's not already
          Map<String, dynamic> telemetryData;
          if (data is Map) {
            telemetryData = Map<String, dynamic>.from(data);
          } else if (data is String) {
            telemetryData = json.decode(data) as Map<String, dynamic>;
          } else {
            debugPrint('Unexpected telemetry data type: ${data.runtimeType}');
            return;
          }
          
          debugPrint('Parsed telemetry data: $telemetryData');
          
          final telemetry = Telemetry.fromJson(telemetryData);
          _telemetryController.add(telemetry);
          notifyListeners();
          
          // Print detailed telemetry data
          debugPrint('''
=== TELEMETRY UPDATE ===
Location: ${telemetry.latitude}, ${telemetry.longitude}
Altitude: ${telemetry.altitude}m
Speed: ${telemetry.speed}m/s
Heading: ${telemetry.heading}°
Battery: ${telemetry.batteryPercentage}%
Spray Level: ${telemetry.sprayLevel}%
Mission Progress: ${telemetry.missionProgress}%
Timestamp: ${telemetry.timestamp}
=======================
''');
        } else {
          debugPrint('Received null telemetry data');
        }
      } catch (e, stackTrace) {
        debugPrint('Error processing telemetry: $e');
        debugPrint('Stack trace: $stackTrace');
        debugPrint('Raw data: $data');
      }
    });

    socket!.onError((error) {
      debugPrint('Socket error: $error');
    });
  }

  Future<void> disconnectFromDrone() async {
    // Cancel any reconnect timer
    _reconnectTimer?.cancel();
    
    if (socket != null) {
      socket!.disconnect();
      socket = null;
    }
    
    _isConnected = false;
    _isConnecting = false;
    _connectionError = null;
    notifyListeners();
    debugPrint('Disconnected from drone');
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

    // Only send mission data if connected to Pi
    if (_isConnected && socket != null) {
      debugPrint('Starting mission with waypoints: ${missionToStart.waypoints.length}');
      
      // Convert mission to JSON and print for debugging
      final missionJson = missionToStart.toJson();
      debugPrint('Mission JSON: ${json.encode(missionJson)}');
      
      // Print first waypoint for debugging
      if (missionToStart.waypoints.isNotEmpty) {
        final firstWaypoint = missionToStart.waypoints.first;
        debugPrint('First waypoint: ${json.encode(firstWaypoint.toJson())}');
      }
      
      // Send mission data to server
      debugPrint('Emitting start_mission event...');
      socket!.emit('start_mission', missionJson);
      
      // Wait for mission status confirmation
      await Future.delayed(const Duration(seconds: 2));
      
      if (!_isMissionActive) {
        debugPrint('Mission failed to start');
        throw Exception('Mission failed to start');
      }
      
      debugPrint('Mission started successfully');
      
      // Start mock telemetry timer regardless of connection status
      _startMockTelemetry();
    } else {
      // Don't start mock telemetry if not connected
      debugPrint('Cannot start mission: Not connected to drone');
      _isMissionActive = false;
      throw Exception('Cannot start mission: Not connected to drone');
    }
  }

  void _startMockTelemetry() {
    // Cancel any existing telemetry timer
    _telemetryTimer?.cancel();
    
    // Start a new telemetry timer
    _telemetryTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!_isMissionActive) {
        timer.cancel();
        return;
      }
      
      _updateMockTelemetry();
    });
  }

  void _updateMockTelemetry() {
    if (!_isMissionActive || _currentMission == null) return;
    
    // Update position based on waypoints
    final waypoints = _currentMission!.waypoints;
    if (waypoints.isEmpty) return;
    
    // Calculate total distance and progress
    final totalWaypoints = waypoints.length;
    final progressPerWaypoint = 100 / totalWaypoints;
    
    // Move towards current waypoint
    final currentWaypoint = waypoints[_waypointIndex];
    final targetLat = currentWaypoint.position.latitude;
    final targetLng = currentWaypoint.position.longitude;
    
    // Calculate distance to target
    final latDiff = targetLat - _latitude;
    final lngDiff = targetLng - _longitude;
    final distance = sqrt(latDiff * latDiff + lngDiff * lngDiff);
    
    // Move towards target (1% of remaining distance)
    if (distance > 0.00001) {
      _latitude += latDiff * 0.01;
      _longitude += lngDiff * 0.01;
      
      // Calculate heading based on movement direction
      _heading = (atan2(lngDiff, latDiff) * 180 / pi) % 360;
    } else {
      // Reached current waypoint, move to next
      _waypointIndex = min(_waypointIndex + 1, totalWaypoints - 1);
      
      // If reached last waypoint, complete mission
      if (_waypointIndex >= totalWaypoints - 1) {
        _isMissionActive = false;
        _missionProgress = 100;
        _telemetryTimer?.cancel();
        return;
      }
    }
    
    // Update other telemetry values
    _altitude = 30 + _random.nextDouble() * 4 - 2; // 28-32m
    _speed = 5 + _random.nextDouble() * 2 - 1; // 4-7 m/s
    _batteryPercentage = max(0, _batteryPercentage - _random.nextInt(2));
    _sprayLevel = max(0, _sprayLevel - _random.nextInt(2));
    
    // Update mission progress
    _missionProgress = min(100, (_waypointIndex * progressPerWaypoint).round());
    
    // Create telemetry data
    final telemetry = Telemetry(
      latitude: _latitude,
      longitude: _longitude,
      altitude: _altitude,
      speed: _speed,
      heading: _heading,
      batteryPercentage: _batteryPercentage,
      sprayLevel: _sprayLevel,
      missionProgress: _missionProgress,
      timestamp: DateTime.now(),
    );
    
    // Add telemetry to stream
    _telemetryController.add(telemetry);
    notifyListeners();
    
    // Print telemetry data to terminal
    debugPrint('''
=== MOCK TELEMETRY UPDATE ===
Location: ${telemetry.latitude}, ${telemetry.longitude}
Altitude: ${telemetry.altitude}m
Speed: ${telemetry.speed}m/s
Heading: ${telemetry.heading}°
Battery: ${telemetry.batteryPercentage}%
Spray Level: ${telemetry.sprayLevel}%
Mission Progress: ${telemetry.missionProgress}%
Timestamp: ${telemetry.timestamp}
===========================
''');
  }

  Future<void> pauseMission() async {
    if (_isConnected && socket != null) {
      debugPrint('Pausing mission');
      socket!.emit('pause_mission');
    }
    
    // Pause mock telemetry
    _telemetryTimer?.cancel();
    _isMissionActive = false;
    notifyListeners();
  }

  Future<void> resumeMission() async {
    if (_isConnected && socket != null) {
      debugPrint('Resuming mission');
      socket!.emit('resume_mission');
    }
    
    // Resume mock telemetry
    _isMissionActive = true;
    _startMockTelemetry();
    notifyListeners();
  }

  Future<void> stopMission() async {
    if (_isConnected && socket != null) {
      debugPrint('Stopping mission');
      socket!.emit('stop_mission');
    }
    
    // Stop mock telemetry timer
    _telemetryTimer?.cancel();
    _isMissionActive = false;
    _currentMission = null;
    _missionProgress = 0;
    _waypointIndex = 0;
    
    // Clear telemetry data
    _altitude = 0;
    _speed = 0;
    _heading = 0;
    _batteryPercentage = 100; // Reset to 100%
    _sprayLevel = 100; // Reset to 100%
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
    
    notifyListeners();
  }

  Future<void> triggerEmergencyReturn() async {
    if (_isConnected && socket != null) {
      debugPrint('Triggering emergency return');
      socket!.emit('emergency_return');
    }
    await stopMission();
  }

  void dispose() {
    disconnectFromDrone();
    _telemetryTimer?.cancel();
    _reconnectTimer?.cancel();
    _telemetryController.close();
    super.dispose();
  }
} 