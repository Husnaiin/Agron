import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/mission_storage.dart';
import '../../services/drone_service.dart';
import '../../models/mission.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';

class MissionScreen extends StatefulWidget {
  const MissionScreen({super.key});

  @override
  State<MissionScreen> createState() => _MissionScreenState();
}

// Rest of the file stays the same... 