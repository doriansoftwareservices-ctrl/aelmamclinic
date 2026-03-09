# Final Release Acceptance Checklist

هذه القائمة هي الاعتماد النهائي للتعديلات المنفذة عبر المراحل `1` إلى `6`:
- الجلسة والمصادقة
- الإشعارات والخلفية
- تخفيف الإقلاع والترابطات الثقيلة
- التوقيع والبناء والاختبارات
- العربية/الإنجليزية والاتجاهات
- التواريخ/الأرقام/التقارير/المخرجات

لا تعتبر النسخة جاهزة للإطلاق قبل إكمال هذه القائمة بالكامل.

## 1. Prerequisites

- العمل من نسخة المشروع نفسها: `C:\Users\zidan\AndroidStudioProjects\aelmamclinic`
- وجود `config.json` أو إعدادات `Nhost` الفعلية.
- وجود `android/key.properties` الفعلي إذا كان المطلوب بناء `release`.
- توافر:
  - حساب `super_admin`
  - حساب `owner`
  - حساب `employee`
  - حساب معطل أو قابل للتعطيل
- جهاز Android فعلي واحد على الأقل.
- جهاز/محاكي ثانٍ أو حساب ثانٍ لاختبار الدردشة والإشعارات.

## 2. Execution Order

نفذ بالترتيب التالي فقط:
1. تحقق محلي static: `analyze` و`test`.
2. نشر الخادم: migrations/functions/triggers.
3. تحقق backend سريع.
4. بناء التطبيق.
5. اختبار ميداني على جهاز فعلي.
6. توثيق النتيجة النهائية `pass/fail`.

## 3. Local Static Verification

بسبب مشكلة `FVM/WSL` الحالية، نفذ هذه الأوامر من `Windows PowerShell` أو `CMD` داخل جذر المشروع، وليس من WSL، حتى يتم تجاوز مشكلة `bash\\r`.

### 3.1 Dependencies

نفذ:

```powershell
cd C:\Users\zidan\AndroidStudioProjects\aelmamclinic
flutter clean
flutter pub get
```

إذا كنت تعتمد `FVM` على ويندوز ويعمل بشكل سليم:

```powershell
fvm flutter clean
fvm flutter pub get
```

### 3.2 Analyze

نفذ:

```powershell
flutter analyze
```

المطلوب:
- `0` أخطاء compile
- لا يوجد error مرتبط بـ:
  - `LocaleProvider`
  - `NotificationService`
  - `PushNotificationsService`
  - `LocalizedText`
  - `RawStringLocalizer`

### 3.3 Tests

نفذ:

```powershell
flutter test
```

المطلوب:
- نجاح اختبارات:
  - `test/android_release_config_test.dart`
  - `test/providers/auth_provider_plan_test.dart`
  - `test/services/clinic_profile_service_test.dart`
  - `test/services/nhost_api_client_test.dart`

### 3.4 Build

للاختبار السريع:

```powershell
flutter build apk --debug
```

وللاعتماد النهائي:

```powershell
flutter build apk --release
```

المطلوب:
- عدم استخدام `debug keystore` في `release`
- نجاح build بدون أخطاء signing

## 4. Backend Deployment

### 4.1 Pull Config

```powershell
nhost config pull
```

### 4.2 Deploy Migrations + Functions

الترتيب المعتمد في هذا المشروع:

```powershell
nhost deployments new --ref HEAD --message "Apply locale and notification fixes" --user "zidan" --follow
```

المطلوب أن يتضمن النشر:
- migration:
  - `nhost/migrations/default/20260308130000_push_device_tokens_locale_code/up.sql`
- functions:
  - `functions/notify-chat-message/index.js`
  - `functions/notify-new-patient/index.js`
  - `functions/notify-plan-request/index.js`
  - `functions/_shared/notify_utils.js`

### 4.3 Push Triggers

إذا لم تكن event triggers مفعلة مسبقًا على الخادم، نفذ:

