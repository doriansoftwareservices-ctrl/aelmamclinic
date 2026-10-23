"""Evaluate real Hasura predicates, separately from PostgreSQL/engine acceptance.

The authority relation rows are inputs here. Real authority derivation is tested
by the isolated PostgreSQL suite; this suite detects metadata bypasses around
that relation and forbidden client-controlled identity columns.
"""

from functools import lru_cache
from pathlib import Path
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
TABLES = ROOT / "nhost/metadata/databases/default/tables"
ACTOR = "actor"
ROLES = ("employee", "me", "owner", "support", "user", "superadmin")


@lru_cache(maxsize=None)
def metadata(name):
    return yaml.safe_load((TABLES / f"public_{name}.yaml").read_text())


def evaluate(predicate, row, database, root=None):
    root = row if root is None else root
    for key, condition in (predicate or {}).items():
        if key == "_and":
            result = all(evaluate(p, row, database, root) for p in condition)
        elif key == "_or":
            result = any(evaluate(p, row, database, root) for p in condition)
        elif key == "_exists":
            result = any(evaluate(condition["_where"], candidate, database, root)
                         for candidate in database.get(condition["_table"]["name"], []))
        elif key == "chat_conversation":
            result = any(candidate["id"] == row.get("conversation_id")
                         and evaluate(condition, candidate, database, root)
                         for candidate in database.get("chat_conversations", []))
        elif key == "chat_participants":
            result = any(candidate["conversation_id"] == row.get("conversation_id")
                         and evaluate(condition, candidate, database, root)
                         for candidate in database.get("chat_participants", []))
        else:
            value = row.get(key)
            result = True
            for operator, expected in condition.items():
                if expected == "X-Hasura-User-Id":
                    expected = ACTOR
                if operator == "_ceq":
                    result &= value == root.get(expected[-1])
                elif operator == "_eq":
                    result &= value is not None and value == expected
                elif operator == "_neq":
                    result &= value is not None and value != expected
                elif operator == "_is_null":
                    result &= (value is None) == expected
                elif operator == "_in":
                    result &= value in expected
                else:
                    raise AssertionError(f"Unsupported predicate {operator}")
        if not result:
            return False
    return True


def permission(name, action, role):
    return next((item["permission"] for item in metadata(name).get(f"{action}_permissions", [])
                 if item["role"] == role), None)


def allows(name, action, role, row, database, columns=()):
    rule = permission(name, action, role)
    if rule is None:
        return False
    permitted = rule.get("columns", "*")
    if columns and permitted != "*" and not set(columns) <= set(permitted):
        return False
    return all(evaluate(rule[key], row, database) for key in ("filter", "check") if key in rule)


def fixture(*, active=True, hidden=False, bootstrap=False, superadmin=False):
    access = {"conversation_id": "room", "account_id": "clinic", "user_uid": ACTOR,
              "can_read": not hidden and not bootstrap, "can_self_update": not bootstrap,
              "can_bootstrap": bootstrap, "is_superadmin": superadmin}
    participant = {"conversation_id": "room", "account_id": "clinic", "user_uid": ACTOR,
                   "is_deleted": hidden, "role": "owner"}
    return {
        "chat_current_access": [access] if active else [],
        "chat_message_current_access": [{**access, "message_id": "message"}] if active else [],
        "active_authenticated_identity": [{"user_uid": ACTOR}],
        "active_superadmin_identity": [{"user_uid": ACTOR}] if superadmin else [],
        "chat_conversations": [{"id": "room", "account_id": "clinic", "created_by": ACTOR}],
        "chat_participants": [participant],
        "account_users": [{"account_id": "clinic", "user_uid": ACTOR, "disabled": False, "role": "owner"}],
        "chat_messages": [{"id": "message", "conversation_id": "room", "sender_uid": ACTOR}],
    }


