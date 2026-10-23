const crypto = require('crypto');
const {
  readBody,
  extractBearer,
  resolveUserIdFromToken,
} = require('../_shared/storage_utils');

// Tombstone state and its audit fields are owned by explicit delete commands.
const TOMBSTONE_COLUMNS = new Set([
  'is_deleted', 'deleted_at', 'deleted_by_user_id',
  'deletion_client_mutation_id',
]);
const META_COLUMNS = new Set([
  'client_mutation_id',
  'updated_by_user_id',
]);

const TABLES = {
  item_types: {
    constraint: 'item_types_account_id_device_id_local_id_key',
    domain: 'reference',
    columns: ['name'],
  },
  items: {
    constraint: 'items_account_id_device_id_local_id_key',
    domain: 'inventory',
    columns: ['type_id', 'name', 'price', 'price_minor', 'created_at'],
  },
  drugs: {
    constraint: 'drugs_account_id_device_id_local_id_key',
    domain: 'reference',
    columns: ['name', 'notes', 'created_at'],
  },
  medical_services: {
    constraint: 'medical_services_account_id_device_id_local_id_key',
    domain: 'reference',
    columns: ['name', 'cost', 'cost_minor', 'service_type'],
  },
  consumption_types: {
    constraint: 'consumption_types_account_id_device_id_local_id_key',
    domain: 'reference',
    columns: ['type'],
  },
  employees: {
    constraint: 'employees_account_id_device_id_local_id_key',
    domain: 'staff',
    columns: [
      'name',
      'identity_number',
      'phone_number',
      'job_title',
      'address',
      'marital_status',
      'basic_salary',
      'basic_salary_minor',
      'final_salary',
      'final_salary_minor',
      'is_doctor',
      'user_uid',
    ],
  },
  doctors: {
    constraint: 'doctors_account_id_device_id_local_id_key',
    domain: 'staff',
    columns: [
      'employee_id',
      'user_uid',
      'name',
      'specialization',
      'phone_number',
      'start_time',
      'end_time',
      'print_counter',
    ],
  },
  service_doctor_share: {
    constraint: 'service_doctor_share_account_id_device_id_local_id_key',
    domain: 'staff',
    columns: [
      'service_id',
      'doctor_id',
      'share_percentage',
      'tower_share_percentage',
      'is_hidden',
    ],
  },
  patients: {
    constraint: 'patients_account_id_device_id_local_id_key',
    domain: 'clinical',
    columns: [
      'name',
      'age',
      'diagnosis',
      'paid_amount',
      'paid_amount_minor',
      'remaining',
      'remaining_minor',
      'register_date',
      'registered_at',
      'phone_number',
      'health_status',
      'preferences',
      'collateral',
      'doctor_id',
      'doctor_name',
      'doctor_specialization',
      'notes',
      'service_type',
      'service_id',
      'service_name',
      'service_cost',
      'service_cost_minor',
      'doctor_share',
      'doctor_share_minor',
      'doctor_input',
      'doctor_input_minor',
      'tower_share',
      'tower_share_minor',
      'department_share',
      'department_share_minor',
      'doctor_review_pending',
      'doctor_reviewed_at',
    ],
  },
  patient_services: {
    constraint: 'patient_services_account_id_device_id_local_id_key',
    domain: 'clinical',
    columns: [
      'patient_id',
      'service_id',
      'service_name',
      'service_cost',
      'service_cost_minor',
    ],
  },
  returns: {
    constraint: 'returns_account_id_device_id_local_id_key',
    domain: 'clinical',
    columns: [
      'date',
      'patient_name',
      'phone_number',
      'diagnosis',
      'remaining',
      'remaining_minor',
      'age',
      'doctor',
      'notes',
      'is_attended',
      'attended_at',
    ],
  },
  appointments: {
    constraint: 'appointments_account_id_device_id_local_id_key',
    domain: 'clinical',
    columns: ['patient_id', 'doctor_id', 'appointment_time', 'status', 'notes'],
  },
  prescriptions: {
    constraint: 'prescriptions_account_id_device_id_local_id_key',
    domain: 'clinical',
    columns: ['patient_id', 'doctor_id', 'record_date', 'created_at'],
  },
  prescription_items: {
    constraint: 'prescription_items_account_id_device_id_local_id_key',
    domain: 'clinical',
    columns: ['prescription_id', 'drug_id', 'days', 'times_per_day'],
  },
  consumptions: {
    constraint: 'consumptions_account_id_device_id_local_id_key',
    domain: 'inventory',
    columns: [
      'patient_id',
      'item_id',
      'quantity',
      'date',
      'amount',
      'amount_minor',
      'unit_price_snapshot',
      'unit_price_minor',
      'note',
    ],
  },
  purchases: {
    constraint: 'purchases_account_id_device_id_local_id_key',
    domain: 'inventory',
    columns: [
      'item_id',
      'item_name_snapshot',
      'item_type_name_snapshot',
      'quantity',
      'total',
      'amount_minor',
      'unit_price_snapshot',
      'unit_price_minor',
      'created_at',
      'date',
    ],
  },
  alert_settings: {
    constraint: 'alert_settings_account_id_device_id_local_id_key',
    domain: 'inventory',
    columns: [
      'item_id',
      'item_uuid',
      'threshold',
      'is_enabled',
      'last_triggered',
      'created_at',
      'notify_time',
    ],
  },
  employees_loans: {
    constraint: 'employees_loans_account_id_device_id_local_id_key',
    domain: 'finance',
    columns: [
      'employee_id',
      'loan_date_time',
      'final_salary',
      'final_salary_minor',
      'ratio_sum',
      'ratio_sum_minor',
      'loan_amount',
      'loan_amount_minor',
      'leftover',
      'leftover_minor',
    ],
  },
  employees_salaries: {
    constraint: 'employees_salaries_account_id_device_id_local_id_key',
    domain: 'finance',
    columns: [
      'employee_id',
      'year',
      'month',
      'final_salary',
      'final_salary_minor',
      'ratio_sum',
      'ratio_sum_minor',
      'total_loans',
      'total_loans_minor',
      'total_discounts',
      'total_discounts_minor',
      'net_pay',
      'net_pay_minor',
      'is_paid',
      'payment_date',
      'period_start',
      'period_end',
    ],
  },
  employees_discounts: {
    constraint: 'employees_discounts_account_id_device_id_local_id_key',
    domain: 'finance',
    columns: [
      'employee_id',
      'discount_date_time',
      'amount',
      'amount_minor',
      'notes',
    ],
  },
  complaints: {
    constraint: 'complaints_account_id_device_id_local_id_key',
    domain: 'clinical',
    columns: [
      'subject',
      'message',
      'status',
      'reply_message',
      'replied_at',
      'replied_by',
      'handled_by',
      'handled_at',
      'created_at',
    ],
  },
  financial_logs: {
    constraint: 'financial_logs_account_id_device_id_local_id_key',
    domain: 'finance',
    columns: [
      'transaction_type',
      'operation',
      'amount',
      'amount_minor',
      'employee_id',
      'patient_id',
      'description',
      'modification_details',
      'timestamp',
    ],
  },
};

