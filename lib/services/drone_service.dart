import 'dart:async';
import 'dart:convert';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/telemetry.dart';
import '../models/mission.dart';

class DroneService extends ChangeNotifier {
  static const String defaultBaseUrl = 'http://192.168.4.1:5000'; // Default Raspberry Pi hotspot IP
  String _baseUrl = defaultBaseUrl;
  IO.Socket? socket;
  WebSocketChannel? _wsChannel;
  StreamSubscription? _wsSubscription;
  final _telemetryController = StreamController<Telemetry>.broadcast();
  bool _isConnected = false;
  Mission? _currentMission;
  bool _isInitialized = false;
  bool _isMissionActive = false;
  bool _isConnecting = false;
  String? _connectionError;
  Timer? _reconnectTimer;
  Timer? _connectionValidationTimer;

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
      
      // Disconnect any existing WS telemetry channel
      await _wsSubscription?.cancel();
      _wsSubscription = null;
      await _wsChannel?.sink.close();
      _wsChannel = null;
      
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
      
      // Start connection validation timer
      _startConnectionValidation();
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

  Future<void> connectToTelemetryWs(String ipAddress) async {
    if (_isConnecting) return;

    _isConnecting = true;
    _connectionError = null;
    notifyListeners();

    try {
      // Close any existing connections (socket.io or WS)
      if (socket != null) {
        socket!.disconnect();
        socket = null;
      }
      await _wsSubscription?.cancel();
      _wsSubscription = null;
      await _wsChannel?.sink.close();
      _wsChannel = null;

      final uri = Uri.parse('ws://$ipAddress:5001/ws/telemetry');
      debugPrint('Connecting to WS telemetry at $uri');
      
      // Test HTTP connection first to validate the server exists
      final httpResponse = await http.get(Uri.parse('http://$ipAddress:5001/status'))
          .timeout(const Duration(seconds: 5));
      
      if (httpResponse.statusCode != 200) {
        throw Exception('Server not responding: ${httpResponse.statusCode}');
      }
      
      _wsChannel = WebSocketChannel.connect(uri);

      _wsSubscription = _wsChannel!.stream.listen((message) {
        try {
          Map<String, dynamic> telemetryData;
          if (message is String) {
            telemetryData = json.decode(message) as Map<String, dynamic>;
          } else if (message is Map) {
            telemetryData = Map<String, dynamic>.from(message);
          } else {
            debugPrint('Unexpected WS telemetry type: ${message.runtimeType}');
            return;
          }
          
          // Handle different message types
          final messageType = telemetryData['type'];
          if (messageType == 'connection_status') {
            debugPrint('Connection status: ${telemetryData['status']}');
            if (telemetryData['status'] == 'connected') {
              _isConnected = true;
              _isConnecting = false;
              _connectionError = null;
              notifyListeners();
              debugPrint('WS telemetry connection confirmed');
              _startConnectionValidation();
            }
          } else if (messageType == 'telemetry') {
            final telemetry = Telemetry.fromJson(telemetryData);
            _telemetryController.add(telemetry);
            notifyListeners();
            debugPrint('WS telemetry received: $telemetryData');
          } else if (messageType == 'mission_status') {
            debugPrint('Mission status: ${telemetryData['status']}');
            // Handle mission status updates
          }
        } catch (e, st) {
          debugPrint('Error processing WS message: $e');
          debugPrint('Stack trace: $st');
        }
      }, onDone: () {
        _isConnected = false;
        _isConnecting = false;
        notifyListeners();
        debugPrint('WS telemetry connection closed');
        _stopConnectionValidation();
      }, onError: (error) {
        _isConnected = false;
        _isConnecting = false;
        _connectionError = 'WS error: $error';
        notifyListeners();
        debugPrint('WS telemetry error: $error');
        _stopConnectionValidation();
      });

      _baseUrl = 'ws://$ipAddress:5001';
      
      // Wait for connection confirmation
      await Future.delayed(const Duration(seconds: 3));
      
      if (!_isConnected) {
        throw Exception('WebSocket connection timeout');
      }
      
      debugPrint('Connected to WS telemetry at $uri');
    } catch (e) {
      _isConnected = false;
      _isConnecting = false;
      _connectionError = e.toString();
      notifyListeners();
      debugPrint('Error connecting to WS telemetry: $e');
    }
  }

