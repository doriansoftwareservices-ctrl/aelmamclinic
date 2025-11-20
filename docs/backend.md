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

## Storage: chat-attachments

- الدلو: `chat-attachments`.
- السياسات:
  - مشارك في المحادثة (`chat_attachments_insert_participant` / `chat_attachments_delete_participant`) يسمح بالرفع/الحذف عبر Sessions عادية.
  - `chat_write_service_only` يسمح لخدمات الخلفية (service_role) بالتعديل.
- العميل يستخدم `_uploadToStorage` داخل `ChatService`. أي 403 سينتج عن السياسات أعلاه ويظهر للمستخدم برسالة واضحة.

## تليمترية وتحذيرات

- `AuthProvider` يسجل `_authDiagWarn` عند فشل RPCات `my_profile`، `my_account_id`، أو `resolveAccountId`.
- `ChatProvider` يسجل `log.w` لكل فشل RPC (جلب الحساب، الدعوات، إلخ).
- راقب القيم في `lastError` من الـ Provider لإظهار الرسائل المناسبة في الواجهات.

## اختبارات دخان

راجع `docs/smoke_tests.md` لخطوات اختبار الدخان لكل دور (Super Admin، Owner، Employee، Disabled).
عند تشغيل أي سيناريو، سجل النتائج في مجلد السجلات المذكور بالأعلى مع التاريخ والوقت.*** End Patch```} to=functions.apply_patch ***!