// يجب أن يطابق هذا الجدول مفاتيح lib/core/features.dart حتى لا تصبح الواجهة
// أكثر صرامة أو أكثر تساهلًا من الخادم. الدالة تعمل بـ admin secret، لذلك
// يجب تطبيق صلاحيات الميزة و CRUD هنا وليس في Flutter فقط.
const TABLE_FEATURES = {
  item_types: 'repository',
  items: 'repository',
  purchases: 'repository',
  consumptions: 'repository',
  alert_settings: 'repository',
  consumption_types: 'repository',
  patients: {
    create: 'patients.new',
    update: 'patients.list',
    delete: 'patients.list',
  },
  patient_services: 'patients.list',
  returns: 'returns',
  appointments: 'patients.list',
  prescriptions: 'prescriptions',
  prescription_items: 'prescriptions',
  drugs: 'prescriptions',
  employees: 'employees',
  doctors: 'employees',
  employees_loans: 'payments',
  employees_salaries: 'payments',
  employees_discounts: 'payments',
  financial_logs: 'payments',
  complaints: 'patients.questions',
};
const DOCTOR_SERVICE_TYPES = new Set(['doctorGeneral', 'doctor', 'طبيب']);
const SERVICE_AUTHORITY_TABLES = new Set(['medical_services', 'service_doctor_share']);

function requestsDeletedPayload(payload) {
  return payload.is_deleted === true || payload.is_deleted === 1 ||
    payload.is_deleted === 'true' || payload.is_deleted === '1';
}

function syncCrudAction(operationType) {
  const text = `${operationType || ''}`.trim().toLowerCase();
  if (text.includes('delete') || text.includes('reverse') || text.includes('disable') || text.includes('archive')) {
    return 'delete';
  }
  if (text.startsWith('create') || text.startsWith('add') || text.startsWith('insert')) {
    return 'create';
  }
  return 'update';
}

function requiredFeatureFor(table, operationType) {
  const spec = TABLE_FEATURES[table];
  if (!spec) return null;
  if (typeof spec === 'string') return spec;
  const action = syncCrudAction(operationType);
  return spec[action] || spec.update || spec.create || null;
}

function deny(status, code, message) {
  const err = new Error(message);
  err.status = status;
  err.code = code;
  return err;
}

function graphqlUrl() {
  const raw =
    process.env.NHOST_GRAPHQL_URL ||
    process.env.HASURA_GRAPHQL_URL ||
    process.env.GRAPHQL_URL ||
    '';
  if (raw && raw.includes('nhost.run')) {
    let normalized = raw.replace(/\/+$/, '');
    if (normalized.endsWith('/v1/graphql')) return normalized;
    if (normalized.endsWith('/graphql')) {
      return normalized.replace(/\/graphql$/i, '/v1/graphql');
    }
    if (normalized.endsWith('/v1')) {
      return normalized.includes('.hasura.')
        ? `${normalized}/graphql`
        : normalized;
    }
    return normalized.includes('.hasura.')
      ? `${normalized}/v1/graphql`
      : `${normalized}/v1`;
  }
  const subdomain = process.env.NHOST_SUBDOMAIN;
  const region = process.env.NHOST_REGION;
  if (subdomain && region) {
    return `https://${subdomain}.graphql.${region}.nhost.run/v1`;
  }
  return raw || 'http://localhost:8080/v1/graphql';
}

