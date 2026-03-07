//C:\Users\zidan\AndroidStudioProjects\aelmamclinic\lib\services\export_service.dart
import 'package:excel/excel.dart';
import 'dart:typed_data';

import 'package:aelmamclinic/models/patient.dart';
import 'package:aelmamclinic/models/consumption.dart';
import 'package:aelmamclinic/models/return_entry.dart';
import 'package:aelmamclinic/models/doctor.dart';
import 'package:aelmamclinic/models/admin_action_log.dart';
import 'package:aelmamclinic/models/admin_audit_activity.dart';
import 'package:aelmamclinic/models/admin_audit_actor.dart';

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
      'Collateral',
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
        p.collateral ?? '',
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

  // تصدير سجلات أوامر السوبر أدمن إلى ملف Excel
  static Future<Uint8List> exportAdminActionLogsToExcel(
      List<AdminActionLog> logs) async {
    final excel = Excel.createExcel();
    final sheet = excel['AdminActions'];

    sheet.appendRow([
      'ID',
      'Actor UID',
      'Actor Email',
      'Action',
      'Entity Type',
      'Entity ID',
      'Created At',
      'Details',
    ]);

    for (final log in logs) {
      sheet.appendRow([
        log.id,
        log.actorUid,
        log.actorEmail ?? '',
        log.action,
        log.entityType,
        log.entityId ?? '',
        log.createdAt.toIso8601String(),
        log.details == null ? '' : log.details.toString(),
      ]);
    }

    return Uint8List.fromList(excel.encode()!);
  }

  static Future<Uint8List> exportAdminAuditActivityDailyToExcel(
      List<AdminAuditActivity> rows) async {
    final excel = Excel.createExcel();
    final sheet = excel['AuditDaily'];
    sheet.appendRow(['Day', 'Table', 'Op', 'Events']);
    for (final r in rows) {
      sheet.appendRow([
        r.day.toIso8601String(),
        r.tableName,
        r.op,
        r.events,
      ]);
    }
    return Uint8List.fromList(excel.encode()!);
  }

  static Future<Uint8List> exportAdminAuditTopActorsToExcel(
      List<AdminAuditActor> rows) async {
    final excel = Excel.createExcel();
    final sheet = excel['AuditTopActors'];
    sheet.appendRow(['Actor UID', 'Actor Email', 'Events', 'Last At']);
    for (final r in rows) {
      sheet.appendRow([
        r.actorUid ?? '',
        r.actorEmail ?? '',
        r.events,
        r.lastAt?.toIso8601String() ?? '',
      ]);
    }
    return Uint8List.fromList(excel.encode()!);
  }
}
