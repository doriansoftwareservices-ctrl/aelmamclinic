param(
    [Parameter(Mandatory = $true)]
    [string]$Branch
)

# مسار مشروعك
$projectPath = "C:\Users\zidan\AndroidStudioProjects\aelmamclinic"

Write-Host "=== Codex Sync Script for aelmamclinic ===" -ForegroundColor Cyan
Write-Host "الفرع المطلوب: $Branch"
Write-Host ""

# 1) الدخول إلى المشروع
Set-Location $projectPath
Write-Host "المسار الحالي: $(Get-Location)" -ForegroundColor Yellow

# 2) جلب آخر التغييرات من GitHub
Write-Host "`n[1/5] git fetch origin" -ForegroundColor Green
git fetch origin
if ($LASTEXITCODE -ne 0) {
    Write-Host "فشل git fetch. أوقف السكربت." -ForegroundColor Red
    exit 1
}

# 3) التأكد أن الفرع موجود على origin
Write-Host "`n[2/5] التحقق من وجود origin/$Branch" -ForegroundColor Green
git show-ref --verify --quiet "refs/remotes/origin/$Branch"
if ($LASTEXITCODE -ne 0) {
    Write-Host "لا يوجد فرع باسم origin/$Branch على GitHub." -ForegroundColor Red
    exit 1
}

# 4) إنشاء/تحديث الفرع المحلي من فرع Codex
Write-Host "`n[3/5] git checkout -B $Branch origin/$Branch" -ForegroundColor Green
git checkout -B $Branch "origin/$Branch"
if ($LASTEXITCODE -ne 0) {
    Write-Host "فشل الانتقال إلى الفرع $Branch." -ForegroundColor Red
    exit 1
}

# 5) أوامر Flutter
Write-Host "`n[4/5] flutter pub get" -ForegroundColor Green
flutter pub get
if ($LASTEXITCODE -ne 0) {
    Write-Host "فشل flutter pub get. أوقف السكربت." -ForegroundColor Red
    exit 1
}

Write-Host "`nflutter analyze" -ForegroundColor Green
flutter analyze
if ($LASTEXITCODE -ne 0) {
    Write-Host "تحذير: flutter analyze رجّع أخطاء أو تحذيرات." -ForegroundColor Red
    # لا نخرج مباشرة، نكمل إلى الاختبارات
}

Write-Host "`nflutter test" -ForegroundColor Green
flutter test
if ($LASTEXITCODE -ne 0) {
    Write-Host "تحذير: flutter test رجّع فشل في الاختبارات." -ForegroundColor Red
    # نكمل ونعطيك خيار الدمج أو لا
}

Write-Host "`n[5/5] الفحص انتهى على الفرع $Branch." -ForegroundColor Cyan

# سؤال الدمج في main
$answer = Read-Host "`nهل تريد دمج الفرع $Branch في main ثم push إلى GitHub؟ (y/n)"
if ($answer -eq "y") {
    Write-Host "`nالانتقال إلى main..." -ForegroundColor Green
    git checkout main
    if ($LASTEXITCODE -ne 0) {
        Write-Host "فشل git checkout main. أوقف السكربت." -ForegroundColor Red
        exit 1
    }

    Write-Host "دمج $Branch في main..." -ForegroundColor Green
    git merge $Branch
    if ($LASTEXITCODE -ne 0) {
        Write-Host "فشل الدمج. راجع التعارضات (conflicts) يدويًا." -ForegroundColor Red
        exit 1
    }

    Write-Host "إرسال التغييرات إلى GitHub: git push origin main" -ForegroundColor Green
    git push origin main
    if ($LASTEXITCODE -ne 0) {
        Write-Host "فشل git push origin main." -ForegroundColor Red
        exit 1
    }

    Write-Host "`n✅ تم دمج الفرع $Branch في main وتم دفعه إلى GitHub بنجاح." -ForegroundColor Cyan
} else {
    Write-Host "`nلم يتم الدمج. ما زلت على الفرع $Branch بملفات Codex على جهازك." -ForegroundColor Yellow
}

Write-Host "`n=== انتهى السكربت ===" -ForegroundColor Cyan
