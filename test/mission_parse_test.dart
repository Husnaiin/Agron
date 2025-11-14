import 'package:flutter_test/flutter_test.dart';
import 'package:agron_gcs/models/mission.dart';

void main() {
  test('Mission.fromJson parses sample mission map', () {
    final sample = {
      'id': 'mission_001',
      'name': 'Field Sweep Alpha',
      'waypoints': [
        {
          'position': {'latitude': 24.8615, 'longitude': 67.0099},
          'altitude': 15,
          'sprayRate': 1.5,
          'sprayEnabled': true,
        },
        {
          'latitude': 24.8620,
          'longitude': 67.0105,
          'altitude': '15',
          'spray_rate': '1.5',
          'spray_enabled': 'true',
        },
        {
          'position': {'lat': 24.8625, 'lng': 67.0110},
          'altitude': 20,
          'sprayLevel': 0,
          'sprayEnabled': false,
        },
      ],
      'defaultAltitude': 15,
      'defaultSprayRate': 1.5,
      'createdAt': '2025-09-27T10:00:00Z',
      'status': 'pending',
    };

    final mission = Mission.fromJson(sample);

    expect(mission.id, 'mission_001');
    expect(mission.name, 'Field Sweep Alpha');
    expect(mission.waypoints.length, 3);
    expect(mission.waypoints[0].position.latitude, closeTo(24.8615, 1e-6));
    expect(mission.waypoints[0].position.longitude, closeTo(67.0099, 1e-6));
    expect(mission.waypoints[1].altitude, 15.0);
    expect(mission.waypoints[1].sprayRate, 1.5);
    expect(mission.defaultAltitude, 15.0);
    expect(mission.defaultSprayRate, 1.5);
    expect(mission.status, MissionStatus.pending);
  });

  test('Mission.fromJson throws FormatException on invalid waypoints format', () {
    final bad = {
      'id': 'bad_mission',
      'name': 'Bad Mission',
      'waypoints': 123, // invalid format
    };

    expect(() => Mission.fromJson(bad), throwsA(isA<FormatException>()));
  });
}