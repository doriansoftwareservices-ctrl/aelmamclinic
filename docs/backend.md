# Backend Integration

مستند مرجعي يوضح العقد الحالي بين تطبيق Flutter وطبقة Supabase.
يجب تحديثه كلما تغيّرت الدوال أو السياسات.
سجلات تنفيذ الإصلاحات مخزّنة تحت:
`\\wsl.localhost\Ubuntu-24.04\home\zidan\dev\aelmamclinic\.ci\logs\2025-11-16_19-23`.

## بيئة Supabase

- **Supabase URL/Anon Key** تأتي من `AppConstants` أو ملفات الإعداد (راجع `lib/core/constants.dart`).
- **نسخ Flutter محليّة** تقرأ الدوال/المفاتيح قبل `runApp`.
- تأكد من تشغيل `supabase start` (أو البيئة السحابية) قبل أي اختبار.

## دوال RPC الحرجة

| الدالة | معاملاتها | الغرض | ملاحظات |
|--------|-----------|-------|---------|
| `my_feature_permissions(p_account uuid)` | `p_account`: معرّف العيادة الحالية | إعادة أذونات الخصائص و CRUD لكل مستخدم | يجب أن تعيد `{allowed_features[],can_create,...}` وإلا ستتعطل شاشات المستودع. |
| `my_profile()` / `my_account_id()` | لا شيء | تحديد العيادة والحالة | يتم استدعاؤها أثناء `AuthProvider._refreshUser`. أي فشل يسجَّل عبر `_authDiagWarn`. |
| `chat_accept_invitation(p_invitation_id uuid)` | معرف الدعوة | يحدّث الدعوة، يسجّل المستَخدم في `chat_participants` | يعاد JSON `{ok: true}`. أي قيمة أخرى = خطأ. |
| `chat_decline_invitation(p_invitation_id uuid, p_note text?)` | معرف الدعوة + ملاحظة اختيارية | وضع الدعوة في حالة `declined` | يجب أن تعيد `{ok: true}`. |
| `chat_mark_delivered(p_message_ids uuid[])` | قائمة معرفات رسائل | تسجيل الاستلام | يُستدعى بعد جلب الرسائل/المرفقات. |
| `admin_*` RPCs | مختلفة | إدارة المالكين والموظفين | غير مستخدمة في مرحلة الدخان، لكن أي تعديل يتطلب تحديث هذا الجدول. |

## الباقات والميزات (Plans/Features)

المصدر الأساسي لصلاحيات الباقة هو جدول `plan_features` ثم يتم إسقاطه إلى
`account_feature_permissions` عبر دالة `apply_plan_permissions`.

الجداول ذات الصلة:
- `subscription_plans`: تعريف الباقات (FREE/MONTH/YEAR).
- `plan_features`: مصفوفة ربط الباقة ← الميزة (feature_key).
- `account_subscriptions`: الاشتراك النشط لكل حساب.
- `account_feature_permissions`: الصلاحيات المطبقة فعليًا على الحساب/المستخدم.
- `subscription_requests`: طلبات الترقية، وتشمل `proof_url` (معرّف الملف في التخزين) وحقول مرجعية الدفع.

الدوال ذات الصلة:
- `plan_allowed_features(p_plan text)`: تُعيد قائمة مفاتيح الميزات المسموحة للباقة.
- `apply_plan_permissions(p_account uuid, p_plan text)`: تُطبّق صلاحيات الباقة على الحساب.
- `my_account_plan()`: تُعيد الباقة النشطة للحساب الحالي مع `plan_end_at` (fallback = free).
- `admin_approve_subscription_request(...)`: اعتماد طلب اشتراك وتفعيل الخطة.
- `admin_reject_subscription_request(...)`: رفض طلب الاشتراك مع سبب.
- `admin_set_account_plan(...)`: تغيير خطة الحساب يدويًا (سوبر أدمن).
- `expire_account_subscriptions(p_dry_run boolean)`: إنهاء الاشتراكات المنتهية وفق grace_days.
- `self_create_account(p_clinic_name text)`: إنشاء حساب مالك جديد بخطة FREE وتوليد الصلاحيات الافتراضية.
- `account_is_paid(p_account uuid)`: يحدد إن كانت العيادة على خطة مدفوعة ضمن فترة السماح.
- `fn_is_account_member(p_account uuid)`: يمنع دخول الموظفين عندما تكون الخطة FREE (يُسمح للمالك فقط).
- `admin_payment_stats_by_plan()`: إحصاءات المدفوعات حسب الباقة.
- `admin_payment_stats_by_month()`: إحصاءات المدفوعات حسب الشهر.
- `admin_payment_stats_by_day()`: إحصاءات المدفوعات حسب اليوم.

## Storage: chat-attachments

- الدلو: `chat-attachments`.
- السياسات:
  - مشارك في المحادثة (`chat_attachments_insert_participant` / `chat_attachments_delete_participant`) يسمح بالرفع/الحذف عبر Sessions عادية.
  - `chat_write_service_only` يسمح لخدمات الخلفية (service_role) بالتعديل.
- العميل يستخدم `_uploadToStorage` داخل `ChatService`. أي 403 سينتج عن السياسات أعلاه ويظهر للمستخدم برسالة واضحة.

## Storage: subscription-proofs

- الدلو: `subscription-proofs`.
- يستخدم لرفع إثباتات الدفع للترقية.
- يتم تخزين معرف الملف في `subscription_requests.proof_url`.

## Cron: انتهاء الاشتراكات

- Trigger: `expire_account_subscriptions_daily`
- يستدعي `expire_account_subscriptions(p_dry_run=false)` يوميًا عبر GraphQL.

## تليمترية وتحذيرات

- `AuthProvider` يسجل `_authDiagWarn` عند فشل RPCات `my_profile`، `my_account_id`، أو `resolveAccountId`.
- `ChatProvider` يسجل `log.w` لكل فشل RPC (جلب الحساب، الدعوات، إلخ).
- راقب القيم في `lastError` من الـ Provider لإظهار الرسائل المناسبة في الواجهات.

## اختبارات دخان

راجع `docs/smoke_tests.md` لخطوات اختبار الدخان لكل دور (Super Admin، Owner، Employee، Disabled).
عند تشغيل أي سيناريو، سجل النتائج في مجلد السجلات المذكور بالأعلى مع التاريخ والوقت.
