// lib/providers/theme_provider.dart
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeProvider extends ChangeNotifier {
  ThemeMode _themeMode = ThemeMode.light;
  static const String themePrefKey = 'theme_mode';

  ThemeProvider() {
    _loadTheme();
  }

  ThemeMode get themeMode => _themeMode;

  void toggleTheme() {
    _themeMode =
        _themeMode == ThemeMode.light ? ThemeMode.dark : ThemeMode.light;
    _saveTheme();
    notifyListeners();
  }

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final storedIndex = prefs.getInt(themePrefKey);
    if (storedIndex == null ||
        storedIndex < 0 ||
        storedIndex >= ThemeMode.values.length) {
      _themeMode = ThemeMode.light;
    } else {
      _themeMode = ThemeMode.values[storedIndex];
    }
    notifyListeners();
  }

  Future<void> _saveTheme() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt(themePrefKey, _themeMode.index);
  }
}
