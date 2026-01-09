#!/usr/bin/env bash
set -euo pipefail

# Apply key permissions via Hasura v3 metadata API (pg_create_*_permission).
# Usage:
#   HASURA_ADMIN_SECRET=... bash scripts/hasura_metadata_permissions_v3.sh

ROOT_DIR="/mnt/c/Users/zidan/AndroidStudioProjects/aelmamclinic"
CONFIG_JSON="$ROOT_DIR/config.json"

if [ ! -f "$CONFIG_JSON" ]; then
  echo "Missing config.json at $CONFIG_JSON" >&2
  exit 1
fi

if [ -z "${HASURA_ADMIN_SECRET:-}" ]; then
  echo "Set HASURA_ADMIN_SECRET first." >&2
  exit 1
fi

GRAPHQL_URL=$(python3 - <<'PY'
import json
with open('/mnt/c/Users/zidan/AndroidStudioProjects/aelmamclinic/config.json','r',encoding='utf-8') as f:
    c=json.load(f)
print(c['nhostGraphqlUrl'])
PY
)

HASURA_BASE="${GRAPHQL_URL%/v1}"
HASURA_BASE="${HASURA_BASE/.graphql./.hasura.}"
METADATA_URL="${HASURA_BASE}/v1/metadata"

post_meta () {
  local f="$1"
  local out="/tmp/hasura_meta_$(basename "$f").out"
  local code=""
  local body=""
  local attempt

  for attempt in 1 2 3 4 5; do
    code="$(curl -sS --show-error \
      -o "$out" -w "%{http_code}" \
      -H "Content-Type: application/json" \
      -H "x-hasura-admin-secret: ${HASURA_ADMIN_SECRET}" \
      -d @"$f" \
      "$METADATA_URL" || true)"
    body="$(cat "$out" 2>/dev/null || true)"
    if [ "$code" = "200" ] && [ -n "$body" ]; then
      break
    fi
    sleep 2
  done

  if [ -z "$body" ]; then
    echo "Empty response (HTTP $code) for $(basename "$f")" >&2
    return 1
  fi
  if [ "$code" != "200" ]; then
    echo "HTTP $code for $(basename "$f")" >&2
    echo "$body" >&2
    return 1
  fi
  if printf '%s' "$body" | head -c 1 | grep -q '[{[]'; then
    printf '%s' "$body" | python3 -m json.tool
  else
    printf '%s' "$body"
  fi
}

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

cat > "$tmpdir/drop_inconsistent.json" <<'JSON'
{"type":"drop_inconsistent_metadata","args":{}}
JSON

cat > "$tmpdir/drop_subscription_requests_user_insert.json" <<'JSON'
{
  "type": "pg_drop_insert_permission",
  "args": {
    "source": "default",
    "table": { "schema": "public", "name": "subscription_requests" },
    "role": "user"
  }
}
JSON

cat > "$tmpdir/drop_subscription_requests_user_select.json" <<'JSON'
{
  "type": "pg_drop_select_permission",
  "args": {
    "source": "default",
    "table": { "schema": "public", "name": "subscription_requests" },
    "role": "user"
  }
}
JSON

cat > "$tmpdir/drop_chat_participants_user_insert.json" <<'JSON'
{
  "type": "pg_drop_insert_permission",
  "args": {
    "source": "default",
    "table": { "schema": "public", "name": "chat_participants" },
    "role": "user"
  }
}
JSON

cat > "$tmpdir/drop_chat_participants_me_insert.json" <<'JSON'
{
  "type": "pg_drop_insert_permission",
  "args": {
    "source": "default",
    "table": { "schema": "public", "name": "chat_participants" },
    "role": "me"
  }
}
JSON

cat > "$tmpdir/subscription_requests_user_insert.json" <<'JSON'
{
  "type": "pg_create_insert_permission",
  "args": {
    "source": "default",
    "table": { "schema": "public", "name": "subscription_requests" },
    "role": "user",
    "permission": {
      "check": {
        "_and": [
          { "user_uid": { "_eq": "X-Hasura-User-Id" } },
          {
            "_exists": {
              "_table": { "schema": "public", "name": "user_current_account" },
              "_where": {
                "account_id": { "_ceq": "account_id" },
                "user_uid": { "_eq": "X-Hasura-User-Id" }
              }
            }
          }
        ]
      },
      "columns": [
        "account_id",
        "user_uid",
        "plan_code",
        "payment_method_id",
        "amount",
        "proof_url",
        "reference_text",
        "sender_name",
        "clinic_name",
        "status",
        "note"
      ]
    }
  }
}
JSON

