# Server State Report (Nhost/Hasura)
- Subdomain: ``
- Region: `ap-southeast-1`
- Generated: `2025-12-26T15:05:30+03:00`

```
Verifying configuration...
Configuration is valid!
```

```
HASURA_GRAPHQL_ADMIN_SECRET
HASURA_GRAPHQL_JWT_SECRET
NHOST_WEBHOOK_SECRET
GRAFANA_ADMIN_PASSWORD
```

```
                                      │                      │              │          │                             │                                          │                                                                            │
 ID                                   │ Date                 │ Duration     │ Status   │ User                        │ Ref                                      │ Message                                                                    │
 4ed5d9a9-43e9-488a-90f4-ae688a162dec │ 2025-12-26T11:41:27Z │ 2m22.416954s │ DEPLOYED │ doriansoftwareservices-ctrl │ eca3d35c08bdd87f92a66f9cf455cb10bccbbef7 │ fix: drop admin RPCs before changing return types                          │
 3867a06d-92d7-450d-86ea-9fdaed2646f9 │ 2025-12-25T17:20:17Z │ 55.787311s   │ FAILED   │ doriansoftwareservices-ctrl │ a5dcbd7b8d8c7248861e2335a0373b107ebd358f │ fix: drop self_create_account before rpc return change                     │
 1a72c8de-2b71-49b0-a3ff-9951e80f2476 │ 2025-12-25T17:12:27Z │ 2m2.149522s  │ FAILED   │ doriansoftwareservices-ctrl │ efb6458f3144e7888cfe0fc53ed62af57ab00898 │ fix: rpc return types + chat views + metadata tracking                     │
 9cca8dad-4b5f-40fb-8f21-e210b67a47d7 │ 2025-12-25T16:42:57Z │ 1m8.086236s  │ DEPLOYED │ doriansoftwareservices-ctrl │ ddd002a08278e3a5d2794963d3a0672fed0db945 │ fix: auth flow hardening + free plan gating                                │
 234012a9-f1de-4ed2-ae8a-98801576b65b │ 2025-12-25T16:15:57Z │ 2m14.458811s │ DEPLOYED │ doriansoftwareservices-ctrl │ 441873d0c6b122bae99d2f133256a0dbbfdc4174 │ fix: auth flow hardening + free plan gating                                │
 83ee29a4-b394-45d0-b7e3-ac24897ce3c0 │ 2025-12-25T15:44:37Z │ 2m28.330572s │ DEPLOYED │ doriansoftwareservices-ctrl │ 6a81714674a75cec7d9b5c514199aed54d20ce44 │ fix: delay auto-create until session + allow anonymous self_create_account │
 4f933b6c-f6e9-41a1-a2b0-d421735dab71 │ 2025-12-25T14:55:47Z │ 1m9.169409s  │ DEPLOYED │ doriansoftwareservices-ctrl │ 403c63f50b669180e575792d3581d2d09567b4d7 │ fix: allow anonymous access to self_create_account mutation                │
 d600cd7b-536e-4aee-9c29-ae91a6f3dd26 │ 2025-12-25T14:45:07Z │ 1m13.241139s │ DEPLOYED │ doriansoftwareservices-ctrl │ 23740c4c657e9938fa439e254fd4122e7069fa9f │ fix: force self_create_account as VOLATILE for mutation_root               │
 1dd226f6-ad5e-4c8f-a014-3cafd636946e │ 2025-12-25T14:21:47Z │ 2m24.167s    │ DEPLOYED │ doriansoftwareservices-ctrl │ 807a784746168d5ba71c4091cfe12c32f8d83af7 │ fix: expose user functions to owner/employee/admin roles                   │
 7c978ba9-8334-4a7e-a40c-f0394ad0af27 │ 2025-12-25T13:50:57Z │ 1m19.142338s │ DEPLOYED │ doriansoftwareservices-ctrl │ 2d752c2744d58981fe5ab16beb95ef6f03323461 │ fix: recreate permissions view for allow_all column                        │
                                      │                      │              │          │                             │                                          │                                                                            │
```

**Latest ID:** `4ed5d9a9-43e9-488a-90f4-ae688a162dec`

```
2025-12-26T11:42:49Z Starting deployment
2025-12-26T11:42:49Z Cloning repo github.com/doriansoftwareservices-ctrl/aelmamclinic (#eca3d35)
2025-12-26T11:42:50Z Detected new config file
2025-12-26T11:43:21Z App's configuration has been updated
2025-12-26T11:43:21Z Applying database migrations
2025-12-26T11:43:25Z Database migrations applied successfully
2025-12-26T11:43:25Z Applying metadata
2025-12-26T11:43:31Z Metadata applied successfully
2025-12-26T11:43:31Z Deploying functions
2025-12-26T11:43:43Z Functions deployment completed
2025-12-26T11:43:43Z Reloading metadata
2025-12-26T11:43:49Z Deployment completed with status DEPLOYED
```

**SKIPPED**: لم يتم تحميل قيمة HASURA_GRAPHQL_ADMIN_SECRET (ملف .secrets غير موجود/فارغ).

نفّذ ثم أعد تشغيل السكربت:
```
nhost config pull --subdomain 
source .secrets
./nh_full_audit.sh 
```
