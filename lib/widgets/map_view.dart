import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'dart:ui' as ui;
// import 'package:flutter_map_location_marker/flutter_map_location_marker.dart';
import 'package:geolocator/geolocator.dart';
// import 'package:flutter_svg/flutter_svg.dart';
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'dart:math';
import 'dart:io';
import 'dart:async';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import '../services/drone_service.dart';
import '../services/mission_storage.dart';
import '../models/mission.dart';
import '../models/telemetry.dart';
// import 'emergency_puzzle.dart';
import 'audio_recorder.dart';

class CustomTileProvider extends TileProvider {
  final String urlTemplate;
  final Directory cacheDir;
  final Map<String, File> tileCache = {};
  final String mapType;

  CustomTileProvider(this.urlTemplate, this.cacheDir,
      {this.mapType = 'standard'});

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    final url = urlTemplate
        .replaceAll('{z}', coordinates.z.toString())
        .replaceAll('{x}', coordinates.x.toString())
        .replaceAll('{y}', coordinates.y.toString());

    final fileName =
        '${mapType}_${coordinates.z}_${coordinates.x}_${coordinates.y}.png';
    final file = File('${cacheDir.path}/map_tiles/$fileName');

    if (file.existsSync()) {
      return FileImage(file);
    }

    return NetworkImage(url)
      ..evict().then((_) async {
        try {
          final response = await http.get(Uri.parse(url));
          if (response.statusCode == 200) {
            await file.writeAsBytes(response.bodyBytes);
          }
        } catch (e) {
          debugPrint('Error caching tile: $e');
        }
      });
  }
}

class MapView extends StatefulWidget {
  const MapView({super.key});

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> {
  final MapController _mapController = MapController();
  final List<LatLng> _points = [];
  late DroneService _droneService;
  final MissionStorage _missionStorage = MissionStorage();
  bool _wasMissionActive = false;
  bool _hasCenteredOnDrone = false;
  String? _lastFittedMissionId;

  // Default mission parameters
  static const double defaultAltitude = 30.0; // meters
  static const double defaultSprayRate = 2.0; // liters per minute

  bool _isDrawing = false;
  bool _isSatelliteView = false;
  // Connection and mission flags are managed via DroneService; local copies not used
  // Keeping minimal state only
  LatLng? _currentLocation;
  LatLng? _droneLocation;
  bool _isLoading = false;
  Telemetry? _lastTelemetry;
  late Directory _cacheDir;
  CustomTileProvider? _tileProvider;
  CustomTileProvider? _satelliteTileProvider;
  StreamSubscription<Telemetry>? _telemetrySubscription;
  Timer? _connectionTimer;

  // Dense inspection preview
  final List<LatLng> _densePathPoints = [];
  bool _showDirectionArrows = true; // UI toggle for dense preview arrows
  double _arrowPixelSize = 38.0; // Adjust arrow size (px) for Dense preview

  // Simple compass painter uses heading in degrees
  // Renders a dial with a red north arrow rotated by heading

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

  // Compute camera footprint and spacing given altitude and FOVs
  // Defaults approximate IMX219: ~62.2° horiz, ~48.8° vert
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
    // Lateral spacing: approx 70% of footprint width; for 20 m altitude use fixed 16.8 m
    double across = footprintW * 0.70;
    if ((altitudeM - 20.0).abs() <= 0.6) {
      across = 16.8; // meters at 20 m altitude
    }
    final along = footprintH * (1.0 - forwardOverlap);
    return (
      footprintWidthM: footprintW,
      footprintHeightM: footprintH,
      acrossTrackSpacingM: across,
      alongTrackSpacingM: along,
    );
  }

  // Convert meters to degrees latitude at given latitude
  double _metersToDegreesLat(double meters) {
    return meters / 111320.0;
  }

  // Convert meters to degrees longitude at given latitude
  double _metersToDegreesLon(double meters, double atLatitudeDeg) {
    final mPerDeg = 111320.0 * cos(atLatitudeDeg * pi / 180.0);
    if (mPerDeg.abs() < 1e-9) return 0.0;
    return meters / mPerDeg;
  }

