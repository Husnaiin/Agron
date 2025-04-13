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

  factory Telemetry.fromJson(Map<String, dynamic> json) {
    print('Parsing telemetry JSON: $json');
    
    // Handle potential type conversion issues
    double parseDouble(dynamic value) {
      if (value is int) return value.toDouble();
      if (value is double) return value;
      if (value is String) return double.tryParse(value) ?? 0.0;
      return 0.0;
    }
    
    int parseInt(dynamic value) {
      if (value is int) return value;
      if (value is double) return value.toInt();
      if (value is String) return int.tryParse(value) ?? 0;
      return 0;
    }
    
    DateTime parseDateTime(dynamic value) {
      if (value is DateTime) return value;
      if (value is String) {
        try {
          return DateTime.parse(value);
        } catch (e) {
          print('Error parsing date: $e');
          return DateTime.now();
        }
      }
      return DateTime.now();
    }
    
    return Telemetry(
      latitude: parseDouble(json['latitude']),
      longitude: parseDouble(json['longitude']),
      altitude: parseDouble(json['altitude']),
      speed: parseDouble(json['speed']),
      heading: parseDouble(json['heading']),
      batteryPercentage: parseInt(json['batteryPercentage']),
      sprayLevel: parseInt(json['sprayLevel']),
      missionProgress: parseInt(json['missionProgress']),
      timestamp: parseDateTime(json['timestamp']),
    );
  }
} 