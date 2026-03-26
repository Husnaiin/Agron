// Removed bottom audio/text inputs; imports not needed
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:agron_gcs/providers/auth_provider.dart';
import 'package:agron_gcs/widgets/map_view.dart';
import 'package:agron_gcs/widgets/telemetry_panel.dart';
import 'package:agron_gcs/widgets/mission_controls.dart';
import 'package:agron_gcs/services/drone_service.dart';
import 'package:agron_gcs/screens/fields_screen.dart';
import 'package:agron_gcs/screens/auth/login_screen.dart';

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
                  margin:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: droneService.isConnected
                        ? Colors.green
                        : (droneService.isConnecting
                            ? Colors.orange
                            : Colors.red),
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
                    Icons.crop_square,
                    color: Theme.of(context).brightness == Brightness.light
                        ? Colors.black
                        : Colors.white,
                  ),
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (context) => const FieldsScreen()),
                    );
                  },
                  tooltip: 'Fields & missions',
                ),
                IconButton(
                  icon: Icon(
                    Icons.account_circle,
                    color: Theme.of(context).brightness == Brightness.light
                        ? Colors.black
                        : Colors.white,
                  ),
                  onPressed: () {
                    Navigator.pushNamed(context, '/profile');
                  },
                  tooltip: 'Profile',
                ),
                IconButton(
                  icon: Icon(
                    Icons.logout,
                    color: Theme.of(context).brightness == Brightness.light
                        ? Colors.black
                        : Colors.white,
                  ),
                  onPressed: () => _confirmLogout(context),
                  tooltip: 'Logout',
                ),
              ],
            ),
          ),
        ),
        body: Column(
          children: [
            const Expanded(
              child: MapView(),
            ),
            const Divider(
              height: 1,
              thickness: 1,
              indent: 12,
              endIndent: 12,
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

  Future<void> _confirmLogout(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Log out?'),
        content: const Text(
          'You will need to sign in again to access your fields and synced data.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Log out'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      Provider.of<AuthProvider>(context, listen: false).logout();
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const LoginScreen()),
      );
    }
  }

  void _showConnectionDialog(BuildContext context, DroneService droneService) {
    final TextEditingController ipController = TextEditingController(
        text: droneService.baseUrl
            .replaceAll('http://', '')
            .replaceAll('ws://', '')
            .replaceAll(':5000', '')
            .replaceAll(':5001', ''));

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Connect to Drone'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ipController,
              enabled: !droneService.isConnected && !droneService.isConnecting,
              decoration: const InputDecoration(
                labelText: 'Server IP or WebSocket URL',
                hintText:
                    'e.g. 192.168.1.50  or  ws://192.168.1.50:5001/ws/telemetry',
              ),
              keyboardType: TextInputType.text,
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
          if (!droneService.isConnected)
            ElevatedButton(
              onPressed: droneService.isConnecting
                  ? null
                  : () {
                      final ip = ipController.text.trim();
                      if (ip.isNotEmpty) {
                        droneService.connectToTelemetryWs(ip);
                        Navigator.pop(context);
                      }
                    },
              child:
                  Text(droneService.isConnecting ? 'Connecting…' : 'Connect'),
            ),
          if (droneService.isConnected)
            ElevatedButton(
              onPressed: () async {
                await droneService.disconnectFromDrone();
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('Disconnect'),
            ),
        ],
      ),
    );
  }
}
