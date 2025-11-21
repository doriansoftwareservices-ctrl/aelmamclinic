# setup_supabase_once.ps1
# يضع config.json للويندوز ويدفعه لكل أجهزة/محاكيات أندرويد المتصلة عبر ADB.
# ملاحظة أمنية: لا تضع service_role في هذا الملف أو داخل التطبيق.

param(
  [string]$Url  = "https://kdcgpgcyxpameowcopqb.supabase.co",
  [string]$Anon = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImtkY2dwZ2N5eHBhbWVvd2NvcHFiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjM3NTA5NzMsImV4cCI6MjA3OTMyNjk3M30.saqQliOC2jTPu1G3MN16XznL4J-Efrw2CSdUEWMKSzE"
)

$ErrorActionPreference = "Stop"

# محتوى config.json
$json = "{`"supabaseUrl`":`"$Url`",`"supabaseAnonKey`":`"$Anon`"}"

# 1) ويندوز: C:\aelmam_clinic\config.json
$winDir = "C:\aelmam_clinic"
New-Item -ItemType Directory -Force -Path $winDir | Out-Null
Set-Content -Path "$winDir\config.json" -Value $json -Encoding UTF8

# 2) أندرويد: /sdcard/Android/data/com.aelmam.clinic/files/config.json
# يحتاج ADB وجهاز/محاكي متصل
& adb start-server | Out-Null
$devices = (& adb devices) -split "`n" | Where-Object {$_ -match "device`$"} | ForEach-Object { ($_ -split "`t")[0] }

foreach($d in $devices){
  & adb -s $d shell "mkdir -p /sdcard/Android/data/com.aelmam.clinic/files" | Out-Null
  & adb -s $d push "$winDir\config.json" "/sdcard/Android/data/com.aelmam.clinic/files/config.json" | Out-Null
}

Write-Host "Supabase config:"
Write-Host "  Windows -> $winDir\config.json"
if($devices.Count -gt 0){ Write-Host "  Android -> pushed to $($devices.Count) device(s)" } else { Write-Host "  Android -> no device connected" }
