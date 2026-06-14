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
    columns: ['type_id', 'name', 'price', 'stock', 'created_at'],
  },
  drugs: {
    constraint: 'drugs_account_id_device_id_local_id_key',
    domain: 'reference',
    columns: ['name', 'notes', 'created_at'],
  },
  medical_services: {
    constraint: 'medical_services_account_id_device_id_local_id_key',
    domain: 'reference',
    columns: ['name', 'cost', 'service_type'],
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
      'final_salary',
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
      'remaining',
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
      'doctor_share',
      'doctor_input',
      'tower_share',
      'department_share',
      'doctor_review_pending',
      'doctor_reviewed_at',
    ],
  },
  patient_services: {
    constraint: 'patient_services_account_id_device_id_local_id_key',
    domain: 'clinical',
    columns: ['patient_id', 'service_id', 'service_name', 'service_cost'],
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
    columns: ['patient_id', 'appointment_time', 'status', 'notes'],
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
    columns: ['patient_id', 'item_id', 'quantity', 'date', 'amount', 'note'],
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
      'ratio_sum',
      'loan_amount',
      'leftover',
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
      'ratio_sum',
      'total_loans',
      'total_discounts',
      'net_pay',
      'is_paid',
      'payment_date',
      'period_start',
      'period_end',
    ],
  },
  employees_discounts: {
    constraint: 'employees_discounts_account_id_device_id_local_id_key',
    domain: 'finance',
    columns: ['employee_id', 'discount_date_time', 'amount', 'notes'],
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
      'employee_id',
      'patient_id',
      'description',
      'modification_details',
      'timestamp',
    ],
  },
};

function graphqlUrl() {
  const raw =
    process.env.NHOST_GRAPHQL_URL ||
    process.env.HASURA_GRAPHQL_URL ||
    process.env.GRAPHQL_URL ||
    '';
  if (raw && raw.includes('nhost.run')) {
    let normalized = raw.replace(/\/+$/, '');
    if (normalized.endsWith('/v1/graphql')) return normalized;
    if (normalized.endsWith('/v1')) return normalized;
    return `${normalized}/v1`;
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
    throw new Error(`GraphQL returned invalid JSON: ${text}`);
  }
  if (!res.ok || json.errors) {
    const message = json.errors
      ? json.errors.map((e) => e.message || JSON.stringify(e)).join('; ')
      : text;
    const err = new Error(message || `GraphQL failed: ${res.status}`);
    err.graphql = json;
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

async function fetchCachedMutation(clientMutationId) {
  const query = `
    query ExistingMutation($id: String!) {
      client_mutations(where: {client_mutation_id: {_eq: $id}}, limit: 1) {
        payload_hash
        result_json
      }
    }
  `;
  const data = await gqlRequest(query, { id: clientMutationId });
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
        frozen
      }
      super_admins(where: {user_uid: {_eq: $userId}}, limit: 1) {
        id
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
  return {
    role: `${membership?.role || ''}`.trim().toLowerCase(),
    memberDisabled: membership?.disabled === true,
    accountFrozen: data.accounts_by_pk?.frozen === true,
    isSuperAdmin: !!superAdmin,
    isMember: !!membership,
  };
}

function assertRoleAllowed(access, tableConfig) {
  if (access.isSuperAdmin) return;
  if (!access.isMember) {
    const err = new Error('User is not a member of this account');
    err.status = 403;
    err.code = 'not_account_member';
    throw err;
  }
  if (access.memberDisabled) {
    const err = new Error('User is disabled for this account');
    err.status = 403;
    err.code = 'user_disabled';
    throw err;
  }
  if (access.accountFrozen) {
    const err = new Error('Account is frozen');
    err.status = 423;
    err.code = 'account_frozen';
    throw err;
  }
  if (
    Array.isArray(tableConfig.allowedRoles) &&
    !tableConfig.allowedRoles.includes(access.role)
  ) {
    const err = new Error('Operation is not allowed for this role');
    err.status = 403;
    err.code = 'insufficient_sync_role';
    throw err;
  }
}

async function applyMutation({ table, tableConfig, object, event }) {
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
      $event: sync_events_insert_input!
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
    }
  `;
  return gqlRequest(mutationDoc, { object, event });
}

async function cacheMutationResult(mutation) {
  const mutationDoc = `
    mutation CacheClinicSyncMutation($mutation: client_mutations_insert_input!) {
      clientMutation: insert_client_mutations_one(
        object: $mutation,
        on_conflict: {
          constraint: client_mutations_client_mutation_id_key,
          update_columns: [result_json]
        }
      ) {
        id
        result_json
      }
    }
  `;
  return gqlRequest(mutationDoc, { mutation });
}

module.exports = async function handler(req, res) {
  if (req.method && req.method.toUpperCase() !== 'POST') {
    fail(res, 405, 'method_not_allowed', 'POST is required');
    return;
  }

  try {
    const token = extractBearer(req);
    const userId = await resolveUserIdFromToken(token);
    if (!userId) {
      fail(res, 401, 'invalid_session', 'Invalid or missing session');
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
      fail(res, 400, 'invalid_sync_request', 'Invalid sync request');
      return;
    }
    if (!deviceId || !Number.isFinite(localId) || localId <= 0) {
      fail(res, 400, 'invalid_local_identity', 'Missing device/local identity');
      return;
    }

    const payload = normalizeObject(body.payload);
    const payloadHash = hashPayload({
      operation_type: operationType,
      entity_table: table,
      account_id: accountId,
      payload,
    });

    const cached = await fetchCachedMutation(clientMutationId);
    if (cached?.result_json) {
      if (cached.payload_hash && cached.payload_hash !== payloadHash) {
        fail(res, 409, 'idempotency_payload_mismatch', 'Mutation id was reused with a different payload');
        return;
      }
      response(res, 200, cached.result_json);
      return;
    }

    const access = await accessFor(userId, accountId);
    assertRoleAllowed(access, tableConfig);

    const object = filterPayload(table, payload, {
      accountId,
      deviceId,
      localId,
      clientMutationId,
      userId,
      deleteOperation: isDeleteOperation(operationType),
    });
    const now = new Date().toISOString();
    const event = {
      account_id: accountId,
      domain: tableConfig.domain,
      entity_table: table,
      operation_type: operationType,
      actor_user_id: userId,
    };

    const data = await applyMutation({
      table,
      tableConfig,
      object,
      event,
    });
    const row = data.row || {};
    const result = {
      success: true,
      operation: operationType,
      server_timestamp: row.updated_at || now,
      data: {
        entity_table: table,
        client_mutation_id: clientMutationId,
        remote_id: row.id || null,
        server_version: row.server_version ?? null,
        sync_event_id: data.event?.id || null,
      },
    };
    try {
      await cacheMutationResult({
        account_id: accountId,
        client_mutation_id: clientMutationId,
        operation_type: operationType,
        actor_user_id: userId,
        payload_hash: payloadHash,
        result_json: result,
      });
    } catch (cacheErr) {
      console.warn(
        'clinic-sync: client_mutations cache failed',
        cacheErr?.message || cacheErr,
      );
    }

    response(res, 200, result);
  } catch (err) {
    fail(
      res,
      err.status || 500,
      err.code || 'clinic_sync_function_failed',
      err.message || 'Clinic sync function failed',
      err.graphql ? { graphql: err.graphql } : {},
    );
  }
};
