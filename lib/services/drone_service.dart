import 'dart:async';
import 'dart:convert';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/telemetry.dart';
import '../models/mission.dart';
import 'package:latlong2/latlong.dart';
import 'dart:math';

class DroneService extends ChangeNotifier {
  static const String defaultBaseUrl =
      'http://192.168.4.1:5000'; // Default Raspberry Pi hotspot IP
  String _baseUrl = defaultBaseUrl;
  IO.Socket? socket;
  WebSocketChannel? _wsChannel;
  StreamSubscription? _wsSubscription;
  final _telemetryController = StreamController<Telemetry>.broadcast();
  bool _isConnected = false;
  Mission? _currentMission;
  String _selectedMissionType = 'inspection';
  bool _isInitialized = false;
  bool _isMissionActive = false;
  bool _isConnecting = false;
  String? _connectionError;
  Timer? _reconnectTimer;
  Timer? _connectionValidationTimer;
  String? _lastIpAddress;
  bool _userInitiatedDisconnect = false;
  bool _isMissionUploaded = false;
  bool _isMissionFromHistory = false;
  double? _targetAltitude;
  double? _targetSpeed;

  Stream<Telemetry> get telemetryStream => _telemetryController.stream;
  bool get isConnected => _isConnected;
  bool get isConnecting => _isConnecting;
  String? get connectionError => _connectionError;
  String get baseUrl => _baseUrl;
  Mission? get currentMission => _currentMission;
  bool get isMissionActive => _isMissionActive;
  String get selectedMissionType => _selectedMissionType;
  bool get isMissionUploaded => _isMissionUploaded;
  bool get isMissionFromHistory => _isMissionFromHistory;
  double? get targetAltitude => _targetAltitude;
  double? get targetSpeed => _targetSpeed;

  void setTargetAltitude(double? altitude) {
    _targetAltitude = altitude;
    notifyListeners();
  }

  void setTargetSpeed(double? speed) {
    _targetSpeed = speed;
    notifyListeners();
  }

  void setSelectedMissionType(String type) {
    if (_selectedMissionType == type) return;
    _selectedMissionType = type;
    notifyListeners();
  }

  Future<void> initialize() async {
    if (_isInitialized) return;
    _isInitialized = true;
    notifyListeners();
  }

  void setMission(Mission mission, {bool fromHistory = false}) {
    _currentMission = mission;
    _isMissionFromHistory = fromHistory;
    // Reset upload status when new mission is set (unless it's from history and already uploaded)
    if (!fromHistory) {
      _isMissionUploaded = false;
    }
    notifyListeners();
  }

  // Compute convex hull of points
  List<LatLng> _computeConvexHull(List<LatLng> points) {
    if (points.length <= 3) return List<LatLng>.from(points);
    int compare(LatLng a, LatLng b) {
      if (a.longitude == b.longitude) {
        return a.latitude.compareTo(b.latitude);
      }
      return a.longitude.compareTo(b.longitude);
    }

    double cross(LatLng o, LatLng a, LatLng b) {
      return (a.longitude - o.longitude) * (b.latitude - o.latitude) -
          (a.latitude - o.latitude) * (b.longitude - o.longitude);
    }

    final sorted = List<LatLng>.from(points)..sort(compare);
    final List<LatLng> lower = [];
    for (final p in sorted) {
      while (lower.length >= 2 &&
          cross(lower[lower.length - 2], lower.last, p) <= 0) {
        lower.removeLast();
      }
      lower.add(p);
    }
    final List<LatLng> upper = [];
    for (int i = sorted.length - 1; i >= 0; i--) {
      final p = sorted[i];
      while (upper.length >= 2 &&
          cross(upper[upper.length - 2], upper.last, p) <= 0) {
        upper.removeLast();
      }
      upper.add(p);
    }
    lower.removeLast();
    upper.removeLast();
    return [...lower, ...upper];
  }