cat > "$tmpdir/subscription_requests_user_select.json" <<'JSON'
{
  "type": "pg_create_select_permission",
  "args": {
    "source": "default",
    "table": { "schema": "public", "name": "subscription_requests" },
    "role": "user",
    "permission": {
      "columns": [
        "id",
        "account_id",
        "user_uid",
        "plan_code",
        "payment_method_id",
        "amount",
        "proof_url",
        "reference_text",
        "sender_name",
        "clinic_name",
        "status",
        "note",
        "created_at",
        "updated_at",
        "reviewed_by",
        "reviewed_at"
      ],
      "filter": {
        "_exists": {
          "_table": { "schema": "public", "name": "user_current_account" },
          "_where": {
            "account_id": { "_ceq": "account_id" },
            "user_uid": { "_eq": "X-Hasura-User-Id" }
          }
        }
      },
      "allow_aggregations": false
    }
  }
}
JSON

cat > "$tmpdir/chat_participants_user_insert.json" <<'JSON'
{
  "type": "pg_create_insert_permission",
  "args": {
    "source": "default",
    "table": { "schema": "public", "name": "chat_participants" },
    "role": "user",
    "permission": {
      "check": {
        "_and": [
          {
            "_or": [
              { "account_id": { "_is_null": true } },
              {
                "_exists": {
                  "_table": { "schema": "public", "name": "account_users" },
                  "_where": {
                    "account_id": { "_ceq": "account_id" },
                    "disabled": { "_eq": false },
                    "user_uid": { "_eq": "X-Hasura-User-Id" }
                  }
                }
              }
            ]
          },
          {
            "_or": [
              { "user_uid": { "_eq": "X-Hasura-User-Id" } },
              {
                "_exists": {
                  "_table": { "schema": "public", "name": "chat_conversations" },
                  "_where": {
                    "id": { "_ceq": "conversation_id" },
                    "created_by": { "_eq": "X-Hasura-User-Id" }
                  }
                }
              }
            ]
          }
        ]
      },
      "columns": [
        "account_id",
        "conversation_id",
        "user_uid",
        "email",
        "nickname",
        "role",
        "joined_at",
        "muted"
      ]
    }
  }
}
JSON

cat > "$tmpdir/chat_participants_me_insert.json" <<'JSON'
{
  "type": "pg_create_insert_permission",
  "args": {
    "source": "default",
    "table": { "schema": "public", "name": "chat_participants" },
    "role": "me",
    "permission": {
      "check": {
        "_and": [
          {
            "_or": [
              { "account_id": { "_is_null": true } },
              {
                "_exists": {
                  "_table": { "schema": "public", "name": "account_users" },
                  "_where": {
                    "account_id": { "_ceq": "account_id" },
                    "disabled": { "_eq": false },
                    "user_uid": { "_eq": "X-Hasura-User-Id" }
                  }
                }
              }
            ]
          },
          {
            "_or": [
              { "user_uid": { "_eq": "X-Hasura-User-Id" } },
              {
                "_exists": {
                  "_table": { "schema": "public", "name": "chat_conversations" },
                  "_where": {
                    "id": { "_ceq": "conversation_id" },
                    "created_by": { "_eq": "X-Hasura-User-Id" }
                  }
                }
              }
            ]
          }
        ]
      },
      "columns": [
        "account_id",
        "conversation_id",
        "user_uid",
        "email",
        "nickname",
        "role",
        "joined_at",
        "muted"
      ]
    }
  }
}
JSON

echo "== Drop inconsistent metadata =="
post_meta "$tmpdir/drop_inconsistent.json" || true

echo "== Drop old permissions (ignore if missing) =="
post_meta "$tmpdir/drop_subscription_requests_user_insert.json" || true
post_meta "$tmpdir/drop_subscription_requests_user_select.json" || true
post_meta "$tmpdir/drop_chat_participants_user_insert.json" || true
post_meta "$tmpdir/drop_chat_participants_me_insert.json" || true

echo "== Apply subscription_requests permissions =="
post_meta "$tmpdir/subscription_requests_user_insert.json"
post_meta "$tmpdir/subscription_requests_user_select.json"

echo "== Apply chat_participants insert permissions =="
post_meta "$tmpdir/chat_participants_user_insert.json"
post_meta "$tmpdir/chat_participants_me_insert.json"

echo "== Reload metadata =="
echo '{"type":"reload_metadata","args":{}}' > "$tmpdir/reload.json"
post_meta "$tmpdir/reload.json" || true

echo "Done."
