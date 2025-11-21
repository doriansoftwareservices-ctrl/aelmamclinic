// lib/providers/theme_provider.dart
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeProvider extends ChangeNotifier {
  ThemeMode _themeMode = ThemeMode.light;
  static const String themePrefKey = 'theme_mode';

  ThemeProvider({SharedPreferences? prefs})
      : _prefsOverride = prefs {
    ready = _loadTheme();
  }

  final SharedPreferences? _prefsOverride;
  late final Future<void> ready;

  ThemeMode get themeMode => _themeMode;

  void toggleTheme() {
    _themeMode =
        _themeMode == ThemeMode.light ? ThemeMode.dark : ThemeMode.light;
    _saveTheme();
    notifyListeners();
  }

  Future<void> _loadTheme() async {
    final prefs = _prefsOverride ?? await SharedPreferences.getInstance();
    final themeIndex = prefs.getInt(themePrefKey);

    if (themeIndex == null ||
        themeIndex < 0 ||
        themeIndex >= ThemeMode.values.length) {
      _themeMode = ThemeMode.light;
      await prefs.setInt(themePrefKey, _themeMode.index);
    } else {
      _themeMode = ThemeMode.values[themeIndex];
    }

    notifyListeners();
  }

  Future<void> _saveTheme() async {
    final prefs = _prefsOverride ?? await SharedPreferences.getInstance();
    await prefs.setInt(themePrefKey, _themeMode.index);
  }
}
