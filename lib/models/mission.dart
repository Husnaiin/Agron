import 'dart:convert';
import 'package:latlong2/latlong.dart';

double _asDouble(dynamic v) {
  if (v == null) throw FormatException('Expected number but got null');
  if (v is num) return v.toDouble();
  if (v is String) {
    final parsed = double.tryParse(v);
    if (parsed != null) return parsed;
  }
  throw FormatException('Cannot convert $v to double');
}

bool _asBool(dynamic v) {
  if (v == null) return false;
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) {
    final s = v.toLowerCase();
    return s == 'true' || s == '1' || s == 'yes' || s == 'y';
  }
  return false;
}

class MissionWaypoint {
  final LatLng position;
  final double altitude;
  final double sprayRate;
  final bool sprayEnabled;

  MissionWaypoint({
    required this.position,
    required this.altitude,
    required this.sprayRate,
    required this.sprayEnabled,
  });

  Map<String, dynamic> toJson() => {
        'position': {
          'latitude': position.latitude,
          'longitude': position.longitude,
        },
        'altitude': altitude,
        'sprayRate': sprayRate,
        'sprayEnabled': sprayEnabled,
      };

  factory MissionWaypoint.fromJson(Map<String, dynamic> json) {
    // Accept several possible key formats for position and numeric types
    double lat, lng;

    if (json.containsKey('position')) {
      final pos = json['position'];
      if (pos is Map<String, dynamic> || pos is Map) {
        lat = _asDouble((pos as Map)['latitude'] ?? (pos as Map)['lat']);
        lng = _asDouble((pos as Map)['longitude'] ?? (pos as Map)['lng']);
      } else {
        throw FormatException('Invalid position format');
      }
    } else {
      lat = _asDouble(json['latitude'] ?? json['lat']);
      lng = _asDouble(json['longitude'] ?? json['lng']);
    }

    return MissionWaypoint(
      position: LatLng(lat, lng),
      altitude: _asDouble(json['altitude']),
      sprayRate: _asDouble(json['sprayRate'] ?? json['spray_rate'] ?? json['sprayLevel'] ?? 0),
      sprayEnabled: _asBool(json['sprayEnabled'] ?? json['spray_enabled'] ?? json['spray']),
    );
  }
}

class Mission {
  final String id;
  final String name;
  final List<MissionWaypoint> waypoints;
  final double defaultAltitude;
  final double defaultSprayRate;
  final DateTime createdAt;
  final DateTime? completedAt;
  MissionStatus status;

  Mission({
    required this.id,
    required this.name,
    required this.waypoints,
    required this.defaultAltitude,
    required this.defaultSprayRate,
    required this.createdAt,
    this.completedAt,
    this.status = MissionStatus.pending,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'waypoints': waypoints.map((w) => w.toJson()).toList(),
        'defaultAltitude': defaultAltitude,
        'defaultSprayRate': defaultSprayRate,
        'createdAt': createdAt.toIso8601String(),
        'completedAt': completedAt?.toIso8601String(),
        'status': status.toString().split('.').last,
      };

  factory Mission.fromJson(Map<String, dynamic> json) {
    // waypoints may be List<dynamic> or JSON string
    dynamic rawWaypoints = json['waypoints'];
    List<dynamic> wpList = [];
    if (rawWaypoints is String) {
      final decoded = jsonDecodeSafe(rawWaypoints);
      if (decoded is List) wpList = decoded;
    } else if (rawWaypoints is List) {
      wpList = rawWaypoints;
    } else {
      throw FormatException('Invalid waypoints format');
    }

    final waypoints = wpList
        .map((w) {
          if (w is Map<String, dynamic>) return MissionWaypoint.fromJson(w);
          if (w is Map) return MissionWaypoint.fromJson(Map<String, dynamic>.from(w));
          throw FormatException('Invalid waypoint entry: $w');
        })
        .toList();

    final defaultAlt = _asDouble(json['defaultAltitude'] ?? json['default_altitude'] ?? 0);
    final defaultSpray = _asDouble(json['defaultSprayRate'] ?? json['default_spray_rate'] ?? 0);

    // createdAt may be ISO string or epoch millis
    final createdRaw = json['createdAt'] ?? json['created_at'];
    DateTime createdAt;
    if (createdRaw is String) {
      createdAt = DateTime.parse(createdRaw);
    } else if (createdRaw is num) {
      createdAt = DateTime.fromMillisecondsSinceEpoch(createdRaw.toInt());
    } else {
      createdAt = DateTime.now();
    }

    final completedRaw = json['completedAt'] ?? json['completed_at'];
    DateTime? completedAt;
    if (completedRaw != null) {
      if (completedRaw is String) {
        completedAt = DateTime.parse(completedRaw);
      } else if (completedRaw is num) {
        completedAt = DateTime.fromMillisecondsSinceEpoch(completedRaw.toInt());
      }
    }

    final statusRaw = (json['status'] ?? 'pending').toString().toLowerCase();
    final status = MissionStatus.values.firstWhere(
      (e) => e.toString().split('.').last.toLowerCase() == statusRaw,
      orElse: () => MissionStatus.pending,
    );

    return Mission(
      id: json['id'] as String? ?? (json['name'] as String? ?? 'unknown_id'),
      name: json['name'] as String? ?? 'Unnamed Mission',
      waypoints: waypoints,
      defaultAltitude: defaultAlt,
      defaultSprayRate: defaultSpray,
      createdAt: createdAt,
      completedAt: completedAt,
      status: status,
    );
  }
}

dynamic jsonDecodeSafe(String raw) {
  try {
    return raw.isEmpty ? null : jsonDecode(raw);
  } catch (_) {
    return null;
  }
}

enum MissionStatus {
  pending,
  inProgress,
  completed,
  failed,
  aborted
}