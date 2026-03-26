import 'package:latlong2/latlong.dart';
import 'field.dart';

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
      final pos = json['position'] as Map<String, dynamic>;
      lat = (pos['latitude'] as num).toDouble();
      lng = (pos['longitude'] as num).toDouble();
    } else {
      lat = (json['latitude'] as num).toDouble();
      lng = (json['longitude'] as num).toDouble();
    }

    return MissionWaypoint(
      position: LatLng(lat, lng),
      altitude: (json['altitude'] as num).toDouble(),
      sprayRate: (json['sprayRate'] as num).toDouble(),
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
  final DateTime? scheduledAt;
  final bool isScheduled;
  final bool reminderEnabled;
  MissionStatus status;
  final int progressPercentage;
  final int lastCompletedWaypointIndex;
  /// Parent field (plot of land).
  final String fieldId;
  /// inspection | spraying | dense_inspection | dimr
  final String missionType;

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
    this.progressPercentage = 0,
    this.lastCompletedWaypointIndex = -1,
    this.fieldId = Field.kLegacyFieldId,
    this.missionType = 'inspection',
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
        'progressPercentage': progressPercentage,
        'lastCompletedWaypointIndex': lastCompletedWaypointIndex,
        'fieldId': fieldId,
        'missionType': missionType,
      };

  factory Mission.fromJson(Map<String, dynamic> json) => Mission(
        id: json['id'] as String,
        name: json['name'] as String,
        waypoints: (json['waypoints'] as List)
            .map((w) => MissionWaypoint.fromJson(w as Map<String, dynamic>))
            .toList(),
        defaultAltitude: (json['defaultAltitude'] as num).toDouble(),
        defaultSprayRate: (json['defaultSprayRate'] as num).toDouble(),
        defaultSpeed: (json['defaultSpeed'] as num?)?.toDouble() ?? 5.0,
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
        progressPercentage: json['progressPercentage'] as int? ?? 0,
        lastCompletedWaypointIndex:
            json['lastCompletedWaypointIndex'] as int? ?? -1,
        fieldId: json['fieldId'] as String? ?? Field.kLegacyFieldId,
        missionType: json['missionType'] as String? ?? 'inspection',
      );

  Mission copyWith({
    String? name,
    DateTime? scheduledAt,
    bool? isScheduled,
    bool? reminderEnabled,
    MissionStatus? status,
    DateTime? completedAt,
    int? progressPercentage,
    int? lastCompletedWaypointIndex,
    String? fieldId,
    String? missionType,
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
      progressPercentage: progressPercentage ?? this.progressPercentage,
      lastCompletedWaypointIndex:
          lastCompletedWaypointIndex ?? this.lastCompletedWaypointIndex,
      fieldId: fieldId ?? this.fieldId,
      missionType: missionType ?? this.missionType,
    );
  }
}

enum MissionStatus { pending, scheduled, inProgress, completed, failed, aborted }
