//C:\Users\zidan\AndroidStudioProjects\aelmamclinic\lib\services\export_service.dart
import 'package:excel/excel.dart';
import 'dart:typed_data';

import 'package:aelmamclinic/models/patient.dart';
import 'package:aelmamclinic/models/consumption.dart';
import 'package:aelmamclinic/models/return_entry.dart';
import 'package:aelmamclinic/models/doctor.dart';

class ExportService {
  // تصدير المرضى مع إضافة بيانات الطبيب وبيانات البرج الطبي (Tower Share)
  static Future<Uint8List> exportPatientsToExcel(List<Patient> patients) async {
    final excel = Excel.createExcel();
    final sheet = excel['Patients'];

    sheet.appendRow([
      'ID',
      'Name',
      'Age',
      'Phone',
      'Diagnosis',
      'Doctor Name',
      'Doctor Specialization',
      'Paid',
      'Remaining',
      'Tower Share',
      'RegisterDate',
      'Notes'
    ]);

    for (var p in patients) {
      sheet.appendRow([
        p.id ?? '',
        p.name,
        p.age,
        p.phoneNumber,
        p.diagnosis,
        p.doctorName ?? '',
        p.doctorSpecialization ?? '',
        p.paidAmount,
        p.remaining,
        p.towerShare,
        p.registerDate.toIso8601String(),
        p.notes ?? '',
      ]);
    }

    final data = excel.encode()!;
    return Uint8List.fromList(data);
  }

  // تصدير الاستهلاك إلى ملف Excel
  static Future<Uint8List> exportConsumptionToExcel(
      List<Consumption> items) async {
    final excel = Excel.createExcel();
    final sheet = excel['Consumption'];

    sheet.appendRow(['ID', 'Date', 'Amount', 'Note']);

    for (var c in items) {
      sheet.appendRow([
        c.id ?? '',
        c.date.toIso8601String(),
        c.amount,
        c.note,
      ]);
    }

    return Uint8List.fromList(excel.encode()!);
  }

  // تصدير العودات إلى ملف Excel
  static Future<Uint8List> exportReturnsToExcel(
      List<ReturnEntry> returns) async {
    final excel = Excel.createExcel();
    final sheet = excel['Returns'];

    sheet.appendRow([
      'ID',
      'Patient Name',
      'Phone Number',
      'Age',
      'Doctor',
      'Diagnosis',
      'Date',
      'Remaining',
      'Notes',
    ]);

    for (var r in returns) {
      sheet.appendRow([
        r.id ?? '',
        r.patientName,
        r.phoneNumber,
        r.age,
        r.doctor,
        r.diagnosis,
        r.date.toIso8601String(),
        r.remaining,
        r.notes,
      ]);
    }

    final data = excel.encode()!;
    return Uint8List.fromList(data);
  }

  // تصدير بيانات الأطباء إلى ملف Excel
  static Future<Uint8List> exportDoctorsToExcel(List<Doctor> doctors) async {
    final excel = Excel.createExcel();
    final sheet = excel['Doctors'];

    sheet.appendRow([
      'ID',
      'Doctor Name',
      'Specialization',
      'Phone Number',
      'Start Time',
      'End Time'
    ]);

    for (var d in doctors) {
      sheet.appendRow([
        d.id ?? '',
        d.name,
        d.specialization,
        d.phoneNumber,
        d.startTime,
        d.endTime,
      ]);
    }

    final data = excel.encode()!;
    return Uint8List.fromList(data);
  }

  // تصدير بيانات الموظفين إلى ملف Excel
  static Future<Uint8List> exportEmployeesToExcel(
      List<Map<String, dynamic>> employees) async {
    final excel = Excel.createExcel();
    final sheet = excel['Employees'];

    sheet.appendRow([
      'ID',
      'Name',
      'Identity',
      'Phone',
      'Job Title',
      'Address',
      'Marital Status',
      'Basic Salary',
      'Final Salary',
    ]);

    for (var emp in employees) {
      sheet.appendRow([
        emp['id'] ?? '',
        emp['name'] ?? '',
        emp['identityNumber'] ?? '',
        emp['phoneNumber'] ?? '',
        emp['jobTitle'] ?? '',
        emp['address'] ?? '',
        emp['maritalStatus'] ?? '',
        emp['basicSalary'] ?? 0.0,
        emp['finalSalary'] ?? 0.0,
      ]);
    }

    final data = excel.encode()!;
    return Uint8List.fromList(data);
  }
}
