import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:agron_gcs/providers/auth_provider.dart';
import 'package:agron_gcs/widgets/map_view.dart';
import 'package:agron_gcs/widgets/telemetry_panel.dart';
import 'package:agron_gcs/widgets/mission_controls.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async => false, // Prevent back button navigation
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Agron GCS'),
          automaticallyImplyLeading: false, // Remove back button
          actions: [
            IconButton(
              icon: const Icon(Icons.logout),
              onPressed: () async {
                await context.read<AuthProvider>().logout();
                if (!context.mounted) return;
                Navigator.of(context).pushReplacementNamed('/login');
              },
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  const MapView(),
                  Positioned(
                    top: 16,
                    right: 16,
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(8.0),
                        // child: Column(
                        //   children: [
                        //     ElevatedButton(
                        //       onPressed: () {
                        //         // TODO: Implement mission planning
                        //       },
                        //       child: const Text('Plan Mission'),
                        //     ),
                        //     const SizedBox(height: 8),
                        //     ElevatedButton(
                        //       onPressed: () {
                        //         // TODO: Implement emergency return
                        //       },
                        //       style: ElevatedButton.styleFrom(
                        //         backgroundColor: Colors.red,
                        //       ),
                        //       child: const Text('Emergency Return'),
                        //     ),
                        //   ],
                        // ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const TelemetryPanel(),
            const MissionControls(),
          ],
        ),
      ),
    );
  }
} 