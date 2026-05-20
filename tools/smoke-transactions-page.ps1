# Smoke: Transactions page serves with new JS wired to API.
$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }

$body = @{ username='sadmin'; password='admin'; warehouseId='22222222-2222-2222-2222-000000000001'; remember=$false } | ConvertTo-Json
$sess = $null
Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $body -ContentType 'application/json' -SessionVariable sess | Out-Null

Step "GET /Transactions returns the mockup-ported view"
$page = Invoke-WebRequest -Uri "$base/Transactions" -WebSession $sess
if ($page.StatusCode -ne 200) { Fail "Got $($page.StatusCode)" }
foreach ($needle in @(
    'data-app-page="transactions"',
    '/css/transactions.css',
    '/js/transactions.js',
    'id="f-search"',
    'id="tx-tbody"',
    'id="cancelModal"'
)) {
    if ($page.Content -notmatch [regex]::Escape($needle)) { Fail "Missing '$needle'" }
}
OK "Page renders with all mockup landmarks"

Step "GET /js/transactions.js — no seed, has API wiring"
$js = (Invoke-WebRequest -Uri "$base/js/transactions.js" -WebSession $sess).Content
# Seed removed
foreach ($needle in @("'ops.receipts'", "function seedReceipts", "'r-1001'", "STORE.save")) {
    if ($js -match [regex]::Escape($needle)) { Fail "Stage B JS still contains '$needle'" }
}
# API wiring present
foreach ($needle in @("/api/transactions", "/api/receipts/", "loadData", "buildQueryString", "currentRows", "receivedByName")) {
    if ($js -notmatch [regex]::Escape($needle)) { Fail "Missing landmark '$needle'" }
}
OK "Seed removed, API wiring present"

Step "node --check on transactions.js"
$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) {
    $tmp = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "tx-check-$([guid]::NewGuid().ToString('N')).js")
    Set-Content -LiteralPath $tmp -Value $js -Encoding utf8
    $check = & node --check $tmp 2>&1
    Remove-Item $tmp -Force
    if ($LASTEXITCODE -ne 0) { Write-Host $check -ForegroundColor Red; Fail "syntax error" }
    OK "node --check clean"
} else {
    Write-Host "SKIP: node not on PATH" -ForegroundColor Yellow
}

Write-Host "`nTransactions page smoke passed." -ForegroundColor Green
