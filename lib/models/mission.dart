import 'package:latlong2/latlong.dart';

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
    double lat, lng;

    if (json.containsKey('position')) {
      lat = json['position']['latitude'] as double;
      lng = json['position']['longitude'] as double;
    } else {
      lat = json['latitude'] as double;
      lng = json['longitude'] as double;
    }

    return MissionWaypoint(
      position: LatLng(lat, lng),
      altitude: json['altitude'] as double,
      sprayRate: json['sprayRate'] as double,
      sprayEnabled: json['sprayEnabled'] as bool,
    );
  }
}

class Mission {
  final String id;
  final String name;
  final List<MissionWaypoint> waypoints;
  final double defaultAltitude;
  final double defaultSprayRate;
  final double defaultSpeed;
  final DateTime createdAt;
  final DateTime? completedAt;
  final DateTime? scheduledAt; // NEW: Scheduled date/time
  final bool isScheduled; // NEW: Is this mission scheduled?
  final bool reminderEnabled; // NEW: Enable reminder notifications
  MissionStatus status;

  Mission({
    required this.id,
    required this.name,
    required this.waypoints,
    required this.defaultAltitude,
    required this.defaultSprayRate,
    required this.defaultSpeed,
    required this.createdAt,
    this.completedAt,
    this.scheduledAt,
    this.isScheduled = false,
    this.reminderEnabled = false,
    this.status = MissionStatus.pending,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'waypoints': waypoints.map((w) => w.toJson()).toList(),
        'defaultAltitude': defaultAltitude,
        'defaultSprayRate': defaultSprayRate,
        'defaultSpeed': defaultSpeed,
        'createdAt': createdAt.toIso8601String(),
        'completedAt': completedAt?.toIso8601String(),
        'scheduledAt': scheduledAt?.toIso8601String(),
        'isScheduled': isScheduled,
        'reminderEnabled': reminderEnabled,
        'status': status.toString().split('.').last,
      };

  factory Mission.fromJson(Map<String, dynamic> json) => Mission(
        id: json['id'] as String,
        name: json['name'] as String,
        waypoints: (json['waypoints'] as List)
            .map((w) => MissionWaypoint.fromJson(w as Map<String, dynamic>))
            .toList(),
        defaultAltitude: json['defaultAltitude'] as double,
        defaultSprayRate: json['defaultSprayRate'] as double,
        defaultSpeed: (json['defaultSpeed'] as double?) ?? 5.0,
        createdAt: DateTime.parse(json['createdAt'] as String),
        completedAt: json['completedAt'] != null
            ? DateTime.parse(json['completedAt'] as String)
            : null,
        scheduledAt: json['scheduledAt'] != null
            ? DateTime.parse(json['scheduledAt'] as String)
            : null,
        isScheduled: json['isScheduled'] as bool? ?? false,
        reminderEnabled: json['reminderEnabled'] as bool? ?? false,
        status: MissionStatus.values.firstWhere(
          (e) => e.toString().split('.').last == json['status'],
          orElse: () => MissionStatus.pending,
        ),
      );

  // Helper method to copy mission with updates
  Mission copyWith({
    String? name,
    DateTime? scheduledAt,
    bool? isScheduled,
    bool? reminderEnabled,
    MissionStatus? status,
    DateTime? completedAt,
  }) {
    return Mission(
      id: id,
      name: name ?? this.name,
      waypoints: waypoints,
      defaultAltitude: defaultAltitude,
      defaultSprayRate: defaultSprayRate,
      defaultSpeed: defaultSpeed,
      createdAt: createdAt,
      completedAt: completedAt ?? this.completedAt,
      scheduledAt: scheduledAt ?? this.scheduledAt,
      isScheduled: isScheduled ?? this.isScheduled,
      reminderEnabled: reminderEnabled ?? this.reminderEnabled,
      status: status ?? this.status,
    );
  }
}

enum MissionStatus { pending, scheduled, inProgress, completed, failed, aborted }