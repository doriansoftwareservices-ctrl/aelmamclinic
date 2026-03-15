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
import 'package:aelmamclinic/utils/report_localizer.dart';

class ExportService {
  // تصدير المرضى مع إضافة بيانات الطبيب وبيانات البرج الطبي (Tower Share)
  static Future<Uint8List> exportPatientsToExcel(List<Patient> patients) async {
    final i18n = ReportLocalizer();
    final excel = Excel.createExcel();
    final sheet = excel[i18n.isRtl ? 'المرضى' : 'Patients'];

    sheet.appendRow([
      'ID',
      i18n.isRtl ? 'الاسم' : 'Name',
      i18n.isRtl ? 'العمر' : 'Age',
      i18n.isRtl ? 'رقم الهاتف' : 'Phone',
      i18n.isRtl ? 'التشخيص' : 'Diagnosis',
      i18n.isRtl ? 'اسم الطبيب' : 'Doctor name',
      i18n.isRtl ? 'تخصص الطبيب' : 'Doctor specialization',
      i18n.isRtl ? 'المدفوع' : 'Paid',
      i18n.isRtl ? 'المتبقي' : 'Remaining',
      i18n.isRtl ? 'الرهن' : 'Collateral',
      i18n.isRtl ? 'حصة البرج الطبي' : 'Tower share',
      i18n.isRtl ? 'تاريخ التسجيل' : 'Register date',
      i18n.isRtl ? 'ملاحظات' : 'Notes',
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
    final i18n = ReportLocalizer();
    final excel = Excel.createExcel();
    final sheet = excel[i18n.isRtl ? 'الاستهلاك' : 'Consumption'];

    sheet.appendRow([
      'ID',
      i18n.isRtl ? 'التاريخ' : 'Date',
      i18n.isRtl ? 'المبلغ' : 'Amount',
      i18n.isRtl ? 'ملاحظة' : 'Note',
    ]);

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
    final i18n = ReportLocalizer();
    final excel = Excel.createExcel();
    final sheet = excel[i18n.isRtl ? 'العودات' : 'Returns'];

    sheet.appendRow([
      'ID',
      i18n.isRtl ? 'اسم المريض' : 'Patient name',
      i18n.isRtl ? 'رقم الهاتف' : 'Phone number',
      i18n.isRtl ? 'العمر' : 'Age',
      i18n.isRtl ? 'الطبيب' : 'Doctor',
      i18n.isRtl ? 'التشخيص' : 'Diagnosis',
      i18n.isRtl ? 'التاريخ' : 'Date',
      i18n.isRtl ? 'المتبقي' : 'Remaining',
      i18n.isRtl ? 'ملاحظات' : 'Notes',
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
    final i18n = ReportLocalizer();
    final excel = Excel.createExcel();
    final sheet = excel[i18n.isRtl ? 'الأطباء' : 'Doctors'];

    sheet.appendRow([
      'ID',
      i18n.isRtl ? 'اسم الطبيب' : 'Doctor name',
      i18n.isRtl ? 'التخصص' : 'Specialization',
      i18n.isRtl ? 'رقم الهاتف' : 'Phone number',
      i18n.isRtl ? 'وقت البداية' : 'Start time',
      i18n.isRtl ? 'وقت النهاية' : 'End time',
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
    final i18n = ReportLocalizer();
    final excel = Excel.createExcel();
    final sheet = excel[i18n.isRtl ? 'الموظفون' : 'Employees'];

    sheet.appendRow([
      'ID',
      i18n.isRtl ? 'الاسم' : 'Name',
      i18n.isRtl ? 'رقم الهوية' : 'Identity',
      i18n.isRtl ? 'رقم الهاتف' : 'Phone',
      i18n.isRtl ? 'المسمى الوظيفي' : 'Job title',
      i18n.isRtl ? 'العنوان' : 'Address',
      i18n.isRtl ? 'الحالة الاجتماعية' : 'Marital status',
      i18n.isRtl ? 'الراتب الأساسي' : 'Basic salary',
      i18n.isRtl ? 'الراتب النهائي' : 'Final salary',
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
    final i18n = ReportLocalizer();
    final excel = Excel.createExcel();
    final sheet = excel[i18n.isRtl ? 'أوامر الإدارة' : 'AdminActions'];

    sheet.appendRow([
      'ID',
      i18n.isRtl ? 'معرف المنفذ' : 'Actor UID',
      i18n.isRtl ? 'بريد المنفذ' : 'Actor email',
      i18n.isRtl ? 'الإجراء' : 'Action',
      i18n.isRtl ? 'نوع الكيان' : 'Entity type',
      i18n.isRtl ? 'معرف الكيان' : 'Entity ID',
      i18n.isRtl ? 'وقت الإنشاء' : 'Created at',
      i18n.isRtl ? 'التفاصيل' : 'Details',
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
    final i18n = ReportLocalizer();
    final excel = Excel.createExcel();
    final sheet = excel[i18n.isRtl ? 'التدقيق اليومي' : 'AuditDaily'];
    sheet.appendRow([
      i18n.isRtl ? 'اليوم' : 'Day',
      i18n.isRtl ? 'الجدول' : 'Table',
      i18n.isRtl ? 'العملية' : 'Op',
      i18n.isRtl ? 'الأحداث' : 'Events',
    ]);
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
    final i18n = ReportLocalizer();
    final excel = Excel.createExcel();
    final sheet = excel[i18n.isRtl ? 'أكثر المنفذين نشاطًا' : 'AuditTopActors'];
    sheet.appendRow([
      i18n.isRtl ? 'معرف المنفذ' : 'Actor UID',
      i18n.isRtl ? 'بريد المنفذ' : 'Actor email',
      i18n.isRtl ? 'الأحداث' : 'Events',
      i18n.isRtl ? 'آخر وقت' : 'Last at',
    ]);
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
