#!/usr/bin/env bash
set -euo pipefail

ROOT="nhost/metadata/databases/default"
TABLES_FILE="$ROOT/tables/tables.yaml"
FUNCS_FILE="$ROOT/functions/functions.yaml"

mkdir -p "$(dirname "$TABLES_FILE")" "$(dirname "$FUNCS_FILE")"
touch "$TABLES_FILE" "$FUNCS_FILE"

append_table_if_missing () {
  local name="$1"
  # تحقّق بسيط لتجنب التكرار
  if grep -qE "name:\s*${name}\b" "$TABLES_FILE"; then
    return 0
  fi

  cat >> "$TABLES_FILE" <<EOF

- table:
    schema: public
    name: ${name}
EOF
}

append_function_if_missing () {
  local name="$1"
  if grep -qE "name:\s*${name}\b" "$FUNCS_FILE"; then
    return 0
  fi

  cat >> "$FUNCS_FILE" <<EOF

- function:
    schema: public
    name: ${name}
EOF
}

# Tables used by chat flows
tables=(
  chat_conversations
  chat_participants
  chat_messages
  chat_reads
  chat_attachments
  chat_reactions
  chat_delivery_receipts
  chat_group_invitations
  chat_aliases
  chat_typing
  account_users
  profiles
  clinics
)

# Views used by chat flows (Tracked as tables in Hasura)
views=(
  v_chat_conversations_for_me
  v_chat_group_invitations_for_me
  v_chat_typing_active
  v_chat_messages_with_attachments
  v_chat_reads_for_me
  v_chat_last_message
)

# Functions used by chat flows
functions=(
  my_account_id
  chat_mark_delivered
  chat_accept_invitation
  chat_decline_invitation
  chat_admin_start_dm
)

for t in "${tables[@]}"; do append_table_if_missing "$t"; done
for v in "${views[@]}"; do append_table_if_missing "$v"; done
for f in "${functions[@]}"; do append_function_if_missing "$f"; done

echo "✅ Repo metadata updated: chat tables/views/functions are now tracked."
echo "Tables file:   $TABLES_FILE"
echo "Functions file:$FUNCS_FILE"
