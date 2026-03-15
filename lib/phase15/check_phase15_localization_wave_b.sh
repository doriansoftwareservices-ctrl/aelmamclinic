#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

FILES_EXPORT=(
  "$ROOT/lib/screens/returns/list_returns_screen.dart"
  "$ROOT/lib/screens/patients/list_patients_screen.dart"
  "$ROOT/lib/screens/employees/list_employees_screen.dart"
  "$ROOT/lib/screens/patients/view_patient_screen.dart"
  "$ROOT/lib/screens/patients/duplicate_patients_screen.dart"
  "$ROOT/lib/screens/repository/items/add_item_screen.dart"
  "$ROOT/lib/services/patient_report_pdf_service.dart"
  "$ROOT/lib/services/prescription_pdf_service.dart"
  "$ROOT/lib/utils/excel_export_helper.dart"
)

FILES_DIRECTION=(
  "$ROOT/lib/screens/patients/new_patient_screen.dart"
  "$ROOT/lib/screens/patients/edit_patient_screen.dart"
  "$ROOT/lib/screens/returns/new_return_screen.dart"
  "$ROOT/lib/screens/employees/new_employee_screen.dart"
  "$ROOT/lib/screens/employees/edit_employee_screen.dart"
  "$ROOT/lib/screens/employees/finance/employee_discount_select_employee_screen.dart"
  "$ROOT/lib/screens/employees/finance/employee_loan_select_employee_screen.dart"
  "$ROOT/lib/screens/employees/finance/create_salary_payment_screen.dart"
  "$ROOT/lib/screens/repository/purchases_consumptions/view_pc_screen.dart"
  "$ROOT/lib/widgets/feature_hub.dart"
  "$ROOT/lib/core/tbian_ui.dart"
)

FILES_HELPERS=(
  "$ROOT/lib/screens/patients/view_patient_screen.dart"
  "$ROOT/lib/screens/employees/view_employee_screen.dart"
  "$ROOT/lib/screens/repository/statistics/repository_statistics_screen.dart"
  "$ROOT/lib/screens/employees/finance/create_salary_payment_screen.dart"
)

legacy_export_hits="$(
  (
    rg -n \
      "كشف-العودات\\.xlsx|كشف-اسماء-المرضى\\.xlsx|قائمة-الموظفين\\.xlsx|duplicate_patients_[^']*\\.pdf|patient_report_[^']*\\.pdf|prescription_[^']*\\.pdf|نموذج_إدخال_أصناف\\.xlsx|patient_[^']*\\.pdf" \
      "${FILES_EXPORT[@]}" || true
  ) | wc -l
)"

fixed_direction_hits="$(
  (
    rg -n \
      "const Icon\\(Icons\\.chevron_left_rounded\\)|const Icon\\(Icons\\.chevron_right_rounded\\)|Icons\\.arrow_back_ios_new_rounded, // RTL: سهم يسار بصريًا|Icon\\(Icons\\.chevron_right, color: scheme\\.primary\\)" \
      "${FILES_DIRECTION[@]}" || true
  ) | wc -l
)"

helper_localization_hits="$(
  (
    rg -n \
      "label: LocalizedText\\(tab\\.label\\)|child: LocalizedText\\(title\\)|title: LocalizedText\\(label\\)|subtitle: LocalizedText\\(|title: LocalizedText\\(|child: localizeValue" \
      "${FILES_HELPERS[@]}" || true
  ) | wc -l
)"

required_patterns=(
  "'سجلات المرضى المكررة': 'Duplicate patient records'"
  "'قائمة الموظفين المحفوظة': 'Saved employee list'"
  "'كشف العودات المحفوظ': 'Saved follow-up report'"
  "'ملف المرضى المحفوظ': 'Saved patient file'"
  "'تحديد/إلغاء الكل': 'Select / clear all'"
  "'تصدير المحدد إلى PDF': 'Export selected to PDF'"
  "'ابحث بالخدمة أو الطبيب': 'Search by service or doctor'"
  "'ابحث بالاسم…': 'Search by name...'"
  "'تم صرف الراتب لـ ', 'Salary was paid for '"
  "'لم يتم صرف الراتب لـ ', 'Salary has not been paid for '"
)

missing_required=0
for pattern in "${required_patterns[@]}"; do
  if ! rg -Fq "$pattern" "$ROOT/lib/l10n/raw_string_localizer.dart"; then
    missing_required=$((missing_required + 1))
  fi
done

echo "PHASE15_LEGACY_EXPORT_HITS=$legacy_export_hits"
echo "PHASE15_FIXED_DIRECTION_HITS=$fixed_direction_hits"
echo "PHASE15_HELPER_LOCALIZATION_HITS=$helper_localization_hits"
echo "PHASE15_REQUIRED_LOCALIZER_MISSING=$missing_required"

if [[ "$legacy_export_hits" -ne 0 || "$fixed_direction_hits" -ne 0 || "$helper_localization_hits" -lt 6 || "$missing_required" -ne 0 ]]; then
  echo "PHASE15_STATUS=FAIL"
  exit 1
fi

echo "PHASE15_STATUS=PASS"
