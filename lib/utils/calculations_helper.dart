// lib/utils/calculations_helper.dart

/// هذا الملف يحتوي على دوال مساعدة متعلقة بالحسابات في التطبيق
/// مثل حساب الراتب الصافي، وحساب نسب الطبيب والبرج الطبي من تكلفة الخدمة، وغيرها.
library;

class CalculationsHelper {
  /// دالة لحساب الراتب الصافي للموظف.
  /// معادلة الحساب:
  /// الصافي = (finalSalary + ratioSum + doctorInput) - (totalLoans + totalDiscounts)
  static double calculateNetSalary({
    required double finalSalary,
    required double ratioSum,
    required double doctorInput,
    required double totalLoans,
    required double totalDiscounts,
  }) {
    return (finalSalary + ratioSum + doctorInput) -
        (totalLoans + totalDiscounts);
  }

  /// دالة لحساب نسب كل من الطبيب والبرج الطبي من تكلفة الخدمة.
  /// المعطيات:
  /// [serviceCost] : تكلفة الخدمة.
  /// [doctorSharePercentage] : نسبة الطبيب المخصصة لهذه الخدمة.
  /// [towerSharePercentage] : نسبة البرج الطبي المخصصة لهذه الخدمة.
  ///
  /// تُرجع الدالة خريطة (Map) تحتوي على:
  /// - 'doctorShare': حصة الطبيب من الخدمة.
  /// - 'towerShare': حصة البرج الطبي من الخدمة.
  static Map<String, double> calculateServiceShares({
    required double serviceCost,
    required double doctorSharePercentage,
    required double towerSharePercentage,
  }) {
    double doctorShare = serviceCost * (doctorSharePercentage / 100);
    double towerShare = serviceCost * (towerSharePercentage / 100);
    return {
      'doctorShare': doctorShare,
      'towerShare': towerShare,
    };
  }

  /// دالة لحساب النسبة المئوية.
  /// [part]: الجزء الذي تريد حساب نسبته.
  /// [whole]: القيمة الكاملة.
  ///
  /// ترجع الدالة النسبة المئوية للجزء من الكل.
  static double calculatePercentage({
    required double part,
    required double whole,
  }) {
    if (whole == 0) return 0;
    return (part / whole) * 100;
  }

  /// يمكنك إضافة دوال حسابية إضافية هنا حسب متطلبات التطبيق
}