```powershell
$env:HASURA_ENDPOINT="https://<subdomain>.hasura.<region>.nhost.run"
$env:HASURA_ADMIN_SECRET="<admin-secret>"
$env:NHOST_FUNCTIONS_URL="https://<subdomain>.functions.<region>.nhost.run/v1"
bash scripts/setup_push_triggers.sh
```

المطلوب:
- نجاح:
  - `notify_chat_message`
  - `notify_new_patient`
  - `notify_plan_request`

## 5. Backend Verification

تحقق من وجود عمود اللغة في `push_device_tokens`.

### 5.1 Schema Check

```sql
select
  column_name,
  data_type,
  is_nullable,
  column_default
from information_schema.columns
where table_schema = 'public'
  and table_name = 'push_device_tokens'
  and column_name = 'locale_code';
```

المطلوب:
- `column_name = locale_code`
- `is_nullable = NO`
- default = `'ar'`

### 5.2 Data Check

```sql
select locale_code, count(*)
from public.push_device_tokens
group by locale_code
order by locale_code;
```

المطلوب:
- القيم فقط ضمن:
  - `ar`
  - `en`

### 5.3 Trigger / Function Smoke

نفذ إدخالات فعلية من التطبيق أو من قاعدة البيانات ثم تحقق من:
- إدخال دردشة جديد -> `notify-chat-message`
- مريض جديد -> `notify-new-patient`
- طلب ترقية/مقعد -> `notify-plan-request`

## 6. App Runtime Acceptance

## 6.1 Session Persistence

نفذ لكل دور:
- `super_admin`
- `owner`
- `employee`

الخطوات:
1. سجل الدخول.
2. أغلق التطبيق بالكامل.
3. افتحه مجددًا.

المطلوب:
- لا يعاد طلب تسجيل الدخول إن كانت الجلسة صالحة.
- يعود المستخدم إلى الشاشة الصحيحة بحسب الدور.
- لا تظهر بيانات حساب قديم.

## 6.2 Language Toggle

الخطوات:
1. افتح التطبيق أول مرة.
2. تأكد أن اللغة الافتراضية `AR`.
3. اضغط زر `EN`.
4. أغلق التطبيق وافتحه.
5. ارجع إلى `AR`.

المطلوب:
- `AR`:
  - كل الشاشات الأساسية عربية
  - الاتجاه `RTL`
- `EN`:
  - كل الشاشات الأساسية إنجليزية
  - الاتجاه `LTR`
- اللغة تبقى محفوظة بعد إعادة الفتح.

## 6.3 Role Screens

### Super Admin

تحقق من:
- `Admin Dashboard`
- tabs
- subscriptions
- statistics
- support ratings

المطلوب:
- عدم تحميل كل الأقسام دفعة واحدة
- عدم وجود نصوص عربية ثابتة عند `EN`
- عدم وجود محاذاة/اتجاه مكسور

### Owner

تحقق من:
- الإحصائيات
- المرضى
- الوصفات
- العيادة
- المستودع
- الدردشة

### Employee

تحقق من:
- الشاشات المسموح بها فقط
- رسائل المنع واضحة ومترجمة

## 6.4 Reports and Exports

اختبر:
- `Patient PDF`
- `Prescription PDF`
- `Statistics PDF`
- `Clinic HTML export`
- `Excel export`

لكل من `AR` و`EN`.

المطلوب:
- `AR`:
  - labels عربية
  - اتجاه `RTL`
- `EN`:
  - labels إنجليزية
  - اتجاه `LTR`
- أسماء الملفات المصدرة تبقى آمنة.

## 6.5 Dates / Numbers / Currency

اختبر في:
- `statistics`
- `financial logs`
- `returns`
- `patients`

المطلوب:
- التواريخ تتغير مع اللغة.
- الأرقام المحلية تتغير مع اللغة.
- pickers تعمل باللغة والاتجاه الصحيحين.

## 6.6 Local Notifications

اختبر:
- إشعار دردشة محلي
- إشعار مريض
- إشعار إداري
- إشعار انخفاض مخزون
- إشعار موعد مجدول

