import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:latlong2/latlong.dart';

class AIMissionPlanner {
  // Free Google Gemini API - get key from: https://makersuite.google.com/app/apikey
  static const String _apiKey = 'AIzaSyCBQhFzIuPdqB8GPJJFh38vgvwWko_MLY4'; // Replace with your key
  static const String _apiUrl = 'https://generativelanguage.googleapis.com/v1beta/models/gemini-pro:generateContent';

  /// Converts natural language description to mission waypoints
  /// Uses Google Gemini LLM with prompt engineering
  Future<List<LatLng>> generateWaypointsFromText({
    required String description,
    required LatLng centerLocation,
  }) async {
    try {
      // PROMPT ENGINEERING: Create structured prompt for AI
      final prompt = '''You are an agricultural drone mission planner AI. Convert the user's description into GPS waypoints.

User's current location (center): ${centerLocation.latitude}, ${centerLocation.longitude}

User's mission description: "$description"

Instructions:
1. Generate 4-8 waypoints that form a flight path
2. Each waypoint should be within 500 meters of center location
3. For spray missions: create grid pattern
4. For survey missions: create perimeter pattern
5. Return ONLY valid JSON array, no explanation

Required JSON format:
[
  {"lat": 31.5204, "lng": 74.3587},
  {"lat": 31.5214, "lng": 74.3597}
]

Generate waypoints now:''';

      final response = await http.post(
        Uri.parse('$_apiUrl?key=$_apiKey'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'contents': [{
            'parts': [{'text': prompt}]
          }],
          'generationConfig': {
            'temperature': 0.4, // Lower = more consistent
            'maxOutputTokens': 1024,
          }
        }),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final aiResponse = data['candidates'][0]['content']['parts'][0]['text'].toString();
        
        // Extract JSON from AI response (handles markdown code blocks)
        final jsonMatch = RegExp(r'\[[\s\S]*\]').firstMatch(aiResponse);
        if (jsonMatch == null) {
          throw Exception('AI did not return valid JSON');
        }
        
        final jsonString = jsonMatch.group(0)!;
        final List<dynamic> waypointsJson = json.decode(jsonString);
        
        // Convert JSON to LatLng objects
        final waypoints = waypointsJson.map((wp) {
          return LatLng(
            (wp['lat'] as num).toDouble(),
            (wp['lng'] as num).toDouble(),
          );
        }).toList();

        if (waypoints.isEmpty) {
          throw Exception('No waypoints generated');
        }

        return waypoints;
      } else {
        throw Exception('API Error: ${response.statusCode}');
      }
    } catch (e) {
      print('AI Mission Planning Error: $e');
      // Fallback: generate simple square pattern
      return _generateFallbackWaypoints(centerLocation);
    }
  }

  /// Fallback: generates simple 4-corner square pattern if AI fails
  List<LatLng> _generateFallbackWaypoints(LatLng center) {
    const offset = 0.002; // ~200 meters
    return [
      LatLng(center.latitude + offset, center.longitude - offset),
      LatLng(center.latitude + offset, center.longitude + offset),
      LatLng(center.latitude - offset, center.longitude + offset),
      LatLng(center.latitude - offset, center.longitude - offset),
    ];
  }

  /// Analyzes user description to suggest mission type
  Future<String> analyzeMissionType(String description) async {
    final lowerDesc = description.toLowerCase();
    if (lowerDesc.contains('spray') || lowerDesc.contains('pesticide')) {
      return 'Spray Mission';
    } else if (lowerDesc.contains('survey') || lowerDesc.contains('inspect')) {
      return 'Survey Mission';
    } else if (lowerDesc.contains('monitor') || lowerDesc.contains('check')) {
      return 'Monitoring Mission';
    } else {
      return 'General Mission';
    }
  }
}
