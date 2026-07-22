const crypto = require('crypto');
const {
  readBody,
  extractBearer,
  resolveUserIdFromToken,
} = require('../_shared/storage_utils');

const META_COLUMNS = new Set([
  'client_mutation_id',
  'is_deleted',
  'deleted_at',
  'deleted_by_user_id',
  'deletion_client_mutation_id',
  'server_version',
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

const FULL_SYNC_ROLES = new Set(['owner', 'admin']);

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
  medical_services: 'lab_radiology',
  service_doctor_share: 'lab_radiology',
  complaints: 'patients.questions',
};

function syncCrudAction(operationType) {
  const text = `${operationType || ''}`.trim().toLowerCase();
  if (text.includes('delete') || text.includes('reverse') || text.includes('disable')) {
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
  return text.includes('delete') || text.includes('reverse') || text.includes('disable');
}

function filterPayload(table, payload, context) {
  const config = TABLES[table];
  const allowed = new Set([
    'id',
    'account_id',
    'device_id',
    'local_id',
    'updated_at',
    ...config.columns,
    ...META_COLUMNS,
  ]);
  const out = {};
  for (const [key, value] of Object.entries(payload)) {
    if (!allowed.has(key)) continue;
    if (value === undefined) continue;
    if (key === 'id' && !`${value || ''}`.trim()) continue;
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
    out.deleted_at = out.deleted_at || new Date().toISOString();
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

function assertRoleAllowed(access, table, tableConfig, operationType) {
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

  const action = syncCrudAction(operationType);
  const hasFullCrudRole = FULL_SYNC_ROLES.has(access.role);
  if (action === 'create' && !hasFullCrudRole && !access.canCreate) {
    throw deny(403, 'sync_create_denied', 'You do not have permission to create this data');
  }
  if (action === 'update' && !hasFullCrudRole && !access.canUpdate) {
    throw deny(403, 'sync_update_denied', 'You do not have permission to update this data');
  }
  if (action === 'delete' && !hasFullCrudRole && !access.canDelete) {
    throw deny(403, 'sync_delete_denied', 'You do not have permission to delete this data');
  }

  const requiredFeature = requiredFeatureFor(table, operationType);
  if (
    requiredFeature &&
    !access.allowAll &&
    !access.allowedFeatures.includes(requiredFeature)
  ) {
    throw deny(
      403,
      'sync_feature_denied',
      `You do not have permission for feature ${requiredFeature}`,
    );
  }
}

async function applyMutation({
  table,
  tableConfig,
  object,
  event,
  clientMutation,
}) {
  const updateColumns = [
    ...new Set([
      ...tableConfig.columns,
      'updated_at',
      'client_mutation_id',
      'is_deleted',
      'deleted_at',
      'deleted_by_user_id',
      'deletion_client_mutation_id',
      'updated_by_user_id',
    ]),
  ].filter((column) => column !== 'id' && column !== 'account_id');
  const mutationDoc = `
    mutation ClinicSyncApply(
      $object: ${table}_insert_input!,
      $event: sync_events_insert_input!,
      $clientMutation: client_mutations_insert_input!
    ) {
      row: insert_${table}_one(
        object: $object,
        on_conflict: {
          constraint: ${tableConfig.constraint},
          update_columns: [${updateColumns.join(', ')}]
        }
      ) {
        id
        updated_at
        server_version
      }
      event: insert_sync_events_one(object: $event) {
        id
        created_at
      }
      clientMutation: insert_client_mutations_one(object: $clientMutation) {
        id
      }
    }
  `;
  return gqlRequest(mutationDoc, { object, event, clientMutation });
}

function deterministicUuid(value) {
  const bytes = crypto.createHash('sha256').update(value).digest().subarray(0, 16);
  bytes[6] = (bytes[6] & 0x0f) | 0x50;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = bytes.toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

async function resolveRemoteId({
  table,
  accountId,
  deviceId,
  localId,
  requestedId,
  clientMutationId,
}) {
  const candidate = `${requestedId || ''}`.trim();
  if (/^[0-9a-f-]{36}$/i.test(candidate)) return candidate;
  const query = `
    query ExistingSyncIdentity(
      $accountId: uuid!,
      $deviceId: String!,
      $localId: bigint!
    ) {
      rows: ${table}(
        where: {
          account_id: {_eq: $accountId},
          device_id: {_eq: $deviceId},
          local_id: {_eq: $localId}
        },
        limit: 1
      ) { id }
    }
  `;
  const data = await gqlRequest(query, { accountId, deviceId, localId });
  const existing = Array.isArray(data.rows) ? data.rows[0]?.id : null;
  return existing || deterministicUuid(`${accountId}:${table}:${clientMutationId}`);
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

module.exports = async function handler(req, res) {
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
    const localId =
      typeof body.local_id === 'number'
        ? body.local_id
        : parseInt(`${body.local_id || ''}`, 10);

    if (!operationType || !tableConfig || !clientMutationId || !accountId) {
      fail(res, 400, 'invalid_sync_request', 'Invalid sync request', {
        correlation_id: correlationId,
      });
      return;
    }
    if (!deviceId || !Number.isFinite(localId) || localId <= 0) {
      fail(res, 400, 'invalid_local_identity', 'Missing device/local identity', {
        correlation_id: correlationId,
      });
      return;
    }

    const payload = normalizeObject(body.payload);
    const payloadHash = hashPayload({
      operation_type: operationType,
      entity_table: table,
      account_id: accountId,
      payload,
    });

    // Security first: never return cached mutation results before proving that
    // the current JWT still belongs to the requested account and has permission
    // for this table/operation. client_mutation_id values are opaque, but cached
    // result_json may contain remote ids and sync event ids.
    const access = await accessFor(userId, accountId);
    assertRoleAllowed(access, table, tableConfig, operationType);

    const cached = await fetchCachedMutation(clientMutationId, accountId);
    if (cached) {
      if (cached.payload_hash && cached.payload_hash !== payloadHash) {
        fail(res, 409, 'idempotency_payload_mismatch', 'Mutation id was reused with a different payload', {
          correlation_id: correlationId,
        });
        return;
      }
      if (cached.result_json) {
        response(res, 200, cached.result_json);
        return;
      }
      const recovered = await recoverCommittedMutation({
        cached,
        table,
        accountId,
        clientMutationId,
      });
      if (recovered) {
        response(res, 200, recovered);
        return;
      }
      throw deny(409, 'mutation_in_progress', 'Mutation is still being committed');
    }

    const object = filterPayload(table, payload, {
      accountId,
      deviceId,
      localId,
      clientMutationId,
      userId,
      deleteOperation: isDeleteOperation(operationType),
    });
    object.id = await resolveRemoteId({
      table,
      accountId,
      deviceId,
      localId,
      requestedId: object.id,
      clientMutationId,
    });
    const now = new Date().toISOString();
    const eventId = crypto.randomUUID();
    const mutationRowId = crypto.randomUUID();
    const event = {
      id: eventId,
      account_id: accountId,
      domain: tableConfig.domain,
      entity_table: table,
      entity_id: object.id,
      operation_type: operationType,
      actor_user_id: userId,
      client_mutation_id: clientMutationId,
      correlation_id: correlationId,
    };
    const result = {
      success: true,
      operation: operationType,
      server_timestamp: now,
      data: {
        entity_table: table,
        client_mutation_id: clientMutationId,
        remote_id: object.id,
        server_version: null,
        sync_event_id: eventId,
      },
    };

    try {
      await applyMutation({
        table,
        tableConfig,
        object,
        event,
        clientMutation: {
          id: mutationRowId,
          account_id: accountId,
          client_mutation_id: clientMutationId,
          operation_type: operationType,
          actor_user_id: userId,
          payload_hash: payloadHash,
          correlation_id: correlationId,
          result_json: result,
          completed_at: now,
        },
      });
    } catch (error) {
      if (!error?.isConstraintViolation) throw error;
      const concurrent = await fetchCachedMutation(clientMutationId, accountId);
      if (!concurrent || concurrent.payload_hash !== payloadHash) {
        throw deny(409, 'idempotency_conflict', 'Concurrent mutation conflict');
      }
      const recovered = concurrent.result_json ||
        await recoverCommittedMutation({
          cached: concurrent,
          table,
          accountId,
          clientMutationId,
        });
      if (!recovered) {
        throw deny(409, 'mutation_in_progress', 'Mutation is still being committed');
      }
      response(res, 200, recovered);
      return;
    }
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