  void _startConnectionValidation() {
    _connectionValidationTimer?.cancel();
    _connectionValidationTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      if (!_isConnected) {
        timer.cancel();
        return;
      }
      
      // Send a ping to validate connection is still alive
      if (_wsChannel != null) {
        try {
          _wsChannel!.sink.add(json.encode({'type': 'ping'}));
        } catch (e) {
          debugPrint('Connection validation failed: $e');
          _isConnected = false;
          notifyListeners();
          timer.cancel();
        }
      }
    });
  }

  void _stopConnectionValidation() {
    _connectionValidationTimer?.cancel();
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
      
      // Start connection validation
      _startConnectionValidation();
    });

    socket!.onDisconnect((_) {
      _isConnected = false;
      _isConnecting = false;
      notifyListeners();
      debugPrint('Socket disconnected from drone');
      _stopConnectionValidation();
      
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
      _stopConnectionValidation();
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
    _stopConnectionValidation();
    
    if (socket != null) {
      socket!.disconnect();
      socket = null;
    }
    
    await _wsSubscription?.cancel();
    _wsSubscription = null;
    await _wsChannel?.sink.close();
    _wsChannel = null;
    
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
    _isMissionActive = true;

    // Start mission if connected to either Socket.IO server or WS telemetry server
    if (_isConnected && (socket != null || _wsChannel != null)) {
      debugPrint('Starting mission with waypoints: ${missionToStart.waypoints.length}');
      
      // Convert mission to JSON and print for debugging
      final missionJson = missionToStart.toJson();
      debugPrint('Mission JSON: ${json.encode(missionJson)}');
      
      // Print first waypoint for debugging
      if (missionToStart.waypoints.isNotEmpty) {
        final firstWaypoint = missionToStart.waypoints.first;
        debugPrint('First waypoint: ${json.encode(firstWaypoint.toJson())}');
      }
      
      if (socket != null) {
        // Send mission data to Socket.IO server
        debugPrint('Emitting start_mission event...');
        socket!.emit('start_mission', missionJson);
        
        // Wait for mission status confirmation
        await Future.delayed(const Duration(seconds: 2));
        
        if (!_isMissionActive) {
          debugPrint('Mission failed to start');
          throw Exception('Mission failed to start');
        }
        
        debugPrint('Mission started successfully');
      } else if (_wsChannel != null) {
        // Send mission data to WebSocket server
        debugPrint('Sending start_mission via WebSocket...');
        final message = {
          'type': 'start_mission',
          'waypoints': missionJson['waypoints'],
        };
        _wsChannel!.sink.add(json.encode(message));
        
        // Wait for mission status confirmation
        await Future.delayed(const Duration(seconds: 2));
        
        if (!_isMissionActive) {
          debugPrint('Mission failed to start');
          throw Exception('Mission failed to start');
        }
        
        debugPrint('Mission started successfully');
      }
    } else {
      // Don't start mission if not connected
      debugPrint('Cannot start mission: Not connected to drone');
      _isMissionActive = false;
      throw Exception('Cannot start mission: Not connected to drone');
    }
  }

  Future<void> pauseMission() async {
    if (_isConnected && socket != null) {
      debugPrint('Pausing mission via Socket.IO');
      socket!.emit('pause_mission');
    } else if (_isConnected && _wsChannel != null) {
      debugPrint('Pausing mission via WebSocket');
      _wsChannel!.sink.add(json.encode({'type': 'pause_mission'}));
    }
    
    _isMissionActive = false;
    notifyListeners();
  }

  Future<void> resumeMission() async {
    if (_isConnected && socket != null) {
      debugPrint('Resuming mission via Socket.IO');
      socket!.emit('resume_mission');
    } else if (_isConnected && _wsChannel != null) {
      debugPrint('Resuming mission via WebSocket');
      _wsChannel!.sink.add(json.encode({'type': 'resume_mission'}));
    }
    
    _isMissionActive = true;
    notifyListeners();
  }

  Future<void> stopMission() async {
    if (_isConnected && socket != null) {
      debugPrint('Stopping mission via Socket.IO');
      socket!.emit('stop_mission');
    } else if (_isConnected && _wsChannel != null) {
      debugPrint('Stopping mission via WebSocket');
      _wsChannel!.sink.add(json.encode({'type': 'stop_mission'}));
    }
    
    // Stop mission locally
    _isMissionActive = false;
    _currentMission = null;
    notifyListeners();
  }

  Future<void> triggerEmergencyReturn() async {
    if (_isConnected && socket != null) {
      debugPrint('Triggering emergency return via Socket.IO');
      socket!.emit('emergency_return');
    } else if (_isConnected && _wsChannel != null) {
      debugPrint('Triggering emergency return via WebSocket');
      _wsChannel!.sink.add(json.encode({'type': 'emergency_return'}));
    }
    await stopMission();
  }

  @override
  void dispose() {
    disconnectFromDrone();
    _reconnectTimer?.cancel();
    _connectionValidationTimer?.cancel();
    _telemetryController.close();
    super.dispose();
  }
}
