# Server Snapshot (Nhost/Hasura)
- Subdomain: `mergrgclboxflnucehgb`
- Region: `ap-southeast-1`
- Generated: `2026-01-01T11:31:09+03:00`
- Output folder: `server_snapshot_mergrgclboxflnucehgb_20260101_113109`

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
```

## Deployments list
```
                                      │                      │              │          │                             │                                          │                                                                 │
 ID                                   │ Date                 │ Duration     │ Status   │ User                        │ Ref                                      │ Message                                                         │
 39b5bc0d-b97f-4925-913a-d986ce6ae723 │ 2025-12-31T20:26:53Z │ 1m20.728871s │ DEPLOYED │ doriansoftwareservices-ctrl │ d35adc70cc88667b65400ad0cf9f773363f3330e │ chore: redeploy after metadata 502                              │
 da37f6e4-5d24-415a-8f86-b2e3ca859355 │ 2025-12-31T20:22:23Z │ 2m16.603496s │ FAILED   │ doriansoftwareservices-ctrl │ efad8b2514928c85d1c5568fe5c3e0d76e6d6d7f │ fix: pass hasura_session to auth RPCs via session_argument      │
 0b38d841-ca60-4442-ae02-d64be5898fd1 │ 2025-12-31T19:09:23Z │ 1m21.997323s │ DEPLOYED │ doriansoftwareservices-ctrl │ a5a50bfb9466f3096ff290ba78fe1875fbb9d94b │ fix(metadata): remove session_argument from self_create_account │
 25da1833-8020-4a2a-b77d-582b59d45dba │ 2025-12-31T03:25:13Z │ 1m19.016346s │ DEPLOYED │ doriansoftwareservices-ctrl │ c020952461e440376e37d3a78dad7fa503c3c961 │ chore: redeploy after metadata 502                              │
 d6bfdcdc-693c-4b1c-98c4-24da7b04448b │ 2025-12-31T03:19:43Z │ 3m22.63238s  │ FAILED   │ doriansoftwareservices-ctrl │ 3347c39b209ef8a13788e2881c3209113437214a │ fix: add hasura jwt claims_map                                  │
 d180b9b3-d34f-4409-b714-dcc53f58da4a │ 2025-12-31T02:40:43Z │ 1m11.337132s │ DEPLOYED │ doriansoftwareservices-ctrl │ a880aa80640d3f5bad42ae23825370c65c3c4e02 │ fix: remove session_argument from functions metadata            │
 cbae0fa2-7963-4b19-aeaa-7aeffabc8dcb │ 2025-12-31T02:09:03Z │ 1m10.729052s │ DEPLOYED │ doriansoftwareservices-ctrl │ 38fef9b028fc3e6faaae89d566dd0c2177b68308 │ revert: remove broken migration referencing v_me_profile        │
 46d8c317-9b70-4a40-aaaa-7e68a87ebff9 │ 2025-12-31T01:49:23Z │ 48.311834s   │ FAILED   │ doriansoftwareservices-ctrl │ a2c68d14213449779d85748f7988816affd080c8 │ fix: jwt claims_format json                                     │
 5c1d242f-29de-4f9a-9a7b-ff73bae40441 │ 2025-12-27T01:26:47Z │ 57.733364s   │ FAILED   │ doriansoftwareservices-ctrl │ c680c7193d1a61a8b81ec32c24fe6ea9bbdeea70 │ fix(hasura): pass session vars to RPCs via session_argument     │
 a30f59d4-fe37-490e-ba7c-e98c00a2f273 │ 2025-12-27T00:16:47Z │ 1m9.198123s  │ DEPLOYED │ doriansoftwareservices-ctrl │ da44f4fd5ded745e48a9acdc8ff744d45ca546b6 │ chore: trigger redeploy                                         │
                                      │                      │              │          │                             │                                          │                                                                 │
```

## Hasura export_metadata
Saved: server_snapshot_mergrgclboxflnucehgb_20260101_113109/hasura_export_metadata.json

## DB inventory
Saved:
- server_snapshot_mergrgclboxflnucehgb_20260101_113109/db_version.json
- server_snapshot_mergrgclboxflnucehgb_20260101_113109/db_objects.json
- server_snapshot_mergrgclboxflnucehgb_20260101_113109/db_functions.json
- server_snapshot_mergrgclboxflnucehgb_20260101_113109/db_policies.json

## GraphQL introspection
Saved: server_snapshot_mergrgclboxflnucehgb_20260101_113109/graphql_introspection.json

