class Telemetry {
  final double latitude;
  final double longitude;
  final double altitude;
  final double speed;
  final double heading;
  final int batteryPercentage;
  final int sprayLevel;
  final int missionProgress;
  final DateTime timestamp;

  Telemetry({
    required this.latitude,
    required this.longitude,
    required this.altitude,
    required this.speed,
    required this.heading,
    required this.batteryPercentage,
    required this.sprayLevel,
    this.missionProgress = 0,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
    'latitude': latitude,
    'longitude': longitude,
    'altitude': altitude,
    'speed': speed,
    'heading': heading,
    'batteryPercentage': batteryPercentage,
    'sprayLevel': sprayLevel,
    'missionProgress': missionProgress,
    'timestamp': timestamp.toIso8601String(),
  };

  factory Telemetry.fromJson(Map<String, dynamic> json) => Telemetry(
    latitude: json['latitude'] as double,
    longitude: json['longitude'] as double,
    altitude: json['altitude'] as double,
    speed: json['speed'] as double,
    heading: json['heading'] as double,
    batteryPercentage: json['batteryPercentage'] as int,
    sprayLevel: json['sprayLevel'] as int,
    missionProgress: json['missionProgress'] as int? ?? 0,
    timestamp: DateTime.parse(json['timestamp'] as String),
  );
} 