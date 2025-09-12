# Agron GCS - Agricultural Drone Ground Control Station

A cross-platform Ground Control Station (GCS) application for agricultural drones, built with Flutter. This application enables users to plan and execute drone missions for agricultural inspection and spraying tasks, with real-time telemetry from Pixhawk autopilots.

## Features

- **Real-time Drone Telemetry**: Live position, altitude, speed, heading, and battery monitoring from Pixhawk via MAVLink
- **Mission Planning**: 
  - Draw field boundaries on interactive maps with satellite/street view toggle
  - Automatic first waypoint at current drone location
  - Save missions locally and upload to Pixhawk autopilot
- **Drone Control**:
  - Start/Stop mission execution with Pixhawk integration
  - Emergency return functionality (RTL)
  - Real-time mission progress tracking
- **Visual Interface**:
  - Custom quadcopter marker on map that rotates with drone heading
  - Live compass widget showing drone orientation
  - Camera capture controls (start/stop recording)
- **Map Features**:
  - Offline tile caching for reduced data usage
  - Convex hull calculation for field areas
  - Mission waypoint visualization
- **Communication**:
  - WebSocket connection to Raspberry Pi server
  - Real-time telemetry streaming
  - Mission upload to flight controller

## System Requirements

- **Flutter SDK** (>=3.0.0)
- **Dart SDK** (>=3.0.0)
- **Android SDK** (API level 23+)
- **Raspberry Pi** with Pixhawk autopilot
- **Python 3.8+** (for server)
- **pymavlink** (for MAVLink communication)

## Installation

### Mobile App (Flutter)

1. Clone the repository:
   ```bash
   git clone https://github.com/Husnaiin/Agron.git
   cd agron_mobile\ app
   ```

2. Install dependencies:
   ```bash
   flutter pub get
   ```

3. Run the application:
   ```bash
   flutter run
   ```

### Server Setup (Raspberry Pi)

1. Install Python dependencies:
   ```bash
   pip install fastapi uvicorn websockets pymavlink
   ```

2. Connect Pixhawk to Raspberry Pi via USB/serial

3. Run the server:
   ```bash
   uvicorn server1:app --host 0.0.0.0 --port 5001 --reload
   ```

4. Connect mobile app to Raspberry Pi IP address

## Project Structure

```
agron_mobile app/
├── lib/
│   ├── main.dart                 # App entry point
│   ├── models/
│   │   ├── mission.dart         # Mission data models
│   │   └── telemetry.dart       # Telemetry data models
│   ├── screens/
│   │   ├── auth/
│   │   │   └── login_screen.dart
│   │   ├── home/
│   │   │   └── home_screen.dart
│   │   ├── mission_screen.dart
│   │   └── chat_screen.dart
│   ├── widgets/
│   │   ├── map_view.dart        # Interactive map with drone tracking
│   │   ├── telemetry_panel.dart # Real-time telemetry display
│   │   ├── mission_controls.dart
│   │   ├── audio_recorder.dart
│   │   └── emergency_puzzle.dart
│   ├── services/
│   │   ├── drone_service.dart   # WebSocket communication
│   │   ├── auth_service.dart
│   │   └── mission_storage.dart
│   └── providers/
│       └── auth_provider.dart
├── server1.py                   # FastAPI server with MAVLink integration
├── server.py                    # Legacy Flask server
└── requirements.txt             # Python dependencies
```

## Key Components

### Mobile App Features

- **Map View**: Interactive map with OpenStreetMap tiles, satellite view toggle, offline caching
- **Drone Tracking**: Custom quadcopter marker that rotates with heading from telemetry
- **Compass**: Live compass widget showing drone orientation
- **Mission Planning**: Draw field boundaries, automatic drone location as first waypoint
- **Camera Controls**: Start/stop camera capture with visual feedback
- **Telemetry Panel**: Real-time display of drone position, altitude, speed, heading, battery

### Server Features

- **MAVLink Integration**: Direct communication with Pixhawk autopilot
- **Mission Upload**: Upload waypoints to flight controller with proper MAVLink protocol
- **Real-time Telemetry**: Stream live drone data via WebSocket
- **Camera Capture**: Dual camera support (RGB + NIR) with automatic capture loops
- **Mission Control**: Start/stop/pause missions with Pixhawk integration

## Usage

1. **Connect to Drone**:
   - Enter Raspberry Pi IP address in connection dialog
   - App connects via WebSocket to server running on Pi

2. **Plan Mission**:
   - Draw field boundaries by tapping on map
   - First waypoint automatically set to current drone location
   - Save mission to upload to Pixhawk

3. **Execute Mission**:
   - Start mission from mission controls
   - Monitor real-time telemetry and progress
   - Use emergency return if needed

4. **Camera Operations**:
   - Start/stop camera capture during flight
   - Images saved to `/home/agron/Agron/rgb` and `/home/agron/Agron/noir`

## Technical Details

- **Communication**: WebSocket for real-time data, MAVLink for Pixhawk control
- **Map Tiles**: OpenStreetMap with offline caching
- **Mission Format**: MAVLink MISSION_ITEM_INT with TAKEOFF, WAYPOINT, RTL sequence
- **Camera**: rpicam-still for dual camera capture
- **Storage**: Local SQLite for missions, SharedPreferences for settings

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Flutter team for the amazing framework
- ArduPilot community for MAVLink protocol
- OpenStreetMap for mapping data
- Raspberry Pi Foundation for hardware platform