class CurrentAuthorityMetadataTests(unittest.TestCase):
    surfaces = ("chat_conversations", "chat_messages", "chat_participants", "chat_reads",
                "chat_typing", "chat_delivery_receipts", "chat_reactions",
                "v_chat_conversations_for_me", "v_chat_reads_for_me",
                "v_chat_typing_active", "v_chat_last_message")

    def row(self, surface):
        return {"id": "room" if surface in ("chat_conversations", "v_chat_conversations_for_me") else "message",
                "conversation_id": "room", "account_id": "clinic", "message_id": "message",
                "user_uid": ACTOR, "sender_uid": ACTOR, "created_by": ACTOR,
                "is_deleted": False}

    def test_revocation_cannot_be_bypassed_by_persisted_participant_and_active_auth(self):
        for role in ROLES:
            for surface in self.surfaces:
                with self.subTest(role=role, surface=surface):
                    self.assertFalse(allows(surface, "select", role, self.row(surface), fixture(active=False)))

    def test_current_member_keeps_each_existing_read_surface(self):
        for role in ROLES:
            for surface in self.surfaces:
                if permission(surface, "select", role) is None:
                    continue
                with self.subTest(role=role, surface=surface):
                    self.assertTrue(allows(surface, "select", role, self.row(surface), fixture(superadmin=role == "superadmin")))

    def test_participant_identity_and_role_are_never_self_service_columns(self):
        for role in ROLES:
            for column in ("conversation_id", "account_id", "user_uid", "role", "personal_hidden"):
                with self.subTest(role=role, column=column):
                    self.assertFalse(allows("chat_participants", "update", role, self.row("chat_participants"),
                                            fixture(superadmin=role == "superadmin"), [column]))

    def test_read_and_typing_identities_are_immutable_at_metadata_boundary(self):
        for role in ROLES:
            for surface in ("chat_reads", "chat_typing"):
                for column in ("conversation_id", "user_uid", "account_id"):
                    with self.subTest(role=role, surface=surface, column=column):
                        self.assertFalse(allows(surface, "update", role, self.row(surface), fixture(), [column]))

    def test_conversation_origin_cannot_be_reassigned(self):
        for role in ROLES:
            rule = permission("chat_conversations", "update", role)
            if rule is None:
                continue
            self.assertTrue(set(rule["columns"]).isdisjoint({"id", "account_id", "created_by", "created_at", "is_group"}))

    def test_hidden_self_preferences_remain_available_without_room_messages(self):
        for role in ROLES[:-1]:
            database = fixture(hidden=True)
            self.assertTrue(allows("chat_participants", "update", role, self.row("chat_participants"), database,
                                   ["archived", "muted", "last_read_at", "is_deleted", "deleted_at"]))
            self.assertFalse(allows("chat_messages", "select", role, self.row("chat_messages"), database))

    def test_removed_member_cannot_restore_tombstone(self):
        for role in ROLES:
            self.assertFalse(allows("chat_participants", "update", role, self.row("chat_participants"),
                                    fixture(active=False), ["is_deleted"]))

    def test_foreign_self_join_and_creator_inserting_someone_else_are_denied(self):
        for role in ROLES[:-1]:
            own = {**self.row("chat_participants"), "role": "owner"}
            self.assertFalse(allows("chat_participants", "insert", role, own, fixture(active=False)))
            other = {**own, "user_uid": "other"}
            self.assertFalse(allows("chat_participants", "insert", role, other, fixture(bootstrap=True)))

    def test_creator_bootstrap_remains_compatible_with_existing_upsert(self):
        for role in ("me", "support", "user"):
            row = {**self.row("chat_participants"), "role": "owner"}
            self.assertTrue(allows("chat_participants", "insert", role, row, fixture(bootstrap=True)))
            self.assertTrue(allows("chat_participants", "update", role, row, fixture(), ["email", "joined_at"]))

    def test_ordinary_hard_delete_cannot_erase_removal_history(self):
        for role in ROLES[:-1]:
            for surface in ("chat_participants", "chat_conversations"):
                self.assertIsNone(permission(surface, "delete", role))

    def test_revoked_member_cannot_write_other_chat_surfaces(self):
        for role in ROLES:
            for surface in ("chat_messages", "chat_reads", "chat_typing", "chat_delivery_receipts", "chat_reactions"):
                for action in ("insert", "update", "delete"):
                    with self.subTest(role=role, surface=surface, action=action):
                        self.assertFalse(allows(surface, action, role, self.row(surface), fixture(active=False)))

    def test_private_authority_relations_have_no_graphql_permissions(self):
        for name in ("chat_scope_authority", "chat_current_access", "chat_message_current_access"):
            self.assertEqual(set(metadata(name)), {"table"})
        includes = yaml.safe_load((TABLES / "tables.yaml").read_text())
        self.assertEqual(len(includes), len(set(includes)))


if __name__ == "__main__":
    unittest.main()
