import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:agron_gcs/screens/auth/login_screen.dart';
import 'package:agron_gcs/providers/auth_provider.dart';
import 'package:agron_gcs/theme/app_theme.dart';

void main() {
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
        home: const LoginScreen(),
        debugShowCheckedModeBanner: false,
      ),
    );
  }
} 