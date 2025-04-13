import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:agron_gcs/providers/auth_provider.dart';
import 'package:agron_gcs/widgets/map_view.dart';
import 'package:agron_gcs/widgets/telemetry_panel.dart';
import 'package:agron_gcs/widgets/mission_controls.dart';
import 'package:agron_gcs/services/drone_service.dart';
import 'package:agron_gcs/screens/mission_screen.dart';
import 'package:agron_gcs/screens/auth/login_screen.dart';
import 'package:agron_gcs/theme/app_theme.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final droneService = Provider.of<DroneService>(context);
    
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
                // Connection status indicator
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: droneService.isConnected 
                        ? Colors.green 
                        : (droneService.isConnecting ? Colors.orange : Colors.red),
                  ),
                ),
                // Connect button
                IconButton(
                  icon: Icon(
                    Icons.wifi,
                    color: Theme.of(context).brightness == Brightness.light
                        ? Colors.black
                        : Colors.white,
                  ),
                  onPressed: () => _showConnectionDialog(context, droneService),
                  tooltip: 'Connect to Drone',
                ),
                IconButton(
                  icon: Icon(
                    Icons.history,
                    color: Theme.of(context).brightness == Brightness.light
                        ? Colors.black
                        : Colors.white,
                  ),
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => const MissionScreen()),
                    );
                  },
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
                    Provider.of<AuthProvider>(context, listen: false).logout();
                    Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(builder: (context) => const LoginScreen()),
                    );
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
                    ),
                  ),
                ],
              ),
            ),
            TelemetryPanel(
              droneService: droneService,
            ),
            const MissionControls(),
          ],
        ),
      ),
    );
  }

  void _showConnectionDialog(BuildContext context, DroneService droneService) {
    final TextEditingController ipController = TextEditingController(
      text: droneService.baseUrl.replaceAll('http://', '').replaceAll(':5000', '')
    );
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Connect to Drone'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ipController,
              decoration: const InputDecoration(
                labelText: 'Raspberry Pi IP Address',
                hintText: 'e.g., 192.168.1.100',
              ),
              keyboardType: TextInputType.number,
            ),
            if (droneService.connectionError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Text(
                  droneService.connectionError!,
                  style: const TextStyle(color: Colors.red),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final ip = ipController.text.trim();
              if (ip.isNotEmpty) {
                droneService.connectToDrone(ip);
                Navigator.pop(context);
              }
            },
            child: const Text('Connect'),
          ),
        ],
      ),
    );
  }
} 