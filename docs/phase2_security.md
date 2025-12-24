Phase 2 Security Execution

Goal
- Remove all Nhost secrets from client-side configuration and runtime overrides.
- Ensure only public endpoints and super admin email list are loaded at runtime.
- Prepare for secret rotation on the server side without impacting clients.

Changes Applied
- Removed admin/webhook/jwt secrets from runtime overrides and public config.
- Removed admin secret logging from startup diagnostics.
- Updated README to clarify that client config must not include secrets.

Files Updated
- lib/core/nhost_config.dart
- lib/core/constants.dart
- lib/core/constants_nhost_override_loader_io.dart
- lib/core/constants_nhost_override_loader_stub.dart
- lib/main.dart
- README.md
- config.example.json
- config.json

Operational Follow-ups (Server-Side)
- Rotate Nhost admin/webhook/jwt secrets in the Nhost dashboard.
- Update server-side .secrets for CLI deployment only.
- Verify no client build embeds these secrets in --dart-define arguments.
