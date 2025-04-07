import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class MapView extends StatefulWidget {
  const MapView({super.key});

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> {
  GoogleMapController? _mapController;
  Set<Polygon> _polygons = {};
  Set<Marker> _markers = {};
  bool _isDrawing = false;
  List<LatLng> _currentPolygonPoints = [];

  static const CameraPosition _initialPosition = CameraPosition(
    target: LatLng(0, 0),
    zoom: 2,
  );

  void _onMapCreated(GoogleMapController controller) {
    _mapController = controller;
  }

  void _onMapTap(LatLng position) {
    if (!_isDrawing) return;

    setState(() {
      _currentPolygonPoints.add(position);
      _updatePolygon();
    });
  }

  void _updatePolygon() {
    if (_currentPolygonPoints.length < 3) return;

    setState(() {
      _polygons = {
        Polygon(
          polygonId: const PolygonId('mission_area'),
          points: _currentPolygonPoints,
          strokeWidth: 2,
          strokeColor: Colors.blue,
          fillColor: Colors.blue.withOpacity(0.2),
        ),
      };
    });
  }

  void startDrawing() {
    setState(() {
      _isDrawing = true;
      _currentPolygonPoints = [];
      _polygons = {};
    });
  }

  void finishDrawing() {
    setState(() {
      _isDrawing = false;
      if (_currentPolygonPoints.length >= 3) {
        _updatePolygon();
      }
    });
  }

  void clearDrawing() {
    setState(() {
      _isDrawing = false;
      _currentPolygonPoints = [];
      _polygons = {};
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        GoogleMap(
          onMapCreated: _onMapCreated,
          initialCameraPosition: _initialPosition,
          polygons: _polygons,
          markers: _markers,
          onTap: _onMapTap,
          myLocationEnabled: true,
          myLocationButtonEnabled: true,
          mapType: MapType.satellite,
        ),
        if (_isDrawing)
          Positioned(
            top: 16,
            left: 16,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Column(
                  children: [
                    ElevatedButton(
                      onPressed: finishDrawing,
                      child: const Text('Finish Drawing'),
                    ),
                    const SizedBox(height: 8),
                    ElevatedButton(
                      onPressed: clearDrawing,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                      ),
                      child: const Text('Clear'),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
} 