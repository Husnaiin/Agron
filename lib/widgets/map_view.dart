import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_location_marker/flutter_map_location_marker.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:math';

class MapView extends StatefulWidget {
  const MapView({super.key});

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> {
  final MapController _mapController = MapController();
  final List<LatLng> _points = [];
  bool _isDrawing = false;
  bool _isSatelliteView = false;
  LatLng? _currentLocation;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _requestLocationPermission();
  }

  Future<void> _requestLocationPermission() async {
    final status = await Permission.location.request();
    if (status.isGranted) {
      _getCurrentLocation();
    }
  }

  Future<void> _getCurrentLocation() async {
    setState(() => _isLoading = true);
    try {
      final position = await Geolocator.getCurrentPosition();
      setState(() {
        _currentLocation = LatLng(position.latitude, position.longitude);
        _mapController.move(_currentLocation!, 15);
      });
    } catch (e) {
      debugPrint('Error getting location: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _toggleSatelliteView() {
    setState(() {
      _isSatelliteView = !_isSatelliteView;
    });
  }

  void _undoLastPoint() {
    if (_points.isNotEmpty) {
      setState(() {
        _points.removeLast();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: _currentLocation ?? const LatLng(0, 0),
            initialZoom: 3,
            onTap: (tapPosition, point) {
              if (_isDrawing) {
                setState(() {
                  _points.add(point);
                });
              }
            },
            interactionOptions: const InteractionOptions(
              enableScrollWheel: true,
              enableMultiFingerGestureRace: true,
            ),
          ),
          children: [
            TileLayer(
              urlTemplate: _isSatelliteView
                  ? 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}'
                  : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.example.agron_gcs',
              maxZoom: 19,
            ),
            CurrentLocationLayer(
              positionStream: const LocationMarkerDataStreamFactory().fromGeolocatorPositionStream(),
              style: const LocationMarkerStyle(
                marker: DefaultLocationMarker(
                  color: Colors.green,
                  child: Icon(
                    Icons.location_on,
                    color: Colors.white,
                  ),
                ),
                markerSize: Size(40, 40),
                accuracyCircleColor: Colors.green,
              ),
            ),
            if (_points.isNotEmpty) ...[
              PolygonLayer(
                polygons: [
                  Polygon(
                    points: _points,
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
                    points: _points,
                    color: Colors.blue,
                    strokeWidth: 2,
                  ),
                ],
              ),
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
            ],
          ],
        ),
        // Top Action Buttons
        Positioned(
          top: 10,
          left: 16,
          right: 16,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              if (_isDrawing)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Drawing Mode',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        Text('Points: ${_points.length}'),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            ElevatedButton(
                              onPressed: () {
                                if (_points.length >= 3) {
                                  setState(() {
                                    _isDrawing = false;
                                  });
                                  _showFieldSummary();
                                } else {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Add at least 3 points to complete the field'),
                                    ),
                                  );
                                }
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.green,
                              ),
                              child: const Text('Finish'),
                            ),
                            const SizedBox(width: 8),
                            ElevatedButton(
                              onPressed: _undoLastPoint,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.orange,
                              ),
                              child: const Text('Undo'),
                            ),
                            const SizedBox(width: 8),
                            ElevatedButton(
                              onPressed: () {
                                setState(() {
                                  _points.clear();
                                  _isDrawing = false;
                                });
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.red,
                              ),
                              child: const Text('Clear'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              // Row(
              //   mainAxisSize: MainAxisSize.min,
              //   children: [
              //     ElevatedButton(
              //       onPressed: () {
              //         // Plan Mission logic
              //       },
              //       style: ElevatedButton.styleFrom(
              //         backgroundColor: Colors.green,
              //         padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              //       ),
              //       child: const Text('Plan Mission'),
              //     ),
              //     const SizedBox(width: 8),
              //     ElevatedButton(
              //       onPressed: () {
              //         // Emergency Return logic
              //       },
              //       style: ElevatedButton.styleFrom(
              //         backgroundColor: Colors.red,
              //         padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              //       ),
              //       child: const Text('Emergency Return'),
              //     ),
              //   ],
              // ),
            ],
          ),
        ),
        // Map Controls
        Positioned(
          top: 10,
          right: 12,
          child: Card(
            child: Column(
              children: [
                IconButton(
                  icon: Icon(_isDrawing ? Icons.edit_off : Icons.edit),
                  onPressed: () {
                    setState(() {
                      _isDrawing = !_isDrawing;
                      if (_isDrawing) {
                        _points.clear();
                      }
                    });
                  },
                  tooltip: _isDrawing ? 'Stop Drawing' : 'Start Drawing',
                ),
                IconButton(
                  icon: const Icon(Icons.layers),
                  onPressed: _toggleSatelliteView,
                  tooltip: 'Toggle Satellite View',
                ),
                IconButton(
                  icon: const Icon(Icons.my_location),
                  onPressed: _getCurrentLocation,
                  tooltip: 'My Location',
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
            Text('Area: ${area.toStringAsFixed(2)} sq meters'),
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

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }
} 