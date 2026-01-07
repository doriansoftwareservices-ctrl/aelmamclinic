# Server Snapshot (Nhost/Hasura)
- Subdomain: `mergrgclboxflnucehgb`
- Region: `ap-southeast-1`
- Generated: `2026-01-07T09:23:14+03:00`
- Output folder: `server_snapshot_mergrgclboxflnucehgb_20260107_092314`

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
                                      │                      │              │          │                             │                                          │                                                            │
 ID                                   │ Date                 │ Duration     │ Status   │ User                        │ Ref                                      │ Message                                                    │
 74b16a9e-8bb6-45d5-b147-4e39d2cddaae │ 2026-01-07T05:23:50Z │ 1m15.074926s │ DEPLOYED │ doriansoftwareservices-ctrl │ 7202887cf38a1cce82f9a2df3fead7aabddcfcd0 │ fix: guard storage policy role escalation                  │
 22a7e68f-57ad-43ca-b318-4fd40b5b0719 │ 2026-01-07T05:11:20Z │ 55.189753s   │ FAILED   │ doriansoftwareservices-ctrl │ 365833774a48129a9fe0605ee8f594e9e84f8dff │ fix: force storage policies + auth admin URL               │
 4430c2b5-a4aa-4360-b8aa-20814ae442b6 │ 2026-01-07T04:28:20Z │ 2m26.110597s │ DEPLOYED │ doriansoftwareservices-ctrl │ d36254c8b900c6c65f1fdfd9ad04a94e2ac989bc │ fix: auth role cleanup + storage policies + auth admin URL │
 b580e1af-e402-4633-889e-982b879bb7b1 │ 2026-01-06T23:53:10Z │ 1m14.713798s │ DEPLOYED │ doriansoftwareservices-ctrl │ 2185fceb9161943a8f8b668b3100e0b31b19e60d │ fix: auth defaults + auth URL normalization                │
 fef5f112-83ef-40a8-b143-30cd83ac483e │ 2026-01-06T23:08:20Z │ 1m14.945332s │ DEPLOYED │ doriansoftwareservices-ctrl │ dc596445aaa4441e0ff788e535ffbd400eaee72f │ fix: auth default role cleanup                             │
 6f0bd980-ba54-4c73-8005-630c434c7f2e │ 2026-01-06T22:00:10Z │ 1m15.415442s │ DEPLOYED │ doriansoftwareservices-ctrl │ d8e672975159568f36ccae9bb345378b45e26d82 │ fix: prevent default superadmin roles                      │
 940ab5f2-130b-4920-a082-0db19fa845db │ 2026-01-06T18:35:50Z │ 1m14.331325s │ DEPLOYED │ doriansoftwareservices-ctrl │ c5f3e32ef35925757e5c49ab57513723b07ec016 │ fix: apply storage.files policies with role switch         │
 25259e9b-1e13-4a85-928c-7e7dd560f658 │ 2026-01-06T17:16:00Z │ 1m13.359667s │ DEPLOYED │ doriansoftwareservices-ctrl │ 214f492c59d004df1a735263f17e47369064c7e1 │ chore: sync auth roles tables                              │
 69d7d2dd-93c9-4fe9-bad8-a13feb58466b │ 2026-01-06T17:03:00Z │ 1m14.723249s │ DEPLOYED │ doriansoftwareservices-ctrl │ 15323717917d3bffd1417d7315efd68292be64b9 │ fix: storage upload + auth role sync                       │
 05cb6471-a1ce-4352-9521-1313fcd7edd5 │ 2026-01-06T15:20:00Z │ 1m15.186007s │ DEPLOYED │ doriansoftwareservices-ctrl │ 2cdb2ba321bbc31fc72b5a480a6d03c788fcac3a │ fix: enforce plan permissions for owners                   │
                                      │                      │              │          │                             │                                          │                                                            │
```

## Hasura export_metadata
Saved: server_snapshot_mergrgclboxflnucehgb_20260107_092314/hasura_export_metadata.json

## DB inventory
Saved:
- server_snapshot_mergrgclboxflnucehgb_20260107_092314/db_version.json
- server_snapshot_mergrgclboxflnucehgb_20260107_092314/db_objects.json
- server_snapshot_mergrgclboxflnucehgb_20260107_092314/db_functions.json
- server_snapshot_mergrgclboxflnucehgb_20260107_092314/db_policies.json

## GraphQL introspection
Saved: server_snapshot_mergrgclboxflnucehgb_20260107_092314/graphql_introspection.json

