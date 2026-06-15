enum ClinicSyncDomain {
  reference,
  inventory,
  clinical,
  staff,
  finance,
  settings,
  all,
}

class ClinicSyncDomains {
  const ClinicSyncDomains._();

  static const List<String> pushOrder = <String>[
    'item_types',
    'items',
    'drugs',
    'medical_services',
    'consumption_types',
    'employees',
    'doctors',
    'service_doctor_share',
    'patients',
    'patient_services',
    'returns',
    'appointments',
    'prescriptions',
    'prescription_items',
    'consumptions',
    'purchases',
    'alert_settings',
    'employees_loans',
    'employees_salaries',
    'employees_discounts',
    'complaints',
    'financial_logs',
  ];

  static const Map<ClinicSyncDomain, List<String>> tablesByDomain =
      <ClinicSyncDomain, List<String>>{
        ClinicSyncDomain.reference: <String>[
          'item_types',
          'drugs',
          'medical_services',
          'consumption_types',
        ],
        ClinicSyncDomain.inventory: <String>[
          'items',
          'purchases',
          'consumptions',
          'alert_settings',
        ],
        ClinicSyncDomain.clinical: <String>[
          'patients',
          'patient_services',
          'appointments',
          'prescriptions',
          'prescription_items',
          'returns',
          'complaints',
        ],
        ClinicSyncDomain.staff: <String>[
          'employees',
          'doctors',
          'employees_loans',
          'employees_salaries',
          'employees_discounts',
          'service_doctor_share',
        ],
        ClinicSyncDomain.finance: <String>[
          'financial_logs',
          'patient_services',
          'employees_salaries',
          'employees_loans',
          'employees_discounts',
        ],
        ClinicSyncDomain.settings: <String>['clinic_profile', 'alert_settings'],
        ClinicSyncDomain.all: pushOrder,
      };

  static ClinicSyncDomain domainForTable(String table) {
    final normalized = table.trim();
    if (normalized.isEmpty) return ClinicSyncDomain.all;
    for (final entry in tablesByDomain.entries) {
      if (entry.key == ClinicSyncDomain.all) continue;
      if (entry.value.contains(normalized)) return entry.key;
    }
    return ClinicSyncDomain.all;
  }

  static List<String> tablesForDomain(ClinicSyncDomain domain) {
    return List<String>.unmodifiable(
      tablesByDomain[domain] ?? const <String>[],
    );
  }

  static String foundationOperationFor({
    required String table,
    required bool isCreate,
    required bool isDelete,
    String? status,
  }) {
    const baseNames = <String, String>{
      'item_types': 'item_type',
      'items': 'item',
      'drugs': 'drug',
      'medical_services': 'service',
      'service_doctor_share': 'service_doctor_share',
      'employees': 'employee',
      'doctors': 'doctor',
      'patients': 'patient',
      'patient_services': 'patient_service',
      'returns': 'return',
      'appointments': 'appointment',
      'prescriptions': 'prescription',
      'prescription_items': 'prescription_item',
      'consumptions': 'consumption',
      'purchases': 'purchase',
      'alert_settings': 'alert_setting',
      'employees_loans': 'loan',
      'employees_salaries': 'salary',
      'employees_discounts': 'discount',
      'complaints': 'complaint',
      'financial_logs': 'financial_log',
    };
    if (table == 'patients') {
      if (isDelete) return 'delete_patient_soft';
      return isCreate ? 'create_patient' : 'update_patient';
    }
    if (table == 'appointments') {
      if (isDelete) return 'delete_appointment_soft';
      final normalizedStatus = status?.trim().toLowerCase() ?? '';
      if (normalizedStatus.contains('ملغي') ||
          normalizedStatus.contains('cancel')) {
        return 'cancel_appointment';
      }
      if (normalizedStatus.contains('مكتمل') ||
          normalizedStatus.contains('تم') ||
          normalizedStatus.contains('complete')) {
        return 'complete_appointment';
      }
      return isCreate ? 'create_appointment' : 'update_appointment';
    }
    if (table == 'doctors' && isDelete) return 'disable_doctor';
    if (table == 'employees_salaries' && !isCreate && !isDelete) {
      final normalizedStatus = status?.trim().toLowerCase() ?? '';
      if (normalizedStatus.contains('paid') ||
          normalizedStatus.contains('مدفوع') ||
          normalizedStatus.contains('مسدد')) {
        return 'mark_salary_paid';
      }
    }
    if (table == 'consumptions' && isDelete) return 'reverse_consumption';
    if (table == 'purchases' && isDelete) return 'reverse_purchase';
    if (table == 'financial_logs' && isDelete) return 'reverse_financial_log';
    final baseName = baseNames[table] ?? table;
    return isDelete
        ? 'delete_${baseName}_soft'
        : isCreate
        ? 'create_$baseName'
        : 'update_$baseName';
  }
}
