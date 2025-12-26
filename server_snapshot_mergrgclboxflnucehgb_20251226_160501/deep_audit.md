# Deep GraphQL Audit (client vs server)

Snapshot: server_snapshot_mergrgclboxflnucehgb_20251226_160501

Total GraphQL ops detected: 25
Missing root fields: 4

## Missing root fields (used in app but not in server schema)
- query admin_payment_stats (lib/services/admin_billing_service.dart)
- query admin_payment_stats_by_day (lib/services/admin_billing_service.dart)
- query admin_payment_stats_by_month (lib/services/admin_billing_service.dart)
- query admin_payment_stats_by_plan (lib/services/admin_billing_service.dart)