function adminSecret() {
  return (
    process.env.GRAPHQL_ADMIN_SECRET ||
    process.env.NHOST_ADMIN_SECRET ||
    process.env.HASURA_GRAPHQL_ADMIN_SECRET ||
    ''
  );
}

function response(res, status, body) {
  res.status(status).json(body);
}

function fail(res, status, code, message, extra = {}) {
  response(res, status, {
    success: false,
    error_code: code,
    user_message: message,
    server_timestamp: new Date().toISOString(),
    ...extra,
  });
}

async function gqlRequest(query, variables) {
  const secret = adminSecret();
  if (!secret) throw new Error('Missing Hasura admin secret');
  const res = await fetch(graphqlUrl(), {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-hasura-admin-secret': secret,
    },
    body: JSON.stringify({ query, variables }),
  });
  const text = await res.text();
  let json;
  try {
    json = text ? JSON.parse(text) : {};
  } catch (_) {
    const error = new Error('upstream_invalid_response');
    error.code = 'upstream_invalid_response';
    throw error;
  }
  if (!res.ok || json.errors) {
    const errors = Array.isArray(json.errors) ? json.errors : [];
    const err = new Error('upstream_mutation_failed');
    err.code = 'upstream_mutation_failed';
    const contractCodes = ['purchase_amendment_source_missing', 'purchase_amendment_denied',
      'purchase_amendment_payload_invalid', 'idempotency_payload_mismatch',
      'inventory_stock_update_rejected', 'purchase_amendment_conflict',
      'purchase_amendment_pair_invalid', 'purchase_amendment_link_immutable',
      'sync_atomic_denied', 'foreign_sync_identity', 'foreign_sync_reference',
      'sync_catalog_dependency_pending', 'sync_expected_version_invalid',
      'clinic_timestamp_utc_required', 'clinic_timestamp_invalid',
      'patient_registration_time_required', 'patient_registration_time_clear_denied',
      'sync_atomic_request_invalid', 'sync_version_unknown', 'sync_version_conflict',
      'sync_identity_mismatch', 'sync_identity_missing', 'sync_record_deleted',
      'mutation_in_progress', 'sync_money_mismatch', 'money_minor_mismatch',
      'money_dual_write_conflicting_nulls', 'money_value_out_of_minor_range'];
    const upstreamText = JSON.stringify(errors);
    err.upstreamContractCode = contractCodes.find((code) => upstreamText.includes(code));
    if (upstreamText.includes('apply_clinic_sync_atomic') &&
        upstreamText.toLowerCase().includes('not found')) {
      err.upstreamContractCode = 'sync_protocol_unavailable';
    }
    err.isConstraintViolation = errors.some((entry) => {
      const code = `${entry?.extensions?.code || ''}`.toLowerCase();
      const message = `${entry?.message || ''}`.toLowerCase();
      return code.includes('constraint') || message.includes('unique constraint');
    });
    throw err;
  }
  return json.data || {};
}

function hashPayload(payload) {
  return crypto
    .createHash('sha256')
    .update(stableStringify(payload))
    .digest('hex');
}

function stableStringify(value) {
  if (value === null || typeof value !== 'object') {
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) {
    return `[${value.map((item) => stableStringify(item)).join(',')}]`;
  }
  const keys = Object.keys(value).sort();
  return `{${keys
    .map((key) => `${JSON.stringify(key)}:${stableStringify(value[key])}`)
    .join(',')}}`;
}

function normalizeObject(value) {
  return value && typeof value === 'object' && !Array.isArray(value)
    ? value
    : {};
}

function isDeleteOperation(operationType) {
  const text = `${operationType || ''}`.toLowerCase();
  return text.includes('delete') || text.includes('reverse') || text.includes('disable') || text.includes('archive');
}

function normalizeLocalId(value) {
  // bigint origin IDs travel as decimal strings; unsafe JSON numbers are rejected.
  const text = typeof value === 'number'
    ? (Number.isSafeInteger(value) && value > 0 ? String(value) : null)
    : (typeof value === 'string' ? value.trim() : null);
  if (!text || !/^[0-9]{1,19}$/.test(text)) return null;
  const parsed = BigInt(text);
  return parsed > 0n && parsed <= 9223372036854775807n ? parsed.toString() : null;
}

function filterPayload(table, payload, context) {
  const config = TABLES[table];
  const allowed = new Set([
    'id',
    'account_id',
    'device_id',
    'local_id',
    'updated_at',
    ...(context.deleteOperation ? [] : config.columns),
    ...META_COLUMNS,
  ]);
  const out = {};
  for (const [key, value] of Object.entries(payload)) {
    if (!allowed.has(key)) continue;
    if (value === undefined) continue;
    if (key === 'id' && !`${value || ''}`.trim()) continue;
    if (key.endsWith('_minor') && value !== null) {
      if ((typeof value !== 'string' && typeof value !== 'number') ||
        (typeof value === 'number' && !Number.isSafeInteger(value)) ||
        !/^(0|-?[1-9][0-9]{0,18})$/.test(`${value}`) ||
        BigInt(value) < -9223372036854775808n || BigInt(value) > 9223372036854775807n) {
        throw deny(400, 'invalid_sync_money', 'Invalid monetary value');
      }
    }
    out[key] = value;
  }
  out.account_id = context.accountId;
  out.device_id = context.deviceId;
  out.local_id = context.localId;
  out.client_mutation_id = context.clientMutationId;
  out.updated_at = new Date().toISOString();
  out.updated_by_user_id = context.userId;
  if (context.deleteOperation) {
    out.is_deleted = true;
    out.deleted_at = new Date().toISOString();
    out.deleted_by_user_id = context.userId;
    out.deletion_client_mutation_id = context.clientMutationId;
  }
  return out;
}