  // Coverage path generator (same spacing policy as map view)
  ({
    double footprintWidthM,
    double footprintHeightM,
    double acrossTrackSpacingM,
    double alongTrackSpacingM
  }) _computeFootprintAndSpacing({
    required double altitudeM,
    double horizontalFovDeg = 62.2,
    double verticalFovDeg = 48.8,
    double forwardOverlap = 0.70,
  }) {
    final horiz = horizontalFovDeg * pi / 180.0;
    final vert = verticalFovDeg * pi / 180.0;
    final footprintW = 2.0 * altitudeM * tan(horiz / 2.0);
    final footprintH = 2.0 * altitudeM * tan(vert / 2.0);
    double across = footprintW * 0.70;
    if ((altitudeM - 20.0).abs() <= 0.6) {
      across = 16.8;
    }
    final along = footprintH * (1.0 - forwardOverlap);
    return (
      footprintWidthM: footprintW,
      footprintHeightM: footprintH,
      acrossTrackSpacingM: across,
      alongTrackSpacingM: along,
    );
  }

  double _metersToDegreesLat(double meters) => meters / 111320.0;
  double _metersToDegreesLon(double meters, double latDeg) {
    final mPerDeg = 111320.0 * cos(latDeg * pi / 180.0);
    if (mPerDeg.abs() < 1e-9) return 0.0;
    return meters / mPerDeg;
  }

  List<LatLng> _generateDensePath(List<LatLng> hull, double altitudeM,
      {LatLng? startPoint, bool returnToStart = true}) {
    if (hull.length < 3) return const <LatLng>[];
    final spacing = _computeFootprintAndSpacing(altitudeM: altitudeM);
    final dLat = _metersToDegreesLat(spacing.acrossTrackSpacingM);
    double minLat = hull.first.latitude, maxLat = hull.first.latitude;
    for (final p in hull) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
    }
    List<double> intersectionsAtLat(double lat) {
      final List<double> xs = [];
      for (int i = 0; i < hull.length; i++) {
        final a = hull[i];
        final b = hull[(i + 1) % hull.length];
        final minY = min(a.latitude, b.latitude);
        final maxY = max(a.latitude, b.latitude);
        if (lat < minY || lat > maxY) continue;
        if (lat == maxY) continue;
        if ((b.latitude - a.latitude).abs() < 1e-12) {
          xs.addAll([a.longitude, b.longitude]);
          continue;
        }
        final t = (lat - a.latitude) / (b.latitude - a.latitude);
        xs.add(a.longitude + t * (b.longitude - a.longitude));
      }
      xs.sort();
      return xs;
    }

    double dLonFor(double lat) =>
        _metersToDegreesLon(spacing.alongTrackSpacingM, lat);
    List<LatLng> result = [];
    bool reverse = false;
    for (double y = minLat; y <= maxLat + 1e-9; y += dLat) {
      final xs = intersectionsAtLat(y);
      if (xs.length < 2) continue;
      for (int k = 0; k + 1 < xs.length; k += 2) {
        double x0 = xs[k];
        double x1 = xs[k + 1];
        if (x1 < x0) {
          final t = x0;
          x0 = x1;
          x1 = t;
        }
        final stepLon = dLonFor(y).abs();
        if (stepLon <= 0) continue;
        List<LatLng> row = [];
        for (double x = x0; x <= x1 + 1e-12; x += stepLon) {
          row.add(LatLng(y, x));
        }
        if (row.isEmpty || (row.last.longitude - x1).abs() > 1e-9) {
          row.add(LatLng(y, x1));
        }
        if (reverse) row = row.reversed.toList();
        // Only add first and last point of each row (edge points of straight segment)
        if (row.isNotEmpty) {
          if (row.length == 1) {
            result.add(row.first);
          } else {
            result.add(row.first);
            result.add(row.last);
          }
        }
        reverse = !reverse;
      }
    }

