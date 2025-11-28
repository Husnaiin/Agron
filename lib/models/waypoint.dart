import 'package:latlong2/latlong.dart';

class Waypoint {
  final LatLng position;
  final double altitude;

  Waypoint({
    required this.position,
    required this.altitude,
  });

  Map<String, dynamic> toJson() {
    return {
      'latitude': position.latitude,
      'longitude': position.longitude,
      'altitude': altitude,
    };
  }

  factory Waypoint.fromJson(Map<String, dynamic> json) {
    return Waypoint(
      position: LatLng(
        json['latitude'] as double,
        json['longitude'] as double,
      ),
      altitude: json['altitude'] as double,
    );
  }
}
