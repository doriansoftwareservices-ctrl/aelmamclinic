@echo off
REM دفع التغييرات الحالية في الفرع الحالي إلى GitHub

cd /d "C:\Users\zidan\AndroidStudioProjects\aelmamclinic\سكربت التنفيذ"

pwsh -NoExit -ExecutionPolicy Bypass -File ".\push-sync-codex-aelmamclinic.ps1"

pause
