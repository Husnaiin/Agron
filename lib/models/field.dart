import 'package:latlong2/latlong.dart';

/// A named plot of land; missions are runs/plans under this field.
class Field {
  static const String kLegacyFieldId = 'legacy_import';

  final String id;
  final String name;
  /// Polygon vertices (user outline / hull), WGS84.
  final List<LatLng> boundary;
  final double areaSquareMeters;
  final DateTime createdAt;
  final DateTime updatedAt;

  Field({
    required this.id,
    required this.name,
    required this.boundary,
    required this.areaSquareMeters,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'boundary': boundary
            .map((p) => {'latitude': p.latitude, 'longitude': p.longitude})
            .toList(),
        'areaSquareMeters': areaSquareMeters,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory Field.fromJson(Map<String, dynamic> json) {
    final b = (json['boundary'] as List?) ?? [];
    return Field(
      id: json['id'] as String,
      name: json['name'] as String,
      boundary: b
          .map((e) {
            final m = e as Map<String, dynamic>;
            return LatLng(
              (m['latitude'] as num).toDouble(),
              (m['longitude'] as num).toDouble(),
            );
          })
          .toList(),
      areaSquareMeters: (json['areaSquareMeters'] as num?)?.toDouble() ?? 0,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );
  }

  Field copyWith({
    String? name,
    List<LatLng>? boundary,
    double? areaSquareMeters,
    DateTime? updatedAt,
  }) {
    return Field(
      id: id,
      name: name ?? this.name,
      boundary: boundary ?? this.boundary,
      areaSquareMeters: areaSquareMeters ?? this.areaSquareMeters,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
