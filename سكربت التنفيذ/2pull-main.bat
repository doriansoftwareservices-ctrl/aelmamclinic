@echo off
REM سحب وتحديث فرع main من GitHub

cd /d "C:\Users\zidan\AndroidStudioProjects\aelmamclinic\سكربت التنفيذ"

pwsh -NoExit -ExecutionPolicy Bypass -File ".\pull-sync-codex-aelmamclinic.ps1" -Branch "main"

pause
