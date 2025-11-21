@echo off
REM سحب فرع Codex ومزامنته محليًا

REM الانتقال إلى مجلد سكربت التنفيذ
cd /d "C:\Users\zidan\AndroidStudioProjects\aelmamclinic\سكربت التنفيذ"

REM تشغيل سكربت PowerShell عبر pwsh (PowerShell 7) مع مسار نسبي
pwsh -NoExit -ExecutionPolicy Bypass -File ".\pull-sync-codex-aelmamclinic.ps1" -Branch "codex/perform-comprehensive-project-review"

pause
