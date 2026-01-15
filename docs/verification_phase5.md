# Phase 5 Verification Checklist

This checklist validates the critical flows after phases 1-4.
Execute on a staging environment with a fresh owner account when possible.

## 1) Owner Free -> Self Employee -> Doctor -> Services -> Patient
- Sign up a new owner account.
- Complete clinic profile (AR/EN + phone).
- Go to Employees -> Create Employee.
- Use "ربط حسابي" to link the owner user to the employee record.
- Go to Employees -> Doctors -> Add Doctor (use the linked employee).
- Go to Doctors Services -> Services -> add at least 1 service with price.
- Go to Patients -> New Patient and assign the owner/doctor.
- Verify doctor share and service details are saved and visible in patient view.

Expected:
- No permission errors in FREE plan for dashboard/patients/employees.
- Doctor appears in selection lists.
- Patient created with doctor/service data.

## 2) Upgrade Plan -> Proof -> Super Admin Approves -> Features Open
- Owner opens "My Plan" and submits upgrade with proof.
- In Super Admin dashboard, open subscription requests and approve the request.
- Owner refreshes app and verifies:
  - Current plan shows as active.
  - Paid features unlock in the drawer (payments, repository, etc.).

Expected:
- No "database query error" on create_subscription_request.
- Plan status changes to active and drawer shows paid tabs.

## 3) Plan Expiry -> Employees Signed Out
- Expire the plan (or set end_at in backend for testing).
- Sign in as an employee for that account.

Expected:
- Employee is signed out automatically.
- Message: "ناسف فالخطة الحالية للمرفق الصحي هي FREE يجب تجديد الاشتراك".

## 4) Complaints -> Admin Reply -> Red Badge -> Reply Text
- User submits a complaint from "الشكاوى والأعطال".
- Super Admin replies via admin dashboard (Reply action).
- User returns to main drawer.

Expected:
- Red badge appears on "الشكاوى والأعطال".
- Opening the complaint shows the reply text.

