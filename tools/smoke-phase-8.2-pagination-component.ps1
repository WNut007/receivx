# Smoke: Phase 8.2 shared pagination component.
#
# Verifies:
#   1. JS module loads in Node + exposes mountPagination + helpers
#   2. pageWindow() produces correct tokens for representative states
#      (single page / few pages / many pages with ellipsis windowing)
#   3. buildPaginationHtml() emits the expected DOM (Prev / pages / Next,
#      active marker on current page, disabled at boundaries)
#   4. CSS file is served via /css/components/pagination.css
#   5. _Pagination.cshtml partial file exists and contains the
#      expected DOM contract (pagination-info, pagination-nav, etc.)
#
# 8.3 will exercise the Razor partial via a real /Reports?page=N hit.
# Here we just verify the file deploys and the JS module produces
# correct output — the visual integration test belongs to 8.3.

$ErrorActionPreference = 'Stop'
$base = 'http://localhost:5213'

function Step($n) { Write-Host "`n--- $n ---" -ForegroundColor Cyan }
function OK($m)   { Write-Host "PASS: $m" -ForegroundColor Green }
function Fail($m) { Write-Host "FAIL: $m" -ForegroundColor Red; exit 1 }

# ----------------------------------------------------------------------------
# 1-3. Node-driven JS module assertions
# ----------------------------------------------------------------------------
Step "JS module: pageWindow + buildPaginationHtml produce correct output"
$nodeScript = @'
const p = require("C:/dev/receivx/src/ReceivingOps.Web/wwwroot/js/components/pagination.js");
const fails = [];

// pageWindow: single page → just [1]
const w1 = p.pageWindow(1, 1, 7);
if (JSON.stringify(w1) !== "[1]") fails.push("pageWindow(1,1,7) expected [1], got " + JSON.stringify(w1));

// pageWindow: few pages, no ellipsis (totalPages <= maxButtons)
const w2 = p.pageWindow(3, 5, 7);
if (JSON.stringify(w2) !== "[1,2,3,4,5]") fails.push("pageWindow(3,5,7) expected [1..5], got " + JSON.stringify(w2));

// pageWindow: many pages, current in middle → 1, ..., cur-1, cur, cur+1, ..., N
const w3 = p.pageWindow(50, 100, 7);
if (JSON.stringify(w3) !== '[1,"ellipsis",49,50,51,"ellipsis",100]')
    fails.push("pageWindow(50,100,7) expected [1,…,49,50,51,…,100], got " + JSON.stringify(w3));

// pageWindow: current at start (page 2 of 100)
const w4 = p.pageWindow(2, 100, 7);
if (JSON.stringify(w4) !== '[1,2,3,"ellipsis",100]')
    fails.push("pageWindow(2,100,7) expected [1,2,3,…,100], got " + JSON.stringify(w4));

// pageWindow: current at end (page 99 of 100)
const w5 = p.pageWindow(99, 100, 7);
if (JSON.stringify(w5) !== '[1,"ellipsis",98,99,100]')
    fails.push("pageWindow(99,100,7) expected [1,…,98,99,100], got " + JSON.stringify(w5));

// totalPagesOf
if (p.totalPagesOf(0, 50) !== 0)   fails.push("totalPagesOf(0,50) should be 0");
if (p.totalPagesOf(1, 50) !== 1)   fails.push("totalPagesOf(1,50) should be 1");
if (p.totalPagesOf(50, 50) !== 1)  fails.push("totalPagesOf(50,50) should be 1");
if (p.totalPagesOf(51, 50) !== 2)  fails.push("totalPagesOf(51,50) should be 2");
if (p.totalPagesOf(155, 50) !== 4) fails.push("totalPagesOf(155,50) should be 4");

// buildPaginationHtml: page 1 of 3 (boundary: Prev disabled, Next enabled)
const html1 = p.buildPaginationHtml({ page: 1, total: 150, pageSize: 50, totalPages: 3, label: "records" });
if (!html1.includes("Page <b>1</b> of <b>3</b>"))     fails.push("p1of3 missing 'Page 1 of 3' caption");
if (!html1.includes('class="pagination-btn prev" data-page="0"  disabled')
 && !html1.includes('class="pagination-btn prev" data-page="0" disabled'))
    fails.push("p1of3 Prev should be disabled");
if (!html1.includes('class="pagination-btn next" data-page="2"'))  fails.push("p1of3 Next should target page 2");
if (!html1.includes('class="pagination-btn active" data-page="1"')) fails.push("p1of3 active button missing for page 1");
if (!html1.includes("<b>150</b> records")) fails.push("p1of3 total surface missing");