async function fetchCachedMutation(clientMutationId, accountId) {
  const query = `
    query ExistingMutation($id: String!, $accountId: uuid!) {
      client_mutations(
        where: {
          client_mutation_id: {_eq: $id},
          account_id: {_eq: $accountId}
        },
        limit: 1
      ) {
        id
        operation_type
        payload_hash
        result_json
      }
    }
  `;
  const data = await gqlRequest(query, { id: clientMutationId, accountId });
  return Array.isArray(data.client_mutations) ? data.client_mutations[0] : null;
}

async function accessFor(userId, accountId) {
  const query = `
    query SyncAccess($userId: uuid!, $accountId: uuid!) {
      account_users(
        where: {
          account_id: {_eq: $accountId},
          user_uid: {_eq: $userId}
        },
        limit: 1
      ) {
        role
        disabled
      }
      accounts_by_pk(id: $accountId) {
        id
        frozen
      }
      super_admins(where: {user_uid: {_eq: $userId}}, limit: 1) {
        id
        disabled
      }
      user(id: $userId) { disabled }
      account_feature_permissions(
        where: {
          account_id: {_eq: $accountId},
          user_uid: {_eq: $userId}
        },
        limit: 1
      ) {
        allow_all
        allowed_features
        can_create
        can_update
        can_delete
      }
    }
  `;
  const data = await gqlRequest(query, { userId, accountId });
  const membership = Array.isArray(data.account_users)
    ? data.account_users[0]
    : null;
  const superAdmin = Array.isArray(data.super_admins)
    ? data.super_admins[0]
    : null;
  const permissions = Array.isArray(data.account_feature_permissions)
    ? data.account_feature_permissions[0]
    : null;
  return {
    role: `${membership?.role || ''}`.trim().toLowerCase(),
    memberDisabled: membership?.disabled === true,
    accountFrozen: data.accounts_by_pk?.frozen === true,
    accountExists: !!data.accounts_by_pk?.id,
    userDisabled: data.user?.disabled === true,
    isSuperAdmin:
      !!superAdmin &&
      superAdmin.disabled !== true &&
      data.user?.disabled !== true,
    isMember: !!membership,
    allowAll: permissions?.allow_all === true,
    allowedFeatures: Array.isArray(permissions?.allowed_features)
      ? permissions.allowed_features.map((value) => `${value}`)
      : [],
    canCreate: permissions?.can_create === true,
    canUpdate: permissions?.can_update === true,
    canDelete: permissions?.can_delete === true,
  };
}

function assertRoleAllowed(access, table, tableConfig, operationType, actualAction, actualFeatures) {
  if (access.userDisabled) {
    throw deny(403, 'user_disabled', 'User is disabled');
  }
  if (!access.accountExists) {
    throw deny(404, 'account_not_found', 'Account was not found');
  }
  if (access.accountFrozen) {
    throw deny(423, 'account_frozen', 'Account is frozen');
  }
  if (access.isSuperAdmin) return;
  if (!access.isMember) {
    throw deny(403, 'not_account_member', 'User is not a member of this account');
  }
  if (access.memberDisabled) {
    throw deny(403, 'user_disabled', 'User is disabled for this account');
  }
  if (
    Array.isArray(tableConfig.allowedRoles) &&
    !tableConfig.allowedRoles.includes(access.role)
  ) {
    throw deny(403, 'insufficient_sync_role', 'Operation is not allowed for this role');
  }

  const action = actualAction || syncCrudAction(operationType);

  if (action === 'create' && !access.canCreate) {
    throw deny(403, 'sync_create_denied', 'You do not have permission to create this data');
  }
  if (action === 'update' && !access.canUpdate) {
    throw deny(403, 'sync_update_denied', 'You do not have permission to update this data');
  }
  if (action === 'delete' && !access.canDelete) {
    throw deny(403, 'sync_delete_denied', 'You do not have permission to delete this data');
  }

  const requiredFeatures = actualFeatures || [requiredFeatureFor(table, action)].filter(Boolean);
  const deniedFeature = requiredFeatures.find(feature => !access.allowedFeatures.includes(feature));
  if (deniedFeature && !access.allowAll) {
    throw deny(
      403,
      'sync_feature_denied',
      `You do not have permission for feature ${deniedFeature}`,
    );
  }
}

function serviceFeature(serviceType) {
  return DOCTOR_SERVICE_TYPES.has(serviceType) ? 'employees' : 'lab_radiology';
}

