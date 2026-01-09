# Server Snapshot (Nhost/Hasura)
- Subdomain: `mergrgclboxflnucehgb`
- Region: `ap-southeast-1`
- Generated: `2026-01-09T19:49:38+03:00`
- Output folder: `server_snapshot_mergrgclboxflnucehgb_20260109_194938`

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
 711c5705-6529-422f-a253-ee17b40360c8 │ 2026-01-09T16:28:36Z │ 1m23.925322s │ DEPLOYED │ doriansoftwareservices-ctrl │ 85e388448685bef413d0769221a623344cb6d621 │ Initial sync                                                          │
 04cbbe3d-e363-434f-95dc-521a3fb6c626 │ 2026-01-09T16:06:46Z │ 2m31.061077s │ DEPLOYED │ doriansoftwareservices-ctrl │ 0f3956887a990f12d65a92a3c77039b4d5abc84e │ fix: create owner via auth signup with SQL fallback                   │
 75cdbebd-9cc0-4229-9a0f-d3e221b4d791 │ 2026-01-09T13:57:56Z │ 1m23.092912s │ DEPLOYED │ doriansoftwareservices-ctrl │ 3f82019e05499bea04bdde27902f736590bfbc14 │ fix: clean metadata permissions and chat_start_dm tracking            │
 df206794-12f8-4e9e-a8c5-05d8dc8b7f88 │ 2026-01-09T13:32:06Z │ 1m22.607096s │ DEPLOYED │ doriansoftwareservices-ctrl │ 6cec4c58362623f919895c850698afe17eb18b5a │ fix: reversion chat_start_dm migration id                             │
 e00a0ec4-6a0d-4a43-a9c9-d13f4fd5becf │ 2026-01-09T13:16:36Z │ 45.749876s   │ FAILED   │ doriansoftwareservices-ctrl │ cda0b52395ca25c08978c9049c3b2d04e314d5cf │ fix: add user chat_start_dm rpc and use it for DMs                    │
 ff760edc-b4af-4abd-a119-adecbe87c453 │ 2026-01-09T12:32:46Z │ 1m24.432755s │ DEPLOYED │ doriansoftwareservices-ctrl │ 40e1dcebe235bcbd5018636551e7b457d635bf61 │ fix: correct chat_participants insert permission column compare       │
 11d036da-acfe-4544-8916-269e1ea56ce1 │ 2026-01-09T11:21:56Z │ 1m24.144849s │ DEPLOYED │ doriansoftwareservices-ctrl │ 6f2287437ce6173906ce7ad04d1191639d0874c0 │ fix: default employee permissions + chat test conversation seed       │
 5225f01e-7e48-4a52-b2b3-8f119f3a3d4a │ 2026-01-09T10:49:56Z │ 1m24.088749s │ DEPLOYED │ doriansoftwareservices-ctrl │ b08e803040bb265f844b232f2f069fbfc85c1da2 │ fix: normalize auth metadata arrays and improve chat test uid capture │
 6db7237e-97b8-4e94-879e-db5642fac119 │ 2026-01-09T10:34:30Z │ 1m25.05181s  │ DEPLOYED │ doriansoftwareservices-ctrl │ fa1e08058ae2d3b1adb6dab0fecc528f73fec2c3 │ fix: sync auth roles for employee login and chat test ids             │
 3015d180-67c4-4e54-adb4-2da8ac0bb06a │ 2026-01-09T09:37:40Z │ 1m23.331362s │ DEPLOYED │ doriansoftwareservices-ctrl │ 0bddf69f1eb40401449d2277c1473a4418d3f033 │ fix: free plan gating and complaints tab; link doctor user uid        │
                                      │                      │              │          │                             │                                          │                                                                       │
```

## Hasura export_metadata
Saved: server_snapshot_mergrgclboxflnucehgb_20260109_194938/hasura_export_metadata.json

## DB inventory
Saved:
- server_snapshot_mergrgclboxflnucehgb_20260109_194938/db_version.json
- server_snapshot_mergrgclboxflnucehgb_20260109_194938/db_objects.json
- server_snapshot_mergrgclboxflnucehgb_20260109_194938/db_functions.json
- server_snapshot_mergrgclboxflnucehgb_20260109_194938/db_policies.json

## GraphQL introspection
Saved: server_snapshot_mergrgclboxflnucehgb_20260109_194938/graphql_introspection.json