// buildPaginationHtml: middle page (page 5 of 10) — both Prev + Next enabled
const html2 = p.buildPaginationHtml({ page: 5, total: 500, pageSize: 50, totalPages: 10 });
if (!html2.includes('class="pagination-btn active" data-page="5"')) fails.push("p5of10 active button missing for page 5");
if (html2.match(/class="pagination-btn prev" data-page="4"\s+disabled/)) fails.push("p5of10 Prev should NOT be disabled");
if (html2.match(/class="pagination-btn next" data-page="6"\s+disabled/)) fails.push("p5of10 Next should NOT be disabled");

// buildPaginationHtml: many pages with ellipsis (page 50 of 100)
const html3 = p.buildPaginationHtml({ page: 50, total: 5000, pageSize: 50, totalPages: 100 });
if (!html3.includes("pagination-ellipsis")) fails.push("p50of100 should contain ellipsis spans");
const ellipsisCount = (html3.match(/pagination-ellipsis/g) || []).length;
if (ellipsisCount !== 2) fails.push("p50of100 expected 2 ellipsis (one each side), got " + ellipsisCount);

if (fails.length) { console.log("FAIL"); fails.forEach(f => console.log("  - " + f)); process.exit(1); }
console.log("OK 5 pageWindow shapes + 5 totalPagesOf cases + 3 buildPaginationHtml states");
'@
$nodeScript | Out-File -FilePath "$env:TEMP\smoke-pagination.js" -Encoding utf8
$nodeOut = node "$env:TEMP\smoke-pagination.js" 2>&1
Remove-Item "$env:TEMP\smoke-pagination.js" -Force -ErrorAction SilentlyContinue
if ($LASTEXITCODE -ne 0) {
    Write-Host $nodeOut -ForegroundColor Red
    Fail "JS module assertions failed (see above)"
}
OK ($nodeOut | Out-String).Trim()

# ----------------------------------------------------------------------------
# 4. CSS file is served
# ----------------------------------------------------------------------------
$loginBody = @{ username='sadmin'; password='admin'; warehouseId='22222222-2222-2222-2222-000000000001'; remember=$false } | ConvertTo-Json
$sv = $null
Invoke-RestMethod -Uri "$base/api/auth/login" -Method POST -Body $loginBody -ContentType 'application/json' -SessionVariable sv | Out-Null

Step "GET /css/components/pagination.css → 200 + key selectors"
$css = Invoke-WebRequest -Uri "$base/css/components/pagination.css" -WebSession $sv -UseBasicParsing
if ($css.StatusCode -ne 200) { Fail "pagination.css returned $($css.StatusCode)" }
foreach ($sel in '.pagination', '.pagination-info', '.pagination-nav', '.pagination-btn', '.pagination-btn.active', '.pagination-ellipsis') {
    if ($css.Content -notmatch [regex]::Escape($sel)) { Fail "pagination.css missing selector $sel" }
}
OK "pagination.css served ($($css.RawContentLength) bytes) with all key selectors"

Step "GET /js/components/pagination.js → 200 + exports mountPagination"
$js = Invoke-WebRequest -Uri "$base/js/components/pagination.js" -WebSession $sv -UseBasicParsing
if ($js.StatusCode -ne 200) { Fail "pagination.js returned $($js.StatusCode)" }
foreach ($needle in 'mountPagination', 'buildPaginationHtml', 'pageWindow') {
    if ($js.Content -notmatch [regex]::Escape($needle)) { Fail "pagination.js missing $needle" }
}
OK "pagination.js served ($($js.RawContentLength) bytes) with mountPagination + helpers"

# ----------------------------------------------------------------------------
# 5. Razor partial file deploys correctly
# ----------------------------------------------------------------------------
Step "_Pagination.cshtml partial file exists with expected contract"
$partial = Get-Content 'C:\dev\receivx\src\ReceivingOps.Web\Views\Shared\_Pagination.cshtml' -Raw
foreach ($needle in 'PaginationPartialModel', 'pagination-info', 'pagination-nav', 'pagination-btn', 'pagination-ellipsis', 'BaseQuery', 'aria-current') {
    if ($partial -notmatch [regex]::Escape($needle)) { Fail "_Pagination.cshtml missing $needle" }
}
OK "_Pagination.cshtml exists with full DOM contract"

Write-Host ""
Write-Host "ALL PASS — Phase 8.2 shared pagination component." -ForegroundColor Green
exit 0
