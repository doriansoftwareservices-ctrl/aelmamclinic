# Phase 3 Auto-Create Guard (Owner Only)

## Goal
Prevent automatic clinic creation for employees (or any user) who signs in without a linked account. Auto-create should be explicit in the owner onboarding flow only.

## Changes Applied
- Removed automatic self-create on sign-in from the login flow.
- Removed silent fallback auto-create when clinic name is missing during sign-up.
- Added an explicit guard in AuthProvider to block auto-create unless enabled intentionally.

## Updated Behavior
- **Sign-in (existing user)**: If no account is linked, the app now shows the “no account” message and does **not** create a clinic.
- **Sign-up (owner onboarding)**: Clinic creation only occurs when the user provides a clinic name.

## Files Modified
- `lib/providers/auth_provider.dart`
- `lib/screens/auth/login_screen.dart`

## Notes
- `AuthProvider.allowAutoCreateAccountOnce()` is available for future explicit flows, but is not used by default.