// Auth/membership/CRUD is checked before this service-authenticated lookup.
// Updates authorize the stored classification and the proposed classification;
// a client cannot relabel an existing lab row or forge a share's parent type.
async function doctorServiceFeatures({table, accountId, deviceId, localId, payload, currentOnly = false}) {
  const fields = table === 'medical_services' ? 'service_type' : 'service_id doctor_id';
  const data = await gqlRequest(`
    query DoctorServiceWriteScope($accountId: uuid!, $deviceId: String!, $localId: bigint!) {
      rows: ${table}(where: {account_id: {_eq: $accountId},
        device_id: {_eq: $deviceId}, local_id: {_eq: $localId}}, limit: 1) {
        id account_id ${fields}
      }
    }`, {accountId, deviceId, localId});
  const prior = Array.isArray(data.rows) ? data.rows[0] : null;
  if (table === 'medical_services') {
    const features = [];
    if (prior) features.push(serviceFeature(prior.service_type));
    if (!currentOnly || !prior) {
      features.push(serviceFeature(Object.hasOwn(payload, 'service_type')
        ? payload.service_type : prior?.service_type));
    }
    return [...new Set(features)];
  }
  const next = {
    service_id: Object.hasOwn(payload, 'service_id') ? payload.service_id : prior?.service_id,
    doctor_id: Object.hasOwn(payload, 'doctor_id') ? payload.doctor_id : prior?.doctor_id,
  };
  const references = prior ? (currentOnly ? [prior] : [prior, next]) : [next];
  const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  for (const reference of references) {
    if (!uuidPattern.test(`${reference.service_id || ''}`) ||
        !uuidPattern.test(`${reference.doctor_id || ''}`)) {
      throw deny(400, 'invalid_sync_reference', 'The service and doctor identities are required');
    }
  }
  const serviceIds = [...new Set(references.map(row => row.service_id))];
  const doctorIds = [...new Set(references.map(row => row.doctor_id))];
  const context = await gqlRequest(`
    query DoctorServiceReferenceScope($serviceIds: [uuid!]!, $doctorIds: [uuid!]!) {
      services: medical_services(where: {id: {_in: $serviceIds}}) { id account_id service_type }
      doctors: doctors(where: {id: {_in: $doctorIds}}) { id account_id }
    }`, {serviceIds, doctorIds});
  const services = new Map((context.services || []).map(row => [row.id.toLowerCase(), row]));
  const doctors = new Map((context.doctors || []).map(row => [row.id.toLowerCase(), row]));
  const features = [];
  for (const reference of references) {
    const service = services.get(reference.service_id.toLowerCase());
    const doctor = doctors.get(reference.doctor_id.toLowerCase());
    if (!service || !doctor) {
      throw deny(409, 'mutation_dependency_pending', 'The service and doctor must synchronize first');
    }
    if (service.account_id !== accountId || doctor.account_id !== accountId) {
      throw deny(403, 'foreign_sync_reference', 'The service and doctor must belong to this account');
    }
    features.push(serviceFeature(service.service_type));
  }
  return [...new Set(features)];
}

async function applyMutation({table, object, event, clientMutation, userId, operationType, expectedVersion, allowLegacyReceipt = false}) {
  const mutationDoc = `
    mutation ClinicSyncApply(
      $actor: uuid!, $table: String!, $operation: String!, $expectedVersion: String,
      $object: jsonb!, $event: jsonb!, $clientMutation: jsonb!
    ) {
      rows: apply_clinic_sync_atomic(args: {
        p_actor: $actor, p_table: $table, p_operation: $operation,
        p_expected_version: $expectedVersion, p_object: $object,
        p_event: $event, p_receipt: $clientMutation
      }) { result_json }
    }
  `;
  try {
    const data = await gqlRequest(mutationDoc, {
      actor: userId, table, operation: operationType, expectedVersion,
      object, event, clientMutation,
    });
    const result = Array.isArray(data.rows) ? data.rows[0]?.result_json : null;
    const version = result?.data?.server_version;
    if (result?.success !== true || result.operation !== operationType ||
      result.data?.entity_table !== table ||
      result.data?.client_mutation_id !== clientMutation.client_mutation_id ||
      result.data?.remote_id !== object.id ||
      (!(allowLegacyReceipt && version === null) && (
        !/^[1-9][0-9]{0,18}$/.test(`${version || ''}`) ||
        (typeof version === 'number' && !Number.isSafeInteger(version)) ||
        BigInt(version) > 9223372036854775807n)) ||
      !result.server_timestamp || !result.data?.sync_event_id) {
      throw new Error('sync_atomic_acknowledgement_missing');
    }
    return result;
  } catch (error) {
    switch (error.upstreamContractCode) {
      case 'sync_protocol_unavailable':
        throw deny(503, 'sync_protocol_unavailable', 'The versioned sync service is unavailable');
      case 'sync_atomic_denied':
      case 'foreign_sync_identity':
      case 'foreign_sync_reference':
        throw deny(403, error.upstreamContractCode, 'You no longer have permission to synchronize this data');
      case 'sync_catalog_dependency_pending':
        throw deny(409, 'mutation_dependency_pending', 'The service and doctor must synchronize first');
      case 'clinic_timestamp_utc_required':
      case 'clinic_timestamp_invalid':
      case 'patient_registration_time_required':
      case 'patient_registration_time_clear_denied':
      case 'sync_expected_version_invalid':
      case 'sync_atomic_request_invalid':
        throw deny(400, error.upstreamContractCode, 'Invalid sync request');
      case 'sync_version_unknown':
        throw deny(409, 'sync_version_unknown', 'This saved change needs reconciliation with the server');
      case 'mutation_in_progress':
        throw deny(409, 'mutation_in_progress', 'Mutation is still being committed');
      case 'inventory_stock_update_rejected':
        // The stock trigger rolled back the row, receipt and event. Surface
        // the same domain conflict used by purchase amendments, so the saved
        // consumption is reviewed instead of retried as a temporary HTTP 500.
        throw deny(409, 'inventory_stock_conflict', 'The requested quantity exceeds available stock');
      case 'sync_version_conflict':
      case 'sync_money_mismatch':
      case 'money_minor_mismatch':
      case 'money_dual_write_conflicting_nulls':
      case 'money_value_out_of_minor_range':
      case 'sync_identity_mismatch':
      case 'sync_identity_missing':
      case 'sync_record_deleted':
      case 'idempotency_payload_mismatch':
        throw deny(409, error.upstreamContractCode, 'The record has changed; the saved local change is preserved');
      default:
        throw error;
    }
  }
}

