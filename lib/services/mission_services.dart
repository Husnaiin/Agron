import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/mission.dart';

class MissionService {
  final CollectionReference missions =
      FirebaseFirestore.instance.collection('missions');

  Future<void> saveMission(Mission mission) async {
    await missions.doc(mission.id).set(mission.toJson());
  }

  Future<List<Mission>> getMissions() async {
    final snapshot = await missions.get();
    return snapshot.docs
        .map((doc) => Mission.fromJson(doc.data() as Map<String, dynamic>))
        .toList();
  }
}