  // Compute initial bearing (degrees) from point a to b (0..360, 0 = North)
  double _bearingDegrees(LatLng a, LatLng b) {
    final lat1 = a.latitude * pi / 180.0;
    final lat2 = b.latitude * pi / 180.0;
    final dLon = (b.longitude - a.longitude) * pi / 180.0;
    final y = sin(dLon) * cos(lat2);
    final x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon);
    double brng = atan2(y, x) * 180.0 / pi; // -180..+180
    if (brng < 0) brng += 360.0;
    return brng; // 0..360
  }

  // Generate boustrophedon coverage waypoints for a convex polygon via horizontal scanlines
  List<LatLng> _generateDenseInspectionPath(List<LatLng> hull, double altitudeM,
      {LatLng? startPoint, bool returnToStart = true}) {
    if (hull.length < 3) return const <LatLng>[];

    final spacing = _computeFootprintAndSpacing(altitudeM: altitudeM);
    // Determine scanline step (across-track) in degrees latitude
    final dLat = _metersToDegreesLat(spacing.acrossTrackSpacingM);

    // Bounding box
    double minLat = hull.first.latitude, maxLat = hull.first.latitude;
    for (final p in hull) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
    }

    // Utility: compute intersections of horizontal line (at lat) with polygon edges -> list of longitudes
    List<double> intersectionsAtLat(double lat) {
      final List<double> xs = [];
      for (int i = 0; i < hull.length; i++) {
        final a = hull[i];
        final b = hull[(i + 1) % hull.length];
        final latA = a.latitude;
        final latB = b.latitude;
        final lonA = a.longitude;
        final lonB = b.longitude;

        // Check if horizontal line intersects edge [a,b]
        final minY = min(latA, latB);
        final maxY = max(latA, latB);
        if (lat < minY || lat > maxY) continue;
        // Avoid double counting vertices by excluding the top endpoint
        if (lat == maxY) continue;

        if ((latB - latA).abs() < 1e-12) {
          // Horizontal edge: add span (we'll treat by adding both endpoints)
          xs.addAll([lonA, lonB]);
          continue;
        }
        final t = (lat - latA) / (latB - latA);
        final x = lonA + t * (lonB - lonA);
        xs.add(x);
      }
      xs.sort();
      return xs;
    }

    // Along-track step in longitude depends on latitude of the row
    double dLonForLat(double lat) {
      return _metersToDegreesLon(spacing.alongTrackSpacingM, lat);
    }

    final List<LatLng> result = [];
    bool reverse = false;
    // Start from minLat and move up
    for (double y = minLat; y <= maxLat + 1e-9; y += dLat) {
      final xs = intersectionsAtLat(y);
      if (xs.length < 2) continue;
      // Pair up intersections into segments
      for (int k = 0; k + 1 < xs.length; k += 2) {
        double x0 = xs[k];
        double x1 = xs[k + 1];
        if (x1 < x0) {
          final tmp = x0;
          x0 = x1;
          x1 = tmp;
        }

        final stepLon = dLonForLat(y).abs();
        if (stepLon <= 0) continue;

        List<LatLng> row = [];
        // Build points along the segment
        for (double x = x0; x <= x1 + 1e-12; x += stepLon) {
          row.add(LatLng(y, x));
        }
        // Ensure last endpoint included exactly
        if (row.isEmpty || (row.last.longitude - x1).abs() > 1e-9) {
          row.add(LatLng(y, x1));
        }

        if (reverse) {
          row = row.reversed.toList();
        }
        result.addAll(row);
        reverse = !reverse; // alternate direction for boustrophedon
      }
    }

    // Remove consecutive duplicate points
    if (result.length > 1) {
      final deduped = <LatLng>[result.first];
      for (int i = 1; i < result.length; i++) {
        final prev = deduped.last;
        final curr = result[i];
        final dist = _calculateDistance(prev, curr);
        // Only add if distance is significant (> 0.5m)
        if (dist > 0.5) {
          deduped.add(curr);
        }
      }
      result.clear();
      result.addAll(deduped);
    }

    // If a start point is provided, reorder to nearest entry and add start/return
    if (startPoint != null && result.isNotEmpty) {
      int nearestIdx = 0;
      double best = double.infinity;
      for (int i = 0; i < result.length; i++) {
        final d = _calculateDistance(startPoint, result[i]);
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
      result.insert(0, startPoint);
      if (returnToStart) {
        result.add(startPoint);
      }
    }
    return result;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _droneService = Provider.of<DroneService>(context, listen: false);
    _setupTelemetrySubscription();
    _droneService.addListener(_onServiceChange);
  }

  void _onServiceChange() {
    final isActive = _droneService.isMissionActive;
    final currentMission = _droneService.currentMission;

    // Reset fitted mission ID if mission is cleared, so it can refit when reloaded
    if (currentMission == null) {
      _lastFittedMissionId = null;
    }

    if (_wasMissionActive && !isActive) {
      setState(() {
        _droneLocation = null; // remove airplane icon
        _points.clear(); // clear any drawn points
        _hasCenteredOnDrone = false;
      });
    }
    _wasMissionActive = isActive;
  }

  /// Clear the current mission and reset the map to a clean state.
  /// This allows the user to start drawing a new mission from scratch.
  void _clearMission() {
    // Clear the mission from DroneService
    _droneService.clearMission();

    setState(() {
      // Clear all drawn points
      _points.clear();

      // Clear dense path points
      _densePathPoints.clear();

      // Reset fitted mission ID so new missions can be fitted
      _lastFittedMissionId = null;

      // Stop drawing mode
      _isDrawing = false;

      // Reset map to default view (center on current location if available)
      if (_currentLocation != null) {
        _mapController.move(
            _currentLocation!, 18); // Increased zoom for maximum detail
      } else if (_droneLocation != null) {
        _mapController.move(
            _droneLocation!, 18); // Increased zoom for maximum detail
      }
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Mission cleared. You can now draw a new mission.'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  /// Fit the map camera to show all mission waypoints with MAXIMUM ZOOM.
  /// For small mission areas, this zooms in as much as possible to make the area
  /// appear larger on screen, while ensuring it stays within screen bounds.
  void _fitMapToBounds(List<LatLng> points) {
    if (points.isEmpty) return;

    // Compute bounding box from all points
    double minLat = points.first.latitude;
    double maxLat = points.first.latitude;
    double minLon = points.first.longitude;
    double maxLon = points.first.longitude;

    for (final point in points) {
      if (point.latitude < minLat) minLat = point.latitude;
      if (point.latitude > maxLat) maxLat = point.latitude;
      if (point.longitude < minLon) minLon = point.longitude;
      if (point.longitude > maxLon) maxLon = point.longitude;
    }

    // Calculate the span of the mission area
    final latSpan = maxLat - minLat;
    final lonSpan = maxLon - minLon;

    // For very small areas, use MINIMAL padding to MAXIMIZE ZOOM
    // This makes small mission areas appear as large as possible on screen
    final double padding;
    if (latSpan < 0.0005 || lonSpan < 0.0005) {
      // Extremely small area (< ~50m): absolute minimum padding to maximize zoom
      padding = 10.0;
    } else if (latSpan < 0.001 || lonSpan < 0.001) {
      // Very small area (< ~100m): minimal padding to maximize zoom
      padding = 15.0;
    } else if (latSpan < 0.01 || lonSpan < 0.01) {
      // Small area (< ~1km): moderate padding
      padding = 30.0;
    } else {
      // Larger area: comfortable padding
      padding = 50.0;
    }

    // Create bounds from computed bounding box
    final bounds = LatLngBounds(
      LatLng(minLat, minLon),
      LatLng(maxLat, maxLon),
    );

    // Fit the map to these bounds with minimal padding for small areas
    // This maximizes zoom level while keeping polygon within screen bounds
    _mapController.fitBounds(
      bounds,
      options: FitBoundsOptions(
        padding: EdgeInsets.all(padding),
        maxZoom: 19, // Maximum zoom level allowed
      ),
    );
  }

  void _setupTelemetrySubscription() {
    _telemetrySubscription?.cancel();
    _telemetrySubscription = _droneService.telemetryStream.listen((telemetry) {
      setState(() {
        _lastTelemetry = telemetry;
        _droneLocation = LatLng(telemetry.latitude, telemetry.longitude);
        // On first telemetry after (re)connect, center map on the *current* drone location
        if (!_hasCenteredOnDrone || _currentLocation == null) {
          _currentLocation = _droneLocation;
          // Only auto-center on the drone when there is NO active mission loaded.
          // If a mission is loaded/resumed, we keep the map zoom fitted to the mission area.
          if (_currentLocation != null &&
              _droneService.currentMission == null) {
            _mapController.move(
                _currentLocation!, 18); // Increased zoom for maximum detail
          }
          _hasCenteredOnDrone = true;
        }
      });
    });
  }

  @override
  void initState() {
    super.initState();
    _initializeCache();
    _requestLocationPermission();
  }

  Future<void> _initializeCache() async {
    try {
      _cacheDir = await getTemporaryDirectory();
      final cachePath = '${_cacheDir.path}/map_tiles';
      await Directory(cachePath).create(recursive: true);

      _tileProvider = CustomTileProvider(
        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
        _cacheDir,
        mapType: 'standard',
      );

      _satelliteTileProvider = CustomTileProvider(
        'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
        _cacheDir,
        mapType: 'satellite',
      );

      setState(() {});
    } catch (e) {
      debugPrint('Error initializing cache: $e');
    }
  }

  Future<void> _requestLocationPermission() async {
    final status = await Permission.location.request();
    if (status.isGranted) {
      await _initMobileLocation();
    } else {
      // Fallback: try to center from last known drone location (if any)
      await _loadLastDroneLocationFromCache();
    }
  }

  Future<void> _getCurrentLocation() async {
    await _initMobileLocation();
  }

  Future<void> _initMobileLocation() async {
    try {
      // Ensure location services are enabled
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        debugPrint('Location services are disabled.');
        await _loadLastDroneLocationFromCache();
        return;
      }

      // Check permission (Permission.location from permission_handler is already granted here)
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied ||
            permission == LocationPermission.deniedForever) {
          debugPrint('Geolocator permission denied.');
          await _loadLastDroneLocationFromCache();
          return;
        }
      }

      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      if (!mounted) return;
      setState(() {
        _currentLocation = LatLng(position.latitude, position.longitude);
        // If we are not yet tracking a live drone, center map on mobile location
        if (_droneLocation == null && _currentLocation != null) {
          _mapController.move(
              _currentLocation!, 18); // Increased zoom for maximum detail
        }
      });
    } catch (e) {
      debugPrint('Failed to get mobile location: $e');
      await _loadLastDroneLocationFromCache();
    }
  }

  Future<void> _loadLastDroneLocationFromCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lat = prefs.getDouble('last_drone_latitude');
      final lon = prefs.getDouble('last_drone_longitude');
      if (lat != null && lon != null) {
        setState(() {
          _droneLocation = LatLng(lat, lon);
          _currentLocation = _droneLocation;
          _mapController.move(
              _droneLocation!, 18); // Increased zoom for maximum detail
        });
      }
    } catch (e) {
      debugPrint('Failed to load cached drone location: $e');
    }
  }

  void _toggleSatelliteView() {
    setState(() {
      _isSatelliteView = !_isSatelliteView;
    });

    // Force map to refresh by moving to the same position
    if (_currentLocation != null) {
      final currentZoom = _mapController.zoom;

      // First move away from current position
      _mapController.move(
          LatLng(_currentLocation!.latitude + 0.0001,
              _currentLocation!.longitude + 0.0001),
          currentZoom);

      // Then move back to the original position after a short delay
      Future.delayed(const Duration(milliseconds: 100), () {
        if (mounted) {
          _mapController.move(_currentLocation!, currentZoom);
          setState(() {});
        }
      });
    }
  }

  void _undoLastPoint() {
    if (_points.isNotEmpty) {
      setState(() {
        _points.removeLast();
      });
    }
  }

  Future<Mission?> _createMission() async {
    if (_points.length < 3 || _currentLocation == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'Please mark at least 3 points and ensure location is available')),
      );
      return null;
    }

    // Determine mission type
    final missionType = _droneService.selectedMissionType;

    // For dense missions: use the generated dense path waypoints
    // For other missions: use user-drawn polygon points
    List<LatLng> waypointsToSave;

    if ((missionType == 'dense_inspection' || missionType == 'dimr') &&
        _densePathPoints.isNotEmpty) {
      // Use the pre-generated dense path (what's shown in preview)
      waypointsToSave = List<LatLng>.from(_densePathPoints);
      debugPrint(
          '[SAVE_MISSION] Saving dense mission with ${waypointsToSave.length} pre-generated waypoints');
    } else {
      // Build waypoint list: first = current drone location, then user-selected points
      waypointsToSave = [];
      if (_droneLocation != null) {
        waypointsToSave.add(_droneLocation!);
      }

      // Avoid immediate duplicate if user first point equals last added point
      bool isSamePoint(LatLng a, LatLng b) {
        const double epsilon = 1e-6;
        return (a.latitude - b.latitude).abs() < epsilon &&
            (a.longitude - b.longitude).abs() < epsilon;
      }

      for (final p in _points) {
        if (waypointsToSave.isEmpty || !isSamePoint(waypointsToSave.last, p)) {
          waypointsToSave.add(p);
        }
      }
      debugPrint(
          '[SAVE_MISSION] Saving $missionType mission with ${waypointsToSave.length} user waypoints');
    }

    final mission = Mission(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: 'Mission ${DateTime.now().toString()}',
      waypoints: waypointsToSave
          .map((point) => MissionWaypoint(
                position: point,
                altitude: defaultAltitude,
                sprayRate: defaultSprayRate,
                sprayEnabled: true,
              ))
          .toList(),
      defaultAltitude: defaultAltitude,
      defaultSprayRate: defaultSprayRate,
      defaultSpeed: 5.0, // default speed in m/s
      createdAt: DateTime.now(),
    );

    try {
      await _missionStorage.saveMission(mission);
      return mission;
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save mission: $e')),
      );
      return null;
    }
  }

  // Removed emergency puzzle trigger from map to reduce warnings

  @override
  Widget build(BuildContext context) {
    if (_tileProvider == null || _satelliteTileProvider == null) {
      return const Center(child: CircularProgressIndicator());
    }

    // Listen to service to rebuild UI on state changes
    final service = Provider.of<DroneService>(context);
    final isMissionActive = service.isMissionActive;
    // Decide where to show the drone icon:
    // - If connected: actual drone location from telemetry
    // - If not connected: show drone icon at current mobile location (if known)
    LatLng? droneMarkerLocation = _droneLocation;
    if (!service.isConnected && _currentLocation != null) {
      droneMarkerLocation = _currentLocation;
    }
    final missionPoints = service.currentMission != null
        ? service.currentMission!.waypoints.map((w) => w.position).toList()
        : _points;
    final hullPoints = missionPoints.isNotEmpty
        ? _computeConvexHull(missionPoints)
        : <LatLng>[];

    // When a mission is loaded (from history or resume), automatically zoom the map
    // so that the entire mission area fits nicely on screen with padding.
    // Use ALL waypoints (not just convex hull) to ensure dense inspection paths are fully visible.
    if (service.currentMission != null && missionPoints.isNotEmpty) {
      final currentId = service.currentMission!.id;
      if (_lastFittedMissionId != currentId) {
        _lastFittedMissionId = currentId;
        // Use postFrameCallback to ensure map is fully rendered before fitting
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _fitMapToBounds(missionPoints);
        });
      }
    }
    // While drawing, include drone location as the first point in the hull preview
    final List<LatLng> drawingBasePoints = [];
    if (droneMarkerLocation != null) drawingBasePoints.add(droneMarkerLocation);
    drawingBasePoints.addAll(_points);
    final drawingHullPoints = drawingBasePoints.isNotEmpty
        ? _computeConvexHull(drawingBasePoints)
        : <LatLng>[];

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            center: _currentLocation ?? const LatLng(0, 0),
            zoom: 18, // Increased default zoom for maximum detail
            onTap: _isDrawing ? _handleMapTap : null,
          ),
          children: [
            TileLayer(
              urlTemplate: _isSatelliteView
                  ? 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}'
                  : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.agron.gcs',
              tileProvider:
                  _isSatelliteView ? _satelliteTileProvider! : _tileProvider!,
              maxZoom: 19,
            ),
            if (droneMarkerLocation != null)
              MarkerLayer(
                markers: [
                  Marker(
                    point: droneMarkerLocation,
                    width: 48,
                    height: 48,
                    child: _QuadcopterMarker(
                        headingDegrees: _lastTelemetry?.heading ?? 0),
                  ),
                ],
              ),
            // Remove live mobile location layer; focus on drone position
            if (!isMissionActive && _points.isNotEmpty) ...[
              PolygonLayer(
                polygons: [
                  Polygon(
                    points: drawingHullPoints,
                    color: Colors.blue.withAlpha(50),
                    borderStrokeWidth: 2,
                    borderColor: Colors.blue,
                    isFilled: true,
                  ),
                ],
              ),
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: drawingHullPoints,
                    color: Colors.blue,
                    strokeWidth: 2,
                  ),
                ],
              ),
              if (Provider.of<DroneService>(context, listen: true)
                          .selectedMissionType ==
                      'dense_inspection' &&
                  drawingHullPoints.length >= 3) ...[
                // Compute and render dense inspection preview
                Builder(builder: (context) {
                  final targetAlt =
                      Provider.of<DroneService>(context, listen: true)
                              .targetAltitude ??
                          20.0; // default 20m if not set
                  // Minimum altitude for path calculation is 10m
                  final pathAlt = max(10.0, targetAlt);
                  _densePathPoints
                    ..clear()
                    ..addAll(_generateDenseInspectionPath(
                        drawingHullPoints, pathAlt,
                        startPoint: droneMarkerLocation, returnToStart: true));
                  return PolylineLayer(
                    polylines: [
                      Polyline(
                        points: _densePathPoints,
                        color: Colors.purple,
                        strokeWidth: 3,
                        isDotted: true,
                      ),
                    ],
                  );
                }),
                if (_showDirectionArrows)
                  MarkerLayer(
                    markers: _buildMidpointArrows(_densePathPoints,
                        color: Colors.purple),
                  ),
              ],
              MarkerLayer(
                markers: _points
                    .asMap()
                    .entries
                    .map(
                      (entry) => Marker(
                        point: entry.value,
                        width: 30,
                        height: 30,
                        child: GestureDetector(
                          onTap: () {
                            _showPointDetails(entry.key, entry.value);
                          },
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.blue,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 2),
                            ),
                            child: Center(
                              child: Text(
                                '${entry.key + 1}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ] else if (hullPoints.isNotEmpty) ...[
              PolygonLayer(
                polygons: [
                  Polygon(
                    points: hullPoints,
                    color: Colors.green.withAlpha(60),
                    borderStrokeWidth: 3,
                    borderColor: Colors.green,
                    isFilled: true,
                  ),
                ],
              ),
              if (service.selectedMissionType == 'dense_inspection' ||
                  service.selectedMissionType == 'dimr') ...[
                // Show dense path preview derived from stored user points
                Builder(builder: (context) {
                  final targetAlt =
                      Provider.of<DroneService>(context, listen: true)
                              .targetAltitude ??
                          20.0; // default 20m if not set
                  // Minimum altitude for path calculation is 10m
                  final pathAlt = max(10.0, targetAlt);
                  _densePathPoints
                    ..clear()
                    ..addAll(_generateDenseInspectionPath(hullPoints, pathAlt,
                        startPoint: droneMarkerLocation, returnToStart: true));
                  return PolylineLayer(
                    polylines: [
                      Polyline(
                        points: _densePathPoints,
                        color: Colors.purple,
                        strokeWidth: 3,
                        isDotted: true,
                      ),
                    ],
                  );
                }),
                if (_showDirectionArrows)
                  MarkerLayer(
                    markers: _buildMidpointArrows(_densePathPoints,
                        color: Colors.purple),
                  ),
              ] else if (service.selectedMissionType == 'inspection') ...[
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: hullPoints,
                      color: Colors.green,
                      strokeWidth: 2,
                    ),
                  ],
                ),
              ],
            ],
          ],
        ),
        Positioned(
          top: 10,
          right: 12,
          child: Card(
            child: Column(
              children: [
                IconButton(
                  icon: Icon(_isDrawing ? Icons.edit_off : Icons.edit),
                  onPressed: isMissionActive
                      ? null
                      : () {
                          setState(() {
                            _isDrawing = !_isDrawing;
                            if (_isDrawing) {
                              _points.clear();
                            }
                          });
                        },
                  tooltip: _isDrawing ? 'Stop Drawing' : 'Start Drawing',
                  color: _isDrawing ? Colors.blue : null,
                ),
                IconButton(
                  icon: Icon(
                    Icons.layers,
                    color: _isSatelliteView ? Colors.blue : null,
                  ),
                  onPressed: _toggleSatelliteView,
                  tooltip: _isSatelliteView
                      ? 'Switch to Map View'
                      : 'Switch to Satellite View',
                ),
                IconButton(
                  icon: const Icon(Icons.my_location),
                  onPressed: _getCurrentLocation,
                  tooltip: 'My Location',
                ),
                if (_isDrawing && !isMissionActive) ...[
                  IconButton(
                    icon: const Icon(Icons.undo),
                    onPressed: _points.isNotEmpty ? _undoLastPoint : null,
                    tooltip: 'Undo Last Point',
                  ),
                  IconButton(
                    icon: const Icon(Icons.clear_all),
                    onPressed: _points.isNotEmpty
                        ? () {
                            setState(() => _points.clear());
                          }
                        : null,
                    tooltip: 'Clear All Points',
                  ),
                  IconButton(
                    icon: const Icon(Icons.info),
                    onPressed: _points.length >= 3 ? _showFieldSummary : null,
                    tooltip: 'Field Summary',
                  ),
                  IconButton(
                    icon: const Icon(Icons.save),
                    onPressed: (_points.length >= 3 ||
                            _droneService.currentMission != null)
                        ? () => _saveMission()
                        : null,
                    tooltip: 'Save Mission (local history)',
                    color: _droneService.currentMission != null
                        ? Colors.green
                        : null,
                  ),
                ],
                // Clear Mission button - visible when a mission is loaded
                if (_droneService.currentMission != null && !isMissionActive)
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: _clearMission,
                    tooltip: 'Clear Mission and Start New',
                    color: Colors.red,
                  ),
                IconButton(
                  icon: const Icon(Icons.cloud_upload),
                  onPressed:
                      (!isMissionActive && _droneService.currentMission != null)
                          ? () => _uploadCurrentMission()
                          : null,
                  tooltip: 'Upload Mission to Drone',
                ),
                IconButton(
                  icon: const Icon(Icons.zoom_in),
                  onPressed: () {
                    final zoom = _mapController.zoom + 1;
                    _mapController.move(_mapController.center, zoom);
                  },
                  tooltip: 'Zoom In',
                ),
                IconButton(
                  icon: const Icon(Icons.zoom_out),
                  onPressed: () {
                    final zoom = _mapController.zoom - 1;
                    _mapController.move(_mapController.center, zoom);
                  },
                  tooltip: 'Zoom Out',
                ),
              ],
            ),
          ),
        ),
        Positioned(
          top: 10,
          left: 12,
          child: Card(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: SizedBox(
                    width: 56,
                    height: 56,
                    child: AudioRecorderButton(),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.chat_bubble_outline),
                  onPressed: () {
                    Navigator.pushNamed(context, '/chat');
                  },
                  tooltip: 'Open Chat',
                ),
              ],
            ),
          ),
        ),
        Positioned(
          top: 138,
          left: 12,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: _CompassWidget(
                headingDegrees: _lastTelemetry?.heading ?? 0,
                size: 56,
              ),
            ),
          ),
        ),
        Positioned(
          top: 218,
          left: 12,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: SizedBox(
                width: 56,
                height: 56,
                child: Consumer<DroneService>(
                  builder: (context, droneService, _) {
                    final isCameraOn = droneService.isCameraOn;
                    return IconButton(
                      icon: Icon(
                        isCameraOn ? Icons.stop : Icons.camera_alt,
                        size: 32,
                        color: isCameraOn ? Colors.red : Colors.blue,
                      ),
                      onPressed: () async {
                        try {
                          if (isCameraOn) {
                            await _droneService
                                .sendCaptureCommand('stop_capture');
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text('Camera capture stopped')),
                            );
                          } else {
                            await _droneService
                                .sendCaptureCommand('start_capture');
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text('Camera capture started')),
                            );
                          }
                        } catch (e) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                                content: Text('Capture command failed: $e')),
                          );
                        }
                      },
                    );
                  },
                ),
              ),
            ),
          ),
        ),
        if (_isLoading)
          const Center(
            child: CircularProgressIndicator(),
          ),
      ],
    );
  }

  void _showPointDetails(int index, LatLng point) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Point ${index + 1}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Latitude: ${point.latitude.toStringAsFixed(6)}'),
            Text('Longitude: ${point.longitude.toStringAsFixed(6)}'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              setState(() {
                _points.removeAt(index);
              });
              Navigator.pop(context);
            },
            child: const Text('Delete'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showFieldSummary() {
    // Calculate area and perimeter
    double area = _calculateArea();
    double acres = area / 4046.86; // Convert square meters to acres
    double perimeter = _calculatePerimeter();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Field Summary'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Number of points: ${_points.length}'),
            Text(
                'Area: ${area.toStringAsFixed(2)} m² (${acres.toStringAsFixed(2)} acres)'),
            Text('Perimeter: ${perimeter.toStringAsFixed(2)} meters'),
            const SizedBox(height: 16),
            const Text('Points:'),
            SizedBox(
              height: 150,
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _points.length,
                itemBuilder: (context, index) {
                  final point = _points[index];
                  return Text(
                    'Point ${index + 1}: (${point.latitude.toStringAsFixed(6)}, ${point.longitude.toStringAsFixed(6)})',
                  );
                },
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  double _calculateArea() {
    if (_points.length < 3) return 0;

    double area = 0;
    for (int i = 0; i < _points.length; i++) {
      int j = (i + 1) % _points.length;
      area += _points[i].latitude * _points[j].longitude;
      area -= _points[j].latitude * _points[i].longitude;
    }
    area = area.abs() * 111319.9 * 111319.9 / 2;
    return area;
  }

  double _calculatePerimeter() {
    if (_points.length < 2) return 0;

    double perimeter = 0;
    for (int i = 0; i < _points.length; i++) {
      int j = (i + 1) % _points.length;
      perimeter += _calculateDistance(_points[i], _points[j]);
    }
    return perimeter;
  }

  double _calculateDistance(LatLng point1, LatLng point2) {
    const double earthRadius = 6371000; // meters

    double lat1 = point1.latitude * pi / 180;
    double lat2 = point2.latitude * pi / 180;
    double dLat = (point2.latitude - point1.latitude) * pi / 180;
    double dLon = (point2.longitude - point1.longitude) * pi / 180;

    double a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2);
    double c = 2 * atan2(sqrt(a), sqrt(1 - a));

    return earthRadius * c;
  }

  void _handleMapTap(TapPosition tapPosition, LatLng point) {
    if (_isDrawing) {
      setState(() {
        _points.add(point);
      });
      // As the user defines a new mission polygon, automatically zoom so that
      // the drawn area clearly fills the screen.
      if (_points.length >= 3) {
        final base = <LatLng>[];
        if (_droneLocation != null) base.add(_droneLocation!);
        base.addAll(_points);
        final hull = _computeConvexHull(base);
        _fitMapToBounds(hull);
      }
    }
  }

  // removed unused _buildDirectionMarkers

  // Build a small arrow at the midpoint of each segment to indicate direction
  List<Marker> _buildMidpointArrows(List<LatLng> path,
      {Color color = Colors.purple,
      double minSegmentLengthMeters = 3.0,
      int maxArrows = 1000,
      double? pixelSize}) {
    if (path.length < 2) return const <Marker>[];
    final List<Marker> arrows = [];
    final double sizePx = pixelSize ?? _arrowPixelSize;
    for (int i = 0; i + 1 < path.length; i++) {
      final a = path[i];
      final b = path[i + 1];
      // Skip very short segments to reduce clutter
      if (_calculateDistance(a, b) < minSegmentLengthMeters) continue;
      if (arrows.length >= maxArrows) break;
      final mid = LatLng(
          (a.latitude + b.latitude) * 0.5, (a.longitude + b.longitude) * 0.5);
      final bearingDeg = _bearingDegrees(a, b); // 0..360 (0=N)
      // Icons.arrow_right_alt points to the right (East), rotate from North by (bearing - 90)
      final angleRad = (bearingDeg - 90.0) * pi / 180.0;
      arrows.add(
        Marker(
          point: mid,
          width: sizePx,
          height: sizePx,
          child: Opacity(
            opacity: 0.7,
            child: Transform.rotate(
              angle: angleRad,
              child: Icon(
                Icons.arrow_right_alt,
                color: color,
                size: sizePx,
              ),
            ),
          ),
        ),
      );
    }
    return arrows;
  }

  Future<void> _saveMission() async {
    // If mission is from history, update existing mission; otherwise create new.
    // NOTE: This method *only saves* to local history; it does NOT upload.
    final existingMission = _droneService.currentMission;
    Mission? missionToSave;

    if (existingMission != null && _droneService.isMissionFromHistory) {
      // Update existing mission with current target altitude/speed
      final altitude =
          _droneService.targetAltitude ?? existingMission.defaultAltitude;
      final speed = _droneService.targetSpeed ?? existingMission.defaultSpeed;
      missionToSave = Mission(
        id: existingMission.id,
        name: existingMission.name,
        waypoints: existingMission.waypoints,
        defaultAltitude: altitude,
        defaultSprayRate: existingMission.defaultSprayRate,
        defaultSpeed: speed,
        createdAt: existingMission.createdAt,
        completedAt: existingMission.completedAt,
        status: existingMission.status,
      );
    } else if (_points.length >= 3) {
      // Create new mission from drawn points
      missionToSave = await _createMission();
      if (missionToSave != null) {
        // Use target altitude/speed if set, otherwise use mission defaults
        final altitude =
            _droneService.targetAltitude ?? missionToSave.defaultAltitude;
        final speed = _droneService.targetSpeed ?? missionToSave.defaultSpeed;
        missionToSave = Mission(
          id: missionToSave.id,
          name: missionToSave.name,
          waypoints: missionToSave.waypoints,
          defaultAltitude: altitude,
          defaultSprayRate: missionToSave.defaultSprayRate,
          defaultSpeed: speed,
          createdAt: missionToSave.createdAt,
          completedAt: missionToSave.completedAt,
          status: missionToSave.status,
        );
      }
    }

    if (missionToSave != null) {
      // Save to storage (will replace if ID exists)
      try {
        await _missionStorage.saveMission(missionToSave);
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save mission: $e')),
        );
        return;
      }

      _droneService.setMission(missionToSave, fromHistory: false);
      setState(() => _isDrawing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Mission saved to history')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Please mark at least 3 points or load a mission')),
      );
    }
  }

  Future<void> _uploadCurrentMission() async {
    final mission = _droneService.currentMission;
    if (mission == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'No mission to upload. Please save or load a mission first')),
      );
      return;
    }

    try {
      await _droneService.uploadMissionToAutopilot(mission);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Mission upload requested')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Upload failed: $e')),
      );
    }
  }

  @override
  void dispose() {
    _telemetrySubscription?.cancel();
    _connectionTimer?.cancel();
    _droneService.removeListener(_onServiceChange);
    _droneService.dispose();
    _mapController.dispose();
    super.dispose();
  }
}

