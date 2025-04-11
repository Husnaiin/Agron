import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:agron_gcs/providers/auth_provider.dart';
import 'package:agron_gcs/widgets/map_view.dart';
import 'package:agron_gcs/widgets/telemetry_panel.dart';
import 'package:agron_gcs/widgets/mission_controls.dart';
import 'package:agron_gcs/services/drone_service.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async => false, // Prevent back button navigation
      child: Scaffold(
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(kToolbarHeight),
          child: Container(
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withAlpha(26),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: AppBar(
              title: SvgPicture.asset(
                Theme.of(context).brightness == Brightness.light
                    ? 'AgronLogos/Black-logo.svg'
                    : 'AgronLogos/White-logo.svg',
                height: 32,
              ),
              automaticallyImplyLeading: false,
              backgroundColor: Colors.transparent,
              elevation: 0,
              actions: [
                IconButton(
                  icon: Icon(
                    Icons.history,
                    color: Theme.of(context).brightness == Brightness.light
                        ? Colors.black
                        : Colors.white,
                  ),
                  onPressed: () => Navigator.pushNamed(context, '/missions'),
                  tooltip: 'Mission History',
                ),
                IconButton(
                  icon: Icon(
                    Icons.logout,
                    color: Theme.of(context).brightness == Brightness.light
                        ? Colors.black
                        : Colors.white,
                  ),
                  onPressed: () {
                    context.read<AuthProvider>().logout();
                    Navigator.pushReplacementNamed(context, '/login');
                  },
                  tooltip: 'Logout',
                ),
              ],
            ),
          ),
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
                      // child: Padding(
                      //   padding: const EdgeInsets.all(8.0),
                      //   // child: Column(
                      //   //   children: [
                      //   //     ElevatedButton(
                      //   //       onPressed: () {
                      //   //         // TODO: Implement mission planning
                      //   //       },
                      //   //       child: const Text('Plan Mission'),
                      //   //     ),
                      //   //     const SizedBox(height: 8),
                      //   //     ElevatedButton(
                      //   //       onPressed: () {
                      //   //         // TODO: Implement emergency return
                      //   //       },
                      //   //       style: ElevatedButton.styleFrom(
                      //   //         backgroundColor: Colors.red,
                      //   //       ),
                      //   //       child: const Text('Emergency Return'),
                      //   //     ),
                      //   //   ],
                      //   // ),
                      // ),
                    ),
                  ),
                ],
              ),
            ),
            TelemetryPanel(
              droneService: context.read<DroneService>(),
            ),
            const MissionControls(),
          ],
        ),
      ),
    );
  }
} 