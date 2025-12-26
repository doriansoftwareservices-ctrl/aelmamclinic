// lib/providers/appointment_provider.dart
import 'package:flutter/material.dart';
import 'package:aelmamclinic/models/appointment.dart';
import 'package:aelmamclinic/services/db_service.dart';

class AppointmentProvider with ChangeNotifier {
  bool _hasTodayAppointments = false;
  List<Appointment> _todayAppointments = [];

  bool get hasTodayAppointments => _hasTodayAppointments;
  List<Appointment> get todayAppointments => _todayAppointments;

  // تحميل المواعيد لليوم الحالي
  Future<void> loadAppointments() async {
    final entries = await DBService.instance.getAppointmentsForToday();
    _hasTodayAppointments = entries.isNotEmpty;
    _todayAppointments = entries;
    notifyListeners();
  }

  // إضافة موعد جديد
  void addAppointment(Appointment appointment) {
    _todayAppointments.add(appointment);
    _hasTodayAppointments = _todayAppointments.isNotEmpty;
    notifyListeners();
  }
}
