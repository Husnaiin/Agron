import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:agron_gcs/screens/auth/login_screen.dart';
import 'package:agron_gcs/screens/home/home_screen.dart';
import 'package:agron_gcs/providers/auth_provider.dart';
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
      ],
      child: MaterialApp(
        title: 'Agron GCS',
        theme: AppTheme.lightTheme,
        darkTheme: AppTheme.darkTheme,
        themeMode: ThemeMode.system,
        home: const AuthWrapper(),
        routes: {
          '/login': (context) => const LoginScreen(),
          '/home': (context) => const HomeScreen(),
        },
        debugShowCheckedModeBanner: false,
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