class _CompassWidget extends StatelessWidget {
  final double headingDegrees;
  final double size;
  const _CompassWidget({required this.headingDegrees, this.size = 56});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _CompassPainter(headingDegrees: headingDegrees),
      ),
    );
  }
}

class _CompassPainter extends CustomPainter {
  final double headingDegrees;
  _CompassPainter({required this.headingDegrees});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 4;

    final bgPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    final borderPaint = Paint()
      ..color = Colors.black54
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final tickPaint = Paint()
      ..color = Colors.black26
      ..strokeWidth = 1;
    final northPaint = Paint()
      ..color = Colors.red
      ..style = PaintingStyle.fill;

    // Dial
    canvas.drawCircle(center, radius, bgPaint);
    canvas.drawCircle(center, radius, borderPaint);

    // Ticks every 30 degrees
    for (int i = 0; i < 12; i++) {
      final angle = (i * 30) * pi / 180;
      final p1 = Offset(center.dx + (radius - 6) * cos(angle),
          center.dy + (radius - 6) * sin(angle));
      final p2 = Offset(
          center.dx + radius * cos(angle), center.dy + radius * sin(angle));
      canvas.drawLine(p1, p2, tickPaint);
    }

    // North arrow rotated by heading (0 deg points up)
    final headingRad = (-headingDegrees + 0) * pi / 180; // screen y-down
    final arrowLen = radius - 10;
    final arrowTip = Offset(center.dx + arrowLen * sin(headingRad),
        center.dy - arrowLen * cos(headingRad));
    final baseLeft = Offset(center.dx - 6, center.dy + 8);
    final baseRight = Offset(center.dx + 6, center.dy + 8);

