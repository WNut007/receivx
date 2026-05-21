# Test fixture: deliberately fails with exit code 1.
# Used by smoke-runner-selftest.ps1 to prove the aggregate runner catches failures.
# (Prefix _ keeps it out of the default battery; the runner discovers scripts by name.)

Write-Host "Fixture: about to fail intentionally..." -ForegroundColor Yellow
Write-Host "FAIL: this fixture always fails (exit 1) to test the runner." -ForegroundColor Red
exit 1
