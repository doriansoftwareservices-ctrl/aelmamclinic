# Server Snapshot (Nhost/Hasura)
- Subdomain: `mergrgclboxflnucehgb`
- Region: `ap-southeast-1`
- Generated: `2026-01-09T18:12:59+03:00`
- Output folder: `server_snapshot_mergrgclboxflnucehgb_20260109_181259`

## Tooling
```
Python 3.12.3
```

## Nhost config validate
```
Getting secrets...
Config is valid!
```

## Secrets (names only)
```
HASURA_GRAPHQL_ADMIN_SECRET
HASURA_GRAPHQL_JWT_SECRET
NHOST_WEBHOOK_SECRET
GRAFANA_ADMIN_PASSWORD
NHOST_JWT_SECRET
```

## Deployments list
```
                                      │                      │              │          │                             │                                          │                                                                       │
 ID                                   │ Date                 │ Duration     │ Status   │ User                        │ Ref                                      │ Message                                                               │
 75cdbebd-9cc0-4229-9a0f-d3e221b4d791 │ 2026-01-09T13:57:56Z │ 1m23.092912s │ DEPLOYED │ doriansoftwareservices-ctrl │ 3f82019e05499bea04bdde27902f736590bfbc14 │ fix: clean metadata permissions and chat_start_dm tracking            │
 df206794-12f8-4e9e-a8c5-05d8dc8b7f88 │ 2026-01-09T13:32:06Z │ 1m22.607096s │ DEPLOYED │ doriansoftwareservices-ctrl │ 6cec4c58362623f919895c850698afe17eb18b5a │ fix: reversion chat_start_dm migration id                             │
 e00a0ec4-6a0d-4a43-a9c9-d13f4fd5becf │ 2026-01-09T13:16:36Z │ 45.749876s   │ FAILED   │ doriansoftwareservices-ctrl │ cda0b52395ca25c08978c9049c3b2d04e314d5cf │ fix: add user chat_start_dm rpc and use it for DMs                    │
 ff760edc-b4af-4abd-a119-adecbe87c453 │ 2026-01-09T12:32:46Z │ 1m24.432755s │ DEPLOYED │ doriansoftwareservices-ctrl │ 40e1dcebe235bcbd5018636551e7b457d635bf61 │ fix: correct chat_participants insert permission column compare       │
 11d036da-acfe-4544-8916-269e1ea56ce1 │ 2026-01-09T11:21:56Z │ 1m24.144849s │ DEPLOYED │ doriansoftwareservices-ctrl │ 6f2287437ce6173906ce7ad04d1191639d0874c0 │ fix: default employee permissions + chat test conversation seed       │
 5225f01e-7e48-4a52-b2b3-8f119f3a3d4a │ 2026-01-09T10:49:56Z │ 1m24.088749s │ DEPLOYED │ doriansoftwareservices-ctrl │ b08e803040bb265f844b232f2f069fbfc85c1da2 │ fix: normalize auth metadata arrays and improve chat test uid capture │
 6db7237e-97b8-4e94-879e-db5642fac119 │ 2026-01-09T10:34:30Z │ 1m25.05181s  │ DEPLOYED │ doriansoftwareservices-ctrl │ fa1e08058ae2d3b1adb6dab0fecc528f73fec2c3 │ fix: sync auth roles for employee login and chat test ids             │
 3015d180-67c4-4e54-adb4-2da8ac0bb06a │ 2026-01-09T09:37:40Z │ 1m23.331362s │ DEPLOYED │ doriansoftwareservices-ctrl │ 0bddf69f1eb40401449d2277c1473a4418d3f033 │ fix: free plan gating and complaints tab; link doctor user uid        │
 da91d1a3-5d7d-4ed1-98b8-42f2b9261946 │ 2026-01-09T08:57:20Z │ 1m25.773113s │ DEPLOYED │ doriansoftwareservices-ctrl │ 385acf40af4a7be5650a70377f50f14218e111da │ fix: auth claims roles + chat participants insert for cross-account   │
 3df6093d-22b2-49b9-bf5d-f7de2c94708f │ 2026-01-09T06:07:00Z │ 1m37.581661s │ DEPLOYED │ doriansoftwareservices-ctrl │ 649a5c16a86deb7e68e6aafc33af1a9708f64aa5 │ fix: include error details and service role fallback                  │
                                      │                      │              │          │                             │                                          │                                                                       │
```

## Hasura export_metadata
Saved: server_snapshot_mergrgclboxflnucehgb_20260109_181259/hasura_export_metadata.json

## DB inventory
Saved:
- server_snapshot_mergrgclboxflnucehgb_20260109_181259/db_version.json
- server_snapshot_mergrgclboxflnucehgb_20260109_181259/db_objects.json
- server_snapshot_mergrgclboxflnucehgb_20260109_181259/db_functions.json
- server_snapshot_mergrgclboxflnucehgb_20260109_181259/db_policies.json

## GraphQL introspection
Saved: server_snapshot_mergrgclboxflnucehgb_20260109_181259/graphql_introspection.json