    final path = ui.Path()
      ..moveTo(arrowTip.dx, arrowTip.dy)
      ..lineTo(baseLeft.dx, baseLeft.dy)
      ..lineTo(baseRight.dx, baseRight.dy)
      ..close();
    canvas.drawPath(path, northPaint);
  }

  @override
  bool shouldRepaint(covariant _CompassPainter oldDelegate) {
    return oldDelegate.headingDegrees != headingDegrees;
  }
}

class _QuadcopterMarker extends StatelessWidget {
  final double headingDegrees;
  const _QuadcopterMarker({required this.headingDegrees});

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: (headingDegrees * pi / 180),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Body
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: Colors.black87,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
            ),
          ),
          // Arms
          Container(width: 40, height: 2, color: Colors.black87),
          Transform.rotate(
            angle: pi / 2,
            child: Container(width: 40, height: 2, color: Colors.black87),
          ),
          // Rotors
          Positioned(
            top: 0,
            child: _rotor(),
          ),
          Positioned(
            bottom: 0,
            child: _rotor(),
          ),
          Positioned(
            left: 0,
            child: _rotor(),
          ),
          Positioned(
            right: 0,
            child: _rotor(),
          ),
        ],
      ),
    );
  }

  Widget _rotor() {
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        boxShadow: const [BoxShadow(blurRadius: 2, spreadRadius: 0.5)],
        border: Border.all(color: Colors.black87, width: 2),
      ),
    );
  }
}
