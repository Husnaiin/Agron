import 'package:flutter/foundation.dart';
import 'package:shared_preferences.dart';

class AuthProvider with ChangeNotifier {
  String? _token;
  String? _userId;
  bool _isAuthenticated = false;

  bool get isAuthenticated => _isAuthenticated;
  String? get token => _token;
  String? get userId => _userId;

  Future<void> login(String email, String password) async {
    try {
      // TODO: Implement actual API call to backend
      // For now, using mock authentication
      _token = 'mock_token';
      _userId = 'mock_user_id';
      _isAuthenticated = true;
      
      // Store auth data locally
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('token', _token!);
      await prefs.setString('userId', _userId!);
      
      notifyListeners();
    } catch (error) {
      _isAuthenticated = false;
      _token = null;
      _userId = null;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> logout() async {
    _token = null;
    _userId = null;
    _isAuthenticated = false;
    
    // Clear stored auth data
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('token');
    await prefs.remove('userId');
    
    notifyListeners();
  }

  Future<void> checkAuthStatus() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString('token');
    _userId = prefs.getString('userId');
    _isAuthenticated = _token != null && _userId != null;
    notifyListeners();
  }
} 