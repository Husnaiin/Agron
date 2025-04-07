# Agron GCS - Agricultural Drone Ground Control Station

A cross-platform Ground Control Station (GCS) application for agricultural drones, built with Flutter. This application enables users to plan and execute drone missions for agricultural inspection and spraying tasks.

## Features

- **Authentication**: Secure user login and registration
- **Mission Planning**: 
  - Draw field boundaries on the map
  - Select mission type (inspection/spraying)
  - Save and load missions
- **Drone Control**:
  - Start/Stop mission execution
  - Emergency return functionality
  - Real-time mission monitoring
- **Telemetry Display**:
  - Real-time position tracking
  - Speed and altitude monitoring
  - Battery level and spray fluid status
  - Mission progress tracking
- **Offline Support**:
  - Mission planning without internet
  - Local data storage
  - Automatic sync when online

## System Requirements

- Flutter SDK (>=3.0.0)
- Dart SDK (>=3.0.0)
- Android Studio / VS Code
- Google Maps API Key
- Node.js (for backend)
- MongoDB (for data storage)

## Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/yourusername/agron_gcs.git
   cd agron_gcs
   ```

2. Install dependencies:
   ```bash
   flutter pub get
   ```

3. Configure Google Maps:
   - Get an API key from the Google Cloud Console
   - Add the API key to `android/app/src/main/AndroidManifest.xml`
   - Add the API key to `ios/Runner/AppDelegate.swift`

4. Run the application:
   ```bash
   flutter run
   ```

## Project Structure

```
lib/
├── main.dart
├── theme/
│   └── app_theme.dart
├── screens/
│   ├── auth/
│   │   └── login_screen.dart
│   └── home/
│       └── home_screen.dart
├── widgets/
│   ├── map_view.dart
│   ├── telemetry_panel.dart
│   └── mission_controls.dart
└── providers/
    └── auth_provider.dart
```

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
- Google Maps for mapping functionality
- The open-source community for various packages used in this project 