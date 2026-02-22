// lib/screens/help/user_guide_screen.dart
//
// شاشة "دليل الاستخدام" — شرح مرتب لمسارات التطبيق.

import 'package:flutter/material.dart';

class UserGuideScreen extends StatelessWidget {
  const UserGuideScreen({super.key});

  static const routeName = '/user-guide';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('دليل الاستخدام'),
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _HeaderCard(scheme: scheme),
            const SizedBox(height: 16),
            const _Section(
              title: '1) بدء الاستخدام وتسجيل الدخول',
              bullets: [
                'أدخل بريدًا صحيحًا وكلمة مرور لا تقل عن 9 أحرف.',
                'إذا كنت مالكًا جديدًا: أنشئ الحساب ثم أكمل بيانات العيادة.',
                'إذا تم تجميد الحساب أو تعطيله ستُمنع من المتابعة تلقائيًا.',
              ],
            ),
            const _Section(
              title: 'قواعد استخدام نظام Elmam Clinic لأول مرة',
              bullets: [
                'يرجى اتباع الخطوات بالترتيب بدقة حتى اكتمال دليل الاستخدام المرئي.',
                'الخطوة التالية: إضافة موظف جديد → شؤون الموظفين → إنشاء موظف → أدخل البيانات، واربط الموظف بحساب إذا كان طبيبًا (إلزامي). المحاسب/خدمة العملاء يلزمهم حساب خاص. ثم حفظ.',
                'الخطوة التالية: إضافة طبيب جديد → شؤون الموظفين → الأطباء → إضافة طبيب → اختر اسم الموظف المصنّف كطبيب (مرة واحدة فقط).',
                'الخطوة التالية: إضافة خدمات الأطباء → شؤون الموظفين → خدمات الأطباء → اسم الطبيب → إضافة خدمة → أدخل (اسم الخدمة + المبلغ + نسبة المركز). إذا نسبة المركز 70% فالطبيب 30% تلقائيًا. وإذا لديك ملف اكسل للخدمات تواصل مع خدمة العملاء لإدراجه.',
                'الخطوة التالية: إضافة أسئلة التشخيص للمرضى → شاشة "أسئلة التشخيص للمرضى" → أضف نوع الحالة (مثل صداع مزمن) ثم أضف الأسئلة الخاصة بها.',
                'الخطوة التالية: إضافة أصناف المستودع → قسم المستودع → إضافة صنف جديد → أدخل (نوع الصنف + اسم الصنف) ثم حفظ.',
                'الخطوة التالية: تسجيل المشتريات → قسم المستودع → مشتريات جديدة → اختر (الصنف + الكمية + السعر الفردي) ثم حفظ.',
                'الخطوة التالية: تسجيل مريض جديد (حساب استقبال المرضى) → تسجيل مريض جديد → املأ البيانات الأساسية واختر نوع الخدمة "طبيب" وحدد الطبيب.',
                'الخطوة التالية بعد زيارة الطبيب: "تم مقابلة الطبيب" ثم تسجيل الأدوات المستخدمة من المستودع ثم "إنشاء تقرير" وتعبئته ثم حفظ/طباعة.',
                'الخطوة التالية: إضافة مدفوعات مالية → الشؤون المالية → استهلاكات المرفق الطبي → إضافة مبلغ → اختر/أضف نوع المصروف ثم (+) ثم أدخل المبلغ ثم حفظ.',
                'الخطوة التالية: إضافة وصفات طبية → الوصفات الطبية → إدارة الأدوية → إضافة دواء من أسفل يسار الشاشة → حفظ.',
                'الخطوة التالية: طباعة وصفة طبية للمريض → الوصفات الطبية → وصفات المرضى → اختيار المريض → تحديد الطبيب والدواء ثم حفظ.',
              ],
            ),
            const _Section(
              title: '2) إعداد بيانات العيادة وخطة الاشتراك',
              bullets: [
                'أكمل بيانات المرفق الصحي (الاسم، العنوان، الهاتف).',
                'تحقق من "خطتي" لمعرفة القيود أو طلب ترقية عند الحاجة.',
              ],
            ),
            const _Section(
              title: '3) لوحة الإحصاءات',
              bullets: [
                'اطّلع على المؤشرات الأساسية للزيارات والإيرادات.',
                'استخدم الفلاتر الزمنية لتحليل الأداء.',
              ],
            ),
            const _Section(
              title: '4) المرضى',
              bullets: [
                'سجّل مريضًا جديدًا ثم أضف بياناته الأساسية.',
                'استخدم قائمة المرضى للبحث والتعديل.',
                'أسئلة التشخيص تُدار من شاشة أسئلة التشخيص.',
              ],
            ),
            const _Section(
              title: '5) المواعيد والخدمات',
              bullets: [
                'أنشئ المواعيد وربطها بالطبيب والخدمة.',
                'تحكم بالحالات (مؤكد/ملغى/قيد الانتظار).',
              ],
            ),
            const _Section(
              title: '6) الوصفات الطبية',
              bullets: [
                'أضف وصفة جديدة وحدد الأصناف والجرعات.',
                'يمكن طباعة الوصفة أو حفظها ضمن ملف المريض.',
              ],
            ),
            const _Section(
              title: '7) المستودع',
              bullets: [
                'أنشئ أنواع الأصناف ثم أضف الأصناف.',
                'سجّل المشتريات والاستهلاك والمرتجعات.',
                'تابع تنبيهات انخفاض المخزون.',
              ],
            ),
            const _Section(
              title: '8) شؤون الموظفين',
              bullets: [
                'إدارة حسابات الموظفين وصلاحياتهم.',
                'إدارة الرواتب والسلف والخصومات.',
              ],
            ),
            const _Section(
              title: '9) الشؤون المالية',
              bullets: [
                'سجّل طرق الدفع وتتبع المدفوعات.',
                'تحقق من إحصاءات الدفع حسب الخطة/الفترة.',
              ],
            ),
            const _Section(
              title: '10) الشكاوى والأعطال',
              bullets: [
                'أرسل بلاغًا عند وجود مشكلة.',
                'تابع حالة البلاغ من الشاشة نفسها.',
              ],
            ),
            const _Section(
              title: '11) النسخ الاحتياطي والاسترجاع',
              bullets: [
                'شغّل النسخ الاحتياطي حسب الجدول الموصى به.',
                'استرجع النسخة فقط عند الحاجة لضمان سلامة البيانات.',
              ],
            ),
            const _Section(
              title: '12) الصلاحيات والسجلات (للمالك/الإدارة)',
              bullets: [
                'تحكم بالصلاحيات حسب الدور (مالك/مدير/موظف).',
                'راجع سجلات العمليات لتتبع التغييرات.',
              ],
            ),
            const _Section(
              title: '13) الدردشة (بدون صور ومرفقات)',
              bullets: [
                'الدردشة نصية فقط لتخفيف الضغط على الخادم.',
                'لا يوجد إنشاء مجموعات أو مشاركة ملفات في الوقت الحالي.',
              ],
            ),
            const _Section(
              title: '14) حسابات السوبر أدمن (للجذر فقط)',
              bullets: [
                'حساب الجذر فقط يرى تبويب "حسابات السوبر أدمن".',
                'يمكن إنشاء/تعطيل/حذف حسابات سوبر أدمن وتحديد التبويبات.',
                'يمكن إعادة تعيين كلمة مرور حساب سوبر أدمن عند الحاجة.',
              ],
            ),
            const SizedBox(height: 8),
            _FooterCard(scheme: scheme),
          ],
        ),
      ),
    );
  }
}

class _HeaderCard extends StatelessWidget {
  const _HeaderCard({required this.scheme});

  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: scheme.surfaceContainerHighest,
      elevation: 0,
      child: const Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'مرحبًا بك في دليل الاستخدام',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 6),
            Text(
              'اتبع الخطوات التالية بالترتيب لضمان تشغيل سلس وآمن.',
            ),
          ],
        ),
      ),
    );
  }
}

class _FooterCard extends StatelessWidget {
  const _FooterCard({required this.scheme});

  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: scheme.surfaceContainerHighest,
      elevation: 0,
      child: const Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'ملاحظات مهمة',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 6),
            Text('• كلمة المرور يجب أن تكون 9 أحرف أو أكثر.'),
            Text('• الحسابات المجمّدة/المعطّلة لن تتمكن من الدخول.'),
            Text('• إذا لم يظهر حسابك بعد التسجيل، أكمل إنشاء العيادة أولًا.'),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.bullets});

  final String title;
  final List<String> bullets;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            for (final item in bullets)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('• '),
                    Expanded(child: Text(item)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