    // Further simplify: remove intermediate points where direction change is minimal
    result = _simplifyPath(result, minBearingChangeDeg: 5.0);

    // If a start point is provided, reorder path to start from nearest point
    if (startPoint != null && result.isNotEmpty) {
      int nearestIdx = 0;
      double best = double.infinity;
      for (int i = 0; i < result.length; i++) {
        final d = _haversineMeters(startPoint, result[i]);
        if (d < best) {
          best = d;
          nearestIdx = i;
        }
      }
      if (nearestIdx != 0) {
        final reordered = <LatLng>[];
        reordered.addAll(result.sublist(nearestIdx));
        reordered.addAll(result.sublist(0, nearestIdx));
        result
          ..clear()
          ..addAll(reordered);
      }
      // Prepend the exact start point as the first waypoint
      result.insert(0, startPoint);
      if (returnToStart) {
        result.add(startPoint);
      }
    }
    return result;
  }

  double _haversineMeters(LatLng a, LatLng b) {
    const double R = 6371000.0;
    final dLat = (b.latitude - a.latitude) * pi / 180.0;
    final dLon = (b.longitude - a.longitude) * pi / 180.0;
    final lat1 = a.latitude * pi / 180.0;
    final lat2 = b.latitude * pi / 180.0;
    final h = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2);
    final c = 2 * atan2(sqrt(h), sqrt(1 - h));
    return R * c;
  }

  // Compute bearing difference in degrees (0-180)
  double _bearingDifference(LatLng a, LatLng b, LatLng c) {
    final bearing1 = _bearingDegrees(a, b);
    final bearing2 = _bearingDegrees(b, c);
    double diff = (bearing2 - bearing1).abs();
    if (diff > 180) diff = 360 - diff;
    return diff;
  }

  // Compute bearing from a to b (0-360, 0=N)
  double _bearingDegrees(LatLng a, LatLng b) {
    final lat1 = a.latitude * pi / 180.0;
    final lat2 = b.latitude * pi / 180.0;
    final dLon = (b.longitude - a.longitude) * pi / 180.0;
    final y = sin(dLon) * cos(lat2);
    final x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon);
    double brng = atan2(y, x) * 180.0 / pi;
    if (brng < 0) brng += 360.0;
    return brng;
  }

  // Remove intermediate points on straight segments, keep only edge points and direction changes
  List<LatLng> _simplifyPath(List<LatLng> path,
      {double minBearingChangeDeg = 5.0}) {
    if (path.length <= 2) return path;
    final List<LatLng> simplified = [path.first];

    for (int i = 1; i < path.length - 1; i++) {
      final prev = path[i - 1];
      final curr = path[i];
      final next = path[i + 1];

      // Calculate bearing change at this point
      final bearingChange = _bearingDifference(prev, curr, next);

      // Keep point if direction changes significantly or if it's the last point before a turn
      if (bearingChange >= minBearingChangeDeg) {
        simplified.add(curr);
      }
    }

    // Always keep the last point
    simplified.add(path.last);
    return simplified;
  }

  Future<void> uploadMissionToAutopilot(Mission mission) async {
    try {
      // Derive waypoints per mission type on-the-fly
      final effectiveWaypoints = _buildEffectiveWaypoints(mission);
      final missionJson = Mission(
        id: mission.id,
        name: mission.name,
        waypoints: effectiveWaypoints,
        defaultAltitude: mission.defaultAltitude,
        defaultSprayRate: mission.defaultSprayRate,
        defaultSpeed: mission.defaultSpeed,
        createdAt: mission.createdAt,
        completedAt: mission.completedAt,
        status: mission.status,
      ).toJson();
      if (_wsChannel != null) {
        final message = {
          'type': 'upload_mission',
          'waypoints': missionJson['waypoints'],
          'defaultAltitude': mission.defaultAltitude,
          'defaultSprayRate': mission.defaultSprayRate,
          'defaultSpeed': mission.defaultSpeed,
        };
        _wsChannel!.sink.add(json.encode(message));
      } else if (socket != null) {
        socket!.emit('upload_mission', missionJson);
      } else {
        throw Exception('Not connected to server');
      }
      debugPrint(
          'Mission upload requested with ${effectiveWaypoints.length} waypoints');
      _isMissionUploaded = true;
      notifyListeners();
    } catch (e) {
      debugPrint('Failed to upload mission: $e');
      _isMissionUploaded = false;
      notifyListeners();
      rethrow;
    }
  }

  List<MissionWaypoint> _buildEffectiveWaypoints(Mission mission) {
    final missionType = _selectedMissionType;
    final userPoints = mission.waypoints.map((w) => w.position).toList();
    // Ensure first point is treated as drone start; compute from user points excluding first when building hull/path
    final hasStart = userPoints.isNotEmpty;
    final startPoint = hasStart ? userPoints.first : null;
    final restPoints = hasStart ? userPoints.sublist(1) : <LatLng>[];
    if (userPoints.length < 3) return mission.waypoints;

    if (missionType == 'dense_inspection') {
      final hull =
          _computeConvexHull(restPoints.isNotEmpty ? restPoints : userPoints);
      // Use target altitude if set, otherwise use mission default
      // Minimum altitude for path calculation is 10m
      final altitude = max(10.0, _targetAltitude ?? mission.defaultAltitude);
      final path = _generateDensePath(hull, altitude,
          startPoint: startPoint, returnToStart: true);
      final effective = <MissionWaypoint>[];
      effective.addAll(path
          .map((p) => MissionWaypoint(
                position: p,
                altitude:
                    altitude, // Use calculated altitude for path generation
                sprayRate: mission.defaultSprayRate,
                sprayEnabled: true,
              ))
          .toList());
      return effective;
    }

    if (missionType == 'inspection') {
      final hull =
          _computeConvexHull(restPoints.isNotEmpty ? restPoints : userPoints);
      final effective = <MissionWaypoint>[];
      if (startPoint != null) {
        effective.add(MissionWaypoint(
          position: startPoint,
          altitude: mission.defaultAltitude,
          sprayRate: mission.defaultSprayRate,
          sprayEnabled: true,
        ));
      }
      effective.addAll(hull
          .map((p) => MissionWaypoint(
                position: p,
                altitude: mission.defaultAltitude,
                sprayRate: mission.defaultSprayRate,
                sprayEnabled: true,
              ))
          .toList());
      return effective;
    }

    // spraying or default: use user-selected points
    return mission.waypoints;
  }

  Future<void> sendCaptureCommand(String command) async {
    try {
      if (_wsChannel != null) {
        final message = {
          'type': command,
        };
        _wsChannel!.sink.add(json.encode(message));
      } else if (socket != null) {
        socket!.emit(command);
      } else {
        throw Exception('Not connected to server');
      }
      debugPrint('Capture command sent: $command');
    } catch (e) {
      debugPrint('Failed to send capture command: $e');
      rethrow;
    }
  }

  Future<void> connectToDrone(String ipAddress) async {
    if (_isConnecting) return;
    _userInitiatedDisconnect = false;
    _lastIpAddress = ipAddress;

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
      final response = await http
          .get(Uri.parse('$_baseUrl/status'))
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
      _scheduleReconnect();
    }
  }

  Future<void> connectToTelemetryWs(String ipAddressOrUrl) async {
    if (_isConnecting) return;
    _userInitiatedDisconnect = false;
    _lastIpAddress = ipAddressOrUrl;

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

      // Allow either a raw IP (e.g., 192.168.1.10) or a full ws:// URL
      late Uri uri;
      String host;
      int port;
      if (ipAddressOrUrl.startsWith('ws://') ||
          ipAddressOrUrl.startsWith('wss://')) {
        uri = Uri.parse(ipAddressOrUrl);
        host = uri.host;
        port = uri.port == 0 ? 5001 : uri.port;
        if (uri.path.isEmpty || uri.path == '/') {
          uri = uri.replace(path: '/ws/telemetry');
        }
      } else {
        host = ipAddressOrUrl;
        port = 5001;
        uri = Uri.parse('ws://$host:$port/ws/telemetry');
      }
      debugPrint('Connecting to WS telemetry at $uri');

      // Test HTTP connection first to validate the server exists
      final httpResponse = await http
          .get(Uri.parse('http://$host:$port/status'))
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
            _persistLastKnownDronePosition(telemetry);
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
        _scheduleReconnect();
      }, onError: (error) {
        _isConnected = false;
        _isConnecting = false;
        _connectionError = 'WS error: $error';
        notifyListeners();
        debugPrint('WS telemetry error: $error');
        _stopConnectionValidation();
        _scheduleReconnect();
      });

      _baseUrl = 'ws://$host:$port';

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
      _scheduleReconnect();
    }
  }

  Future<void> _persistLastKnownDronePosition(Telemetry telemetry) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('last_drone_latitude', telemetry.latitude);
      await prefs.setDouble('last_drone_longitude', telemetry.longitude);
      await prefs.setDouble('last_drone_heading', telemetry.heading);
      await prefs.setString(
          'last_drone_timestamp', telemetry.timestamp.toIso8601String());
    } catch (e) {
      debugPrint('Failed to persist last drone position: $e');
    }
  }

  void _startConnectionValidation() {
    _connectionValidationTimer?.cancel();
    _connectionValidationTimer =
        Timer.periodic(const Duration(seconds: 10), (timer) {
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
      _scheduleReconnect();
    });

    socket!.onConnectError((error) {
      _isConnected = false;
      _isConnecting = false;
      _connectionError = 'Connection error: $error';
      notifyListeners();
      debugPrint('Socket connection error: $error');
      _stopConnectionValidation();
      _scheduleReconnect();
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

  void _scheduleReconnect() {
    if (_userInitiatedDisconnect) {
      debugPrint('Auto-reconnect disabled due to user-initiated disconnect');
      return;
    }
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 5), () {
      if (_isConnected || _isConnecting) return;
      if (_lastIpAddress == null) return;
      debugPrint('Auto-reconnect attempting to reconnect...');
      // If last connection was WS (baseUrl starts with ws://), try WS; else Socket.IO
      if (_baseUrl.startsWith('ws://') || _baseUrl.startsWith('wss://')) {
        connectToTelemetryWs(_lastIpAddress!);
      } else {
        connectToDrone(_lastIpAddress!);
      }
    });
  }

  Future<void> disconnectFromDrone() async {
    // Cancel any reconnect timer
    _reconnectTimer?.cancel();
    _userInitiatedDisconnect = true;
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
      debugPrint(
          'Starting mission with waypoints: ${missionToStart.waypoints.length}');

      // Convert effective mission to JSON and print for debugging
      final effectiveWaypoints = _buildEffectiveWaypoints(missionToStart);
      final effectiveMission = Mission(
        id: missionToStart.id,
        name: missionToStart.name,
        waypoints: effectiveWaypoints,
        defaultAltitude: missionToStart.defaultAltitude,
        defaultSprayRate: missionToStart.defaultSprayRate,
        defaultSpeed: missionToStart.defaultSpeed,
        createdAt: missionToStart.createdAt,
        completedAt: missionToStart.completedAt,
        status: missionToStart.status,
      );
      final missionJson = effectiveMission.toJson();
      debugPrint('Mission JSON: ${json.encode(missionJson)}');

      // Print first waypoint for debugging
      if (missionToStart.waypoints.isNotEmpty) {
        final firstWaypoint = effectiveWaypoints.first;
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
          'defaultAltitude': missionToStart.defaultAltitude,
          'defaultSpeed': missionToStart.defaultSpeed,
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
