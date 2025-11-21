import 'package:flutter/material.dart';
import 'package:agron_gcs/services/mission_storage.dart';
import 'package:firebase_auth/firebase_auth.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  Map<String, dynamic>? _profile;
  final _auth = FirebaseAuth.instance;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final profile = await MissionStorage().getUserProfile();
    setState(() {
      _profile = profile;
    });
  }

  @override
  Widget build(BuildContext context) {
    final user = _auth.currentUser;
    return Scaffold(
      appBar: AppBar(title: const Text('User Profile')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: _profile == null
            ? const Center(child: CircularProgressIndicator())
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Email: ${_profile?['email'] ?? user?.email ?? ''}',
                      style: const TextStyle(fontSize: 18)),
                  const SizedBox(height: 12),
                  Text('UID: ${user?.uid ?? ''}',
                      style: const TextStyle(fontSize: 16)),
                  const SizedBox(height: 12),
                  Text(
                    'Account Created: ${_profile?['createdAt'] != null ? DateTime.parse(_profile!['createdAt']).toLocal().toString().split(".")[0] : ''}',
                    style: const TextStyle(fontSize: 16),
                  ),
                ],
              ),
      ),
    );
  }
}
