param(
    [string]$ProjectPath = "C:\Users\zidan\AndroidStudioProjects\aelmamclinic"
)

Write-Host "=== Push Local Changes to GitHub ===" -ForegroundColor Cyan

# 1) الانتقال لمجلد المشروع
Set-Location $ProjectPath
Write-Host "المسار الحالي: $(Get-Location)" -ForegroundColor Yellow

# 2) معرفة الفرع الحالي
$branch = (git rev-parse --abbrev-ref HEAD).Trim()
if (-not $branch) {
    Write-Host "تعذّر معرفة الفرع الحالي. تأكد أن هذا مجلد git." -ForegroundColor Red
    exit 1
}

Write-Host "الفرع الحالي: $branch" -ForegroundColor Green

# 3) التحقق من وجود تغييرات
$changes = git status --porcelain
if (-not $changes) {
    Write-Host "لا توجد تغييرات محلية لرفعها (العمل نظيف)." -ForegroundColor Yellow
    exit 0
}

Write-Host "`nالتغييرات الحالية:" -ForegroundColor Cyan
git status

# 4) طلب رسالة الـ commit
$commitMessage = Read-Host "`nاكتب رسالة الـ commit (أو اضغط Enter لاستخدام رسالة افتراضية)"
if ([string]::IsNullOrWhiteSpace($commitMessage)) {
    $commitMessage = "Local update on $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
}

# 5) git add + commit
Write-Host "`nإضافة كل الملفات المعدلة..." -ForegroundColor Green
git add .
if ($LASTEXITCODE -ne 0) {
    Write-Host "فشل git add ." -ForegroundColor Red
    exit 1
}

Write-Host "إنشاء commit بالرسالة: $commitMessage" -ForegroundColor Green
git commit -m "$commitMessage"
if ($LASTEXITCODE -ne 0) {
    Write-Host "فشل git commit. ربما لا توجد تغييرات بعد الـ add؟" -ForegroundColor Red
    exit 1
}

# 6) push إلى نفس الفرع على origin
Write-Host "`nدفع التغييرات إلى origin/$branch ..." -ForegroundColor Green
git push origin $branch
if ($LASTEXITCODE -ne 0) {
    Write-Host "فشل git push origin $branch" -ForegroundColor Red
    exit 1
}

Write-Host "`n✅ تم دفع كل التغييرات من الفرع '$branch' إلى GitHub بنجاح." -ForegroundColor Cyan
Write-Host "=== انتهى السكربت ==="
