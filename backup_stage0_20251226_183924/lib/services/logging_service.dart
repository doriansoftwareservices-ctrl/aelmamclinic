// lib/services/logging_service.dart

import 'db_service.dart';

/// خدمة الرصد والتوثيق لتسجيل المعاملات المالية مع تفاصيل العملية
class LoggingService {
  // إنشاء نسخة ثابتة من الخدمة (Singleton)
  static final LoggingService _instance = LoggingService._internal();
  factory LoggingService() => _instance;
  LoggingService._internal();

  // الوصول إلى خدمة قاعدة البيانات
  final DBService _dbService = DBService.instance;

  /// يقوم بتسجيل معاملة مالية.
  /// [transactionType]: نوع المعاملة الأساسي مثل "Salary"، "Discount"، "Loan"، "Consumption"، إلخ.
  /// [operation]: نوع العملية (مثلاً "create" لإنشاء معاملة جديدة، "update" لتعديلها، أو "delete" لحذفها).
  /// [amount]: مبلغ المعاملة.
  /// [employeeId]: معرف الموظف المحلي (إن وجد). يمكن تركه فارغًا عند عدم ربط
  /// المعاملة بموظف معيّن.
  /// [description]: وصف إضافي يوضح تفاصيل المعاملة.
  /// [modificationDetails]: تفاصيل إضافية في حال حدث تعديل (مثلاً القيمة القديمة والجديدة مع تاريخ التعديل).
  /// [dateTime]: توقيت المعاملة. إذا لم يُحدد يتم استخدام الوقت الحالي.
  Future<void> logTransaction({
    required String transactionType,
    required String operation,
    required double amount,
    int? employeeId,
    String? description,
    String? modificationDetails,
    DateTime? dateTime,
  }) async {
    DateTime timestamp = dateTime ?? DateTime.now();
    final db = await _dbService.database;
    await db.insert('financial_logs', {
      'transaction_type': transactionType,
      'operation': operation,
      'amount': amount,
      'employee_id': employeeId != null ? employeeId.toString() : null,
      'description': description ?? '',
      'modification_details': modificationDetails ?? '',
      'timestamp': timestamp.toIso8601String(),
    });
  }

  /// استرجاع جميع سجلات المعاملات المالية مرتبة حسب التاريخ تنازلياً.
  Future<List<Map<String, dynamic>>> getLogs() async {
    final db = await _dbService.database;
    return await db.query('financial_logs', orderBy: 'timestamp DESC');
  }
}
