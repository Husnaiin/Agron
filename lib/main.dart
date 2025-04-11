import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:agron_gcs/screens/auth/login_screen.dart';
import 'package:agron_gcs/screens/home/home_screen.dart';
import 'package:agron_gcs/screens/mission_screen.dart';
import 'package:agron_gcs/providers/auth_provider.dart';
import 'package:agron_gcs/services/drone_service.dart';
import 'package:agron_gcs/theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        Provider<DroneService>(
          create: (_) {
            final service = DroneService();
            service.initialize();
            return service;
          },
          dispose: (_, service) => service.dispose(),
        ),
      ],
      child: MaterialApp(
        title: 'Agron GCS',
        theme: AppTheme.lightTheme,
        darkTheme: AppTheme.darkTheme,
        themeMode: ThemeMode.system,
        home: const SplashScreen(),
        routes: {
          '/login': (context) => const LoginScreen(),
          '/home': (context) => const HomeScreen(),
          '/missions': (context) => const MissionScreen(),
        },
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    print('SplashScreen: initState called');
    _navigateToLogin();
  }

  Future<void> _navigateToLogin() async {
    print('SplashScreen: Starting navigation delay');
    await Future.delayed(const Duration(seconds: 4));
    print('SplashScreen: Delay completed');
    if (!mounted) {
      print('SplashScreen: Widget not mounted, skipping navigation');
      return;
    }
    print('SplashScreen: Navigating to login screen');
    Navigator.pushReplacementNamed(context, '/login');
  }

  @override
  Widget build(BuildContext context) {
    print('SplashScreen: Building widget');
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SvgPicture.asset(
              Theme.of(context).brightness == Brightness.light
                  ? 'AgronLogos/Brand-logo-black.svg'
                  : 'AgronLogos/Brand-logo-white.svg',
              width: 200,
              height: 200,
              placeholderBuilder: (BuildContext context) => Container(
                width: 200,
                height: 200,
                child: const Center(
                  child: CircularProgressIndicator(),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              '',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ],
        ),
      ),
    );
  }
}

class AuthWrapper extends StatelessWidget {
  const AuthWrapper({super.key});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: Provider.of<AuthProvider>(context, listen: false).checkAuthStatus(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(
              child: CircularProgressIndicator(),
            ),
          );
        }
        
        // If we get an error, or no data, or not authenticated, show login
        if (snapshot.hasError || !snapshot.hasData || !snapshot.data!) {
          return const LoginScreen();
        }
        
        // If authenticated, show home screen
        return const HomeScreen();
      },
    );
  }
} 