function expectedSyncVersion(body, payload) {
  if (body.sync_protocol == null || body.sync_protocol === 1) return null;
  if (body.sync_protocol === 2 && body.legacy_prepared === true) {
    if (body.expected_server_version !== null || Object.hasOwn(payload, 'expected_server_version')) {
      throw deny(400, 'invalid_sync_protocol', 'Invalid sync protocol');
    }
    return null;
  }
  if (body.sync_protocol !== 2 || !Object.hasOwn(body, 'expected_server_version') ||
    !Object.hasOwn(payload, 'expected_server_version')) {
    throw deny(400, 'invalid_sync_protocol', 'Invalid sync protocol');
  }
  function normalize(value) {
    if (value === null) return null;
    if ((typeof value !== 'string' && typeof value !== 'number') ||
      (typeof value === 'number' && !Number.isSafeInteger(value)) ||
      !/^(0|[1-9][0-9]{0,18})$/.test(`${value}`) ||
      BigInt(value) > 9223372036854775807n) {
      throw deny(400, 'sync_expected_version_invalid', 'Invalid server version');
    }
    return `${value}`;
  }
  const expected = normalize(body.expected_server_version);
  if (expected !== normalize(payload.expected_server_version)) {
    throw deny(400, 'sync_expected_version_invalid', 'Server version does not match the saved request');
  }
  return expected;
}

