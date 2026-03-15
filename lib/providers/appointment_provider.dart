// lib/providers/appointment_provider.dart
import 'package:flutter/material.dart';
import 'package:aelmamclinic/models/appointment.dart';
import 'package:aelmamclinic/services/db_service.dart';

class AppointmentProvider with ChangeNotifier {
  bool _hasTodayAppointments = false;
  List<Appointment> _todayAppointments = [];
  bool _loading = false;
  bool _loaded = false;
  DateTime? _lastLoadedAt;

  bool get hasTodayAppointments => _hasTodayAppointments;
  List<Appointment> get todayAppointments => _todayAppointments;
  bool get isLoading => _loading;
  bool get isLoaded => _loaded;

  // تحميل المواعيد لليوم الحالي
  Future<void> loadAppointments({bool force = false}) async {
    if (_loading) return;
    if (!force && _loaded && _isSameDay(_lastLoadedAt, DateTime.now())) {
      return;
    }
    _loading = true;
    try {
      final entries = await DBService.instance.getAppointmentsForToday();
      _hasTodayAppointments = entries.isNotEmpty;
      _todayAppointments = entries;
      _loaded = true;
      _lastLoadedAt = DateTime.now();
      notifyListeners();
    } finally {
      _loading = false;
    }
  }

  Future<void> ensureLoaded({bool force = false}) async {
    await loadAppointments(force: force);
  }

  // إضافة موعد جديد
  void addAppointment(Appointment appointment) {
    _todayAppointments.add(appointment);
    _hasTodayAppointments = _todayAppointments.isNotEmpty;
    _loaded = true;
    _lastLoadedAt = DateTime.now();
    notifyListeners();
  }

  bool _isSameDay(DateTime? a, DateTime b) {
    if (a == null) return false;
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }
}