المطلوب:
- عنوان ومحتوى الإشعار باللغة الحالية.
- channel name/description الصحيحين بحسب اللغة.
- عند تغيير اللغة ثم إرسال إشعار جديد، يظهر باللغة الجديدة.

## 6.7 Scheduled Reminder After Language Switch

هذا بند إلزامي لأن تم إصلاحه خصيصًا.

الخطوات:
1. اجعل اللغة `AR`.
2. أنشئ `return reminder` بعد 2-5 دقائق.
3. بدّل اللغة إلى `EN` قبل موعد الإشعار.
4. انتظر الإشعار.
5. كرر بالعكس من `EN` إلى `AR`.

المطلوب:
- يصل الإشعار المجدول باللغة الحالية وقت الإطلاق، لا لغة وقت الإنشاء.

## 6.8 Push Notifications by Locale

اختبر لكل من `AR` و`EN`, وفي الحالات:
- `foreground`
- `background`
- `terminated`

أنواع الإشعارات:
- `chat`
- `patient`
- `plan_request`
- `seat_request`

المطلوب:
- عنوان ومحتوى الإشعار بلغة الحساب/الجهاز المستهدف.
- الضغط على الإشعار يفتح الشاشة الصحيحة.
- `getInitialMessage()` يعمل من حالة الإغلاق الكامل.

## 6.9 Account Switching on Same Device

الخطوات:
1. سجل الدخول بحساب `owner`.
2. استقبل إشعارًا.
3. سجل الخروج.
4. غيّر اللغة.
5. سجل الدخول بحساب `employee`.
6. استقبل إشعارًا جديدًا.

المطلوب:
- لا تصل إشعارات الحساب القديم.
- لا تُحمل بيانات الحساب القديم.
- يتغير `push_device_tokens.user_uid/account_id/locale_code` للحساب الجديد.

## 6.10 Low Stock Alerts

الخطوات:
1. اجعل اللغة `AR` ثم أطلق تنبيه انخفاض مخزون.
2. بدّل إلى `EN` ثم أطلق تنبيهًا آخر.

المطلوب:
- اسم القناة، عنوان الإشعار، النص، و`group summary` كلها تتبدل مع اللغة.

## 6.11 Offline / Sync

الخطوات:
1. سجل الدخول.
2. افصل الشبكة.
3. أنشئ بيانات محلية.
4. بدّل اللغة أثناء وضع offline.
5. أعد الشبكة.

المطلوب:
- لا تتلف الجلسة.
- لا ينكسر `sync`.
- تبقى اللغة الحالية محفوظة وصحيحة بعد reconnect.

## 7. Release Stop Conditions

لا تطلق النسخة إذا فشل أي بند من الآتي:
- `flutter analyze` يفشل
- `flutter test` يفشل
- `locale_code` غير موجود في `push_device_tokens`
- `plan_request/seat_request/chat/patient` لا تصل بلغة صحيحة
- تذكير مجدول لا يتغير مع اللغة
- بقاء طلب تسجيل الدخول بعد إعادة الفتح بدون سبب
- تسرب إشعار لحساب قديم بعد تبديل الحساب
- كسر واضح في `RTL/LTR`

## 8. Evidence Template

لكل سيناريو سجل:
- التاريخ والوقت
- رقم build
- نوع الجهاز
- إصدار Android
- الدور
- اللغة
- حالة التطبيق:
  - `foreground`
  - `background`
  - `terminated`
- النتيجة:
  - `pass`
  - `fail`
- ملاحظات
- screenshot أو log عند الفشل

## 9. Final Sign-Off

لا تعتبر النسخة معتمدة إلا إذا تحققت الشروط التالية كلها:
- static verification = `pass`
- backend deployment = `pass`
- backend verification = `pass`
- manual runtime matrix = `pass`
- push locale matrix = `pass`
- reports/exports = `pass`
- session persistence = `pass`
- account switching = `pass`