function deterministicUuid(value) {
  const bytes = crypto.createHash('sha256').update(value).digest().subarray(0, 16);
  bytes[6] = (bytes[6] & 0x0f) | 0x50;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = bytes.toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

async function resolveRemoteIdentity({
  table,
  accountId,
  deviceId,
  localId,
  requestedId,
  clientMutationId,
}) {
  const candidate = `${requestedId || ''}`.trim();
  const hasCandidate = /^[0-9a-f-]{36}$/i.test(candidate);
  const query = `
    query ExistingSyncIdentity(
      $accountId: uuid!,
      $deviceId: String!,
      $localId: bigint!
      ${hasCandidate ? ', $requestedId: uuid!' : ''}
    ) {
      rows: ${table}(
        where: {
          account_id: {_eq: $accountId},
          device_id: {_eq: $deviceId},
          local_id: {_eq: $localId}
        },
        limit: 1
      ) { id is_deleted }
      ${hasCandidate ? `requested: ${table}(
        where: {id: {_eq: $requestedId}}, limit: 1
      ) { id account_id }` : ''}
    }
  `;
  const data = await gqlRequest(query, {
    accountId, deviceId, localId,
    ...(hasCandidate ? {requestedId: candidate} : {}),
  });
  const existing = Array.isArray(data.rows) ? data.rows[0]?.id : null;
  const requested = hasCandidate && Array.isArray(data.requested)
    ? data.requested[0] : null;
  if (requested && requested.account_id !== accountId) {
    throw deny(403, 'foreign_sync_identity', 'Record belongs to another account');
  }
  if (hasCandidate && requested && requested.id !== existing) {
    throw deny(409, 'sync_identity_mismatch', 'Record identity does not match its origin');
  }
  if (hasCandidate && existing && existing !== candidate) {
    throw deny(409, 'sync_identity_mismatch', 'Record identity does not match its origin');
  }
  return {
    id: existing || (hasCandidate ? candidate
      : deterministicUuid(`${accountId}:${table}:${clientMutationId}`)),
    exists: !!existing,
    isDeleted: Array.isArray(data.rows) && data.rows[0]?.is_deleted === true,
  };
}

async function recoverCommittedMutation({
  cached,
  table,
  accountId,
  clientMutationId,
}) {
  const query = `
    query RecoverClinicSyncMutation($accountId: uuid!, $id: String!) {
      rows: ${table}(
        where: {
          account_id: {_eq: $accountId},
          client_mutation_id: {_eq: $id}
        },
        limit: 1
      ) { id updated_at server_version }
      events: sync_events(
        where: {
          account_id: {_eq: $accountId},
          client_mutation_id: {_eq: $id}
        },
        limit: 1
      ) { id created_at }
    }
  `;
  const data = await gqlRequest(query, { accountId, id: clientMutationId });
  const row = Array.isArray(data.rows) ? data.rows[0] : null;
  const event = Array.isArray(data.events) ? data.events[0] : null;
  if (!row || !event) return null;
  const result = {
    success: true,
    operation: cached.operation_type,
    server_timestamp: row.updated_at || event.created_at,
    data: {
      entity_table: table,
      client_mutation_id: clientMutationId,
      remote_id: row.id,
      server_version: row.server_version ?? null,
      sync_event_id: event.id,
    },
  };
  await completeMutationResult(cached.id, result);
  return result;
}

async function completeMutationResult(id, result) {
  const mutationDoc = `
    mutation CompleteClinicSyncMutation(
      $id: uuid!,
      $result: jsonb!,
      $completedAt: timestamptz!
    ) {
      clientMutation: update_client_mutations_by_pk(
        pk_columns: {id: $id},
        _set: {result_json: $result, completed_at: $completedAt}
      ) {
        id
        result_json
      }
    }
  `;
  return gqlRequest(mutationDoc, {
    id,
    result,
    completedAt: new Date().toISOString(),
  });
}

async function applyPurchaseAmendment({
  object, userId, clientMutationId, payloadHash, correlationId,
}) {
  const query = 'mutation AmendPurchaseAtomic($actor:uuid!,$object:jsonb!,$receipt:jsonb!,$event:jsonb!){rows:amend_purchase_atomic(args:{p_actor:$actor,p_object:$object,p_receipt:$receipt,p_event:$event}){result_json}}';
  try {
    const data = await gqlRequest(query, {
      actor: userId,
      object,
      receipt: {
        id: crypto.randomUUID(),
        client_mutation_id: clientMutationId,
        payload_hash: payloadHash,
      },
      event: { id: crypto.randomUUID(), correlation_id: correlationId },
    });
    const result = Array.isArray(data.rows) ? data.rows[0]?.result_json : null;
    if (!result?.success || !Number.isSafeInteger(result.data?.server_version)) {
      throw new Error('purchase_amendment_acknowledgement_missing');
    }
    return result;
  } catch (error) {
    switch (error.upstreamContractCode) {
      case 'purchase_amendment_source_missing':
        throw deny(409, 'mutation_dependency_pending', 'The original purchase must synchronize first');
      case 'purchase_amendment_denied':
        throw deny(403, 'purchase_amendment_denied', 'You do not have permission to amend this purchase');
      case 'purchase_amendment_payload_invalid':
        throw deny(400, 'purchase_amendment_payload_invalid', 'Invalid purchase amendment');
      case 'idempotency_payload_mismatch':
        throw deny(409, 'idempotency_payload_mismatch', 'Mutation id was reused with a different payload');
      case 'inventory_stock_update_rejected':
        throw deny(409, 'inventory_stock_conflict', 'The amendment exceeds available stock');
      case 'purchase_amendment_conflict':
      case 'purchase_amendment_pair_invalid':
      case 'purchase_amendment_link_immutable':
        throw deny(409, 'purchase_amendment_conflict', 'The original purchase has already changed');
      default:
        if (error.isConstraintViolation) {
          throw deny(409, 'purchase_amendment_conflict', 'Concurrent purchase amendment conflict');
        }
        throw error;
    }
  }
}

module.exports = async function handler(req, res) {
  // A read-only deployment probe can verify which contract reached the runtime
  // before the database begins requiring its new patient timestamp field.
  if (typeof res.setHeader === 'function') {
    res.setHeader('X-Clinic-Sync-Contract', 'clinic-temporal-v1');
  }
  const correlationId = crypto.randomUUID();
  if (req.method && req.method.toUpperCase() !== 'POST') {
    fail(res, 405, 'method_not_allowed', 'POST is required', {
      correlation_id: correlationId,
    });
    return;
  }

  try {
    const token = extractBearer(req);
    const userId = await resolveUserIdFromToken(token);
    if (!userId) {
      fail(res, 401, 'invalid_session', 'Invalid or missing session', {
        correlation_id: correlationId,
      });
      return;
    }

    const body = await readBody(req);
    const operationType = `${body.operation_type || ''}`.trim();
    const table = `${body.entity_table || ''}`.trim();
    const tableConfig = TABLES[table];
    const clientMutationId = `${body.client_mutation_id || ''}`.trim();
    const accountId = `${body.account_id || ''}`.trim();
    const deviceId = `${body.device_id || ''}`.trim();
    const localId = normalizeLocalId(body.local_id);

    if (!operationType || !tableConfig || !clientMutationId || !accountId) {
      fail(res, 400, 'invalid_sync_request', 'Invalid sync request', {
        correlation_id: correlationId,
      });
      return;
    }
    if (!deviceId || !localId) {
      fail(res, 400, 'invalid_local_identity', 'Missing device/local identity', {
        correlation_id: correlationId,
      });
      return;
    }

    const payload = normalizeObject(body.payload);
    const expectedVersion = expectedSyncVersion(body, payload);
    const isAmendment = operationType === 'amend_purchase';
    if (isAmendment && table !== 'purchases') {
      throw deny(400, 'invalid_purchase_amendment', 'Purchase amendment requires purchases');
    }
    if (!isAmendment && !isDeleteOperation(operationType) && payload.replaces_purchase_id != null) {
      throw deny(400, 'purchase_amendment_operation_required', 'Replacement requires an explicit amendment');
    }
    if (isAmendment && (requestsDeletedPayload(payload) ||
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(`${payload.replaces_purchase_id || ''}`))) {
      throw deny(400, 'invalid_purchase_amendment', 'Invalid original purchase identity');
    }
    const payloadHash = hashPayload({
      operation_type: operationType,
      entity_table: table,
      account_id: accountId,
      ...(isAmendment ? {device_id: deviceId, local_id: localId} : {}),
      payload,
    });

    // Security first: never return cached mutation results before proving that
    // the current JWT still belongs to the requested account and has permission
    // for this table/operation. client_mutation_id values are opaque, but cached
    // result_json may contain remote ids and sync event ids.
    const access = await accessFor(userId, accountId);
    // Check membership before querying any row with the admin credential.
    const requestsTombstone = payload.is_deleted === true ||
      payload.is_deleted === 1 || payload.is_deleted === 'true' ||
      payload.is_deleted === '1';
    assertRoleAllowed(access, table, tableConfig, operationType,
      requestsTombstone ? 'delete' : undefined);
    if (requestsTombstone && !isDeleteOperation(operationType)) {
      throw deny(400, 'tombstone_operation_required',
        'Deleting data requires an explicit delete operation');
    }

    let serviceFeatures = SERVICE_AUTHORITY_TABLES.has(table) && !access.allowAll && !access.isSuperAdmin
      ? await doctorServiceFeatures({table, accountId, deviceId, localId, payload, currentOnly: true}) : undefined;
    if (serviceFeatures) {
      assertRoleAllowed(access, table, tableConfig, operationType,
        requestsTombstone ? 'delete' : undefined, serviceFeatures);
    }

    const cached = await fetchCachedMutation(clientMutationId, accountId);
    if (cached) {
      if (cached.payload_hash && cached.payload_hash !== payloadHash) {
        fail(res, 409, 'idempotency_payload_mismatch', 'Mutation id was reused with a different payload', {
          correlation_id: correlationId,
        });
        return;
      }
      if (cached.result_json && body.sync_protocol !== 2) {
        response(res, 200, cached.result_json);
        return;
      }
      if (body.sync_protocol !== 2) {
        const recovered = await recoverCommittedMutation({cached, table, accountId, clientMutationId});
        if (recovered) { response(res, 200, recovered); return; }
        throw deny(409, 'mutation_in_progress', 'Mutation is still being committed');
      }
    }

    if (!cached && serviceFeatures) {
      serviceFeatures = await doctorServiceFeatures({table, accountId, deviceId, localId, payload,
        currentOnly: isDeleteOperation(operationType)});
      assertRoleAllowed(access, table, tableConfig, operationType,
        requestsTombstone ? 'delete' : undefined, serviceFeatures);
    }

    if (body.legacy_prepared === true && cached?.result_json) {
      // The prepared payload/hash/CID remain unchanged. SQL rechecks current
      // authority and returns the original receipt without inventing a base.
      const result = await applyMutation({
        table, object: {id: cached.result_json.data?.remote_id,
          account_id: accountId, device_id: deviceId, local_id: localId},
        userId, operationType, expectedVersion: null, allowLegacyReceipt: true,
        event: {id: crypto.randomUUID(), correlation_id: correlationId},
        clientMutation: {id: crypto.randomUUID(), client_mutation_id: clientMutationId,
          payload_hash: payloadHash},
      });
      response(res, 200, result);
      return;
    }

    const object = filterPayload(table, payload, {
      accountId,
      deviceId,
      localId,
      clientMutationId,
      userId,
      deleteOperation: isDeleteOperation(operationType),
    });
    if (isAmendment) object.replaces_purchase_id = payload.replaces_purchase_id;
    const identity = await resolveRemoteIdentity({
      table,
      accountId,
      deviceId,
      localId,
      requestedId: object.id,
      clientMutationId,
    });
    object.id = identity.id;
    if (!cached && identity.isDeleted && !isDeleteOperation(operationType)) {
      throw deny(409, 'sync_record_deleted',
        'Deleted data cannot be restored through an ordinary update');
    }
    if (isAmendment) {
      assertRoleAllowed(access, table, tableConfig, operationType, 'update');
      if (identity.exists) {
        const committed = await fetchCachedMutation(clientMutationId, accountId);
        if (committed?.payload_hash === payloadHash && committed.result_json) {
          response(res, 200, committed.result_json);
          return;
        }
        throw deny(409, 'purchase_amendment_conflict', 'Replacement identity is already in use');
      }
      const amended = await applyPurchaseAmendment({
        object, userId, clientMutationId, payloadHash, correlationId,
      });
      response(res, 200, amended);
      return;
    }
    const action = isDeleteOperation(operationType)
      ? 'delete' : (identity.exists ? 'update' : 'create');
    if (action === 'delete' && !identity.exists) {
      throw deny(409, 'sync_identity_missing', 'Cannot delete a missing record');
    }
    if (!cached) assertRoleAllowed(access, table, tableConfig, operationType, action, serviceFeatures);
    const result = await applyMutation({
      table, object, userId, operationType, expectedVersion,
      event: {id: crypto.randomUUID(), correlation_id: correlationId},
      clientMutation: {
        id: crypto.randomUUID(), client_mutation_id: clientMutationId,
        payload_hash: payloadHash,
      },
    });
    response(res, 200, result);
  } catch (err) {
    fail(
      res,
      err.status || 500,
      err.code || 'clinic_sync_function_failed',
      err.status ? err.message : 'Clinic sync function failed',
      { correlation_id: correlationId },
    );
  }
};
