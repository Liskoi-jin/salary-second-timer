# API smoke test for the /api/share endpoints. Uses $PSScriptRoot-free logic
# and talks to the running server on localhost:8765.
$base = 'http://localhost:8765'
$results = @()

function Step($name){ Write-Host ""; Write-Host ("=== " + $name + " ===") }

# 1) Create a token: no password, 1h expiry, maxAccess=2
Step "Test 1: POST /api/share (create token, no pwd, 1h, maxAccess=2)"
$body = '{"payload":"PHRlc3Q+","password":null,"expiresInHours":1,"maxAccess":2,"label":"api-smoke"}'
try {
  $r = Invoke-RestMethod -Method POST -Uri ($base + '/api/share') -Body $body -ContentType 'application/json' -TimeoutSec 10
  $tok = $r.token
  Write-Host ("  token = " + $tok)
  $results += 'T1-create:OK'
} catch {
  Write-Host ("  FAIL: " + $_.Exception.Message)
  $results += 'T1-create:FAIL'
  return
}

# 2) GET #1 -> payload
Step "Test 2: GET /api/share/<tok> (1st access -> payload)"
try {
  $r2 = Invoke-RestMethod -Method GET -Uri ($base + '/api/share/' + $tok) -TimeoutSec 10
  Write-Host ("  payload = " + $r2.payload)
  $results += 'T2-get1:OK'
} catch {
  Write-Host ("  FAIL: " + $_.Exception.Message)
  $results += 'T2-get1:FAIL'
}

# 3) GET #2 -> payload (hits maxAccess)
Step "Test 3: GET /api/share/<tok> (2nd access -> payload)"
try {
  $r3 = Invoke-RestMethod -Method GET -Uri ($base + '/api/share/' + $tok) -TimeoutSec 10
  Write-Host ("  payload = " + $r3.payload)
  $results += 'T3-get2:OK'
} catch {
  Write-Host ("  FAIL: " + $_.Exception.Message)
  $results += 'T3-get2:FAIL'
}

# 4) GET #3 -> 403 max-access
Step "Test 4: GET /api/share/<tok> (3rd access -> expect 403 max-access)"
try {
  Invoke-RestMethod -Method GET -Uri ($base + '/api/share/' + $tok) -TimeoutSec 10 | Out-Null
  Write-Host "  FAIL: expected an error but request succeeded"
  $results += 'T4-maxaccess:FAIL'
} catch {
  $code = $null
  try { $code = [int]$_.Exception.Response.StatusCode } catch {}
  Write-Host ("  status = " + $code + " (expected 403)")
  if ($code -eq 403) { $results += 'T4-maxaccess:OK' } else { $results += 'T4-maxaccess:FAIL' }
}

# 5) Create a password-protected token and verify needPassword flow
Step "Test 5: POST /api/share (create password token)"
$body2 = '{"payload":"PHNlY3JldD4=","password":"hunter2","expiresInHours":0,"maxAccess":0,"label":"pwd-test"}'
try {
  $r5 = Invoke-RestMethod -Method POST -Uri ($base + '/api/share') -Body $body2 -ContentType 'application/json' -TimeoutSec 10
  $tok2 = $r5.token
  Write-Host ("  token = " + $tok2)
  $results += 'T5-createpwd:OK'
} catch {
  Write-Host ("  FAIL: " + $_.Exception.Message)
  $results += 'T5-createpwd:FAIL'
  return
}

Step "Test 6: GET pwd token -> expect needPassword=true"
try {
  $r6 = Invoke-RestMethod -Method GET -Uri ($base + '/api/share/' + $tok2) -TimeoutSec 10
  Write-Host ("  needPassword = " + $r6.needPassword)
  if ($r6.needPassword -eq $true) { $results += 'T6-needpwd:OK' } else { $results += 'T6-needpwd:FAIL' }
} catch {
  Write-Host ("  FAIL: " + $_.Exception.Message)
  $results += 'T6-needpwd:FAIL'
}

Step "Test 7: POST pwd token wrong password -> expect 403"
try {
  $bad = '{"password":"nope"}'
  Invoke-RestMethod -Method POST -Uri ($base + '/api/share/' + $tok2) -Body $bad -ContentType 'application/json' -TimeoutSec 10 | Out-Null
  Write-Host "  FAIL: expected 403 but request succeeded"
  $results += 'T7-wrongpwd:FAIL'
} catch {
  $code = $null
  try { $code = [int]$_.Exception.Response.StatusCode } catch {}
  Write-Host ("  status = " + $code + " (expected 403)")
  if ($code -eq 403) { $results += 'T7-wrongpwd:OK' } else { $results += 'T7-wrongpwd:FAIL' }
}

Step "Test 8: POST pwd token correct password -> expect payload"
try {
  $good = '{"password":"hunter2"}'
  $r8 = Invoke-RestMethod -Method POST -Uri ($base + '/api/share/' + $tok2) -Body $good -ContentType 'application/json' -TimeoutSec 10
  Write-Host ("  payload = " + $r8.payload)
  $results += 'T8-rightpwd:OK'
} catch {
  Write-Host ("  FAIL: " + $_.Exception.Message)
  $results += 'T8-rightpwd:FAIL'
}

# 9) Revoke a token and verify GET returns 403 revoked
Step "Test 9: DELETE /api/share/<tok2> (revoke) then GET -> 403 revoked"
try {
  $r9 = Invoke-RestMethod -Method DELETE -Uri ($base + '/api/share/' + $tok2) -TimeoutSec 10
  Write-Host ("  deleted ok = " + $r9.ok)
  try {
    Invoke-RestMethod -Method GET -Uri ($base + '/api/share/' + $tok2) -TimeoutSec 10 | Out-Null
    Write-Host "  FAIL: revoked token still accessible"
    $results += 'T9-revoke:FAIL'
  } catch {
    $code = $null
    try { $code = [int]$_.Exception.Response.StatusCode } catch {}
    Write-Host ("  status after revoke = " + $code + " (expected 403)")
    if ($code -eq 403) { $results += 'T9-revoke:OK' } else { $results += 'T9-revoke:FAIL' }
  }
} catch {
  Write-Host ("  FAIL: " + $_.Exception.Message)
  $results += 'T9-revoke:FAIL'
}

# 10) Unknown token -> 404
Step "Test 10: GET unknown token -> expect 404"
try {
  Invoke-RestMethod -Method GET -Uri ($base + '/api/share/doesnotexist12345') -TimeoutSec 10 | Out-Null
  Write-Host "  FAIL: expected 404 but request succeeded"
  $results += 'T10-notfound:FAIL'
} catch {
  $code = $null
  try { $code = [int]$_.Exception.Response.StatusCode } catch {}
  Write-Host ("  status = " + $code + " (expected 404)")
  if ($code -eq 404) { $results += 'T10-notfound:OK' } else { $results += 'T10-notfound:FAIL' }
}

# 11) Static file still served (root -> index.html)
Step "Test 11: GET / -> should return HTML (static serving still works)"
try {
  $resp = Invoke-WebRequest -Uri ($base + '/') -TimeoutSec 10 -UseBasicParsing
  $isHtml = $resp.Content -match '<html'
  Write-Host ("  status = " + $resp.StatusCode + " isHtml = " + $isHtml)
  if ($resp.StatusCode -eq 200 -and $isHtml) { $results += 'T11-static:OK' } else { $results += 'T11-static:FAIL' }
} catch {
  Write-Host ("  FAIL: " + $_.Exception.Message)
  $results += 'T11-static:FAIL'
}

Write-Host ""
Write-Host "================================================"
Write-Host "  SUMMARY"
Write-Host "================================================"
foreach($r in $results){ Write-Host ("  " + $r) }
$ok = ($results | Where-Object { $_ -like '*:OK' }).Count
$fail = ($results | Where-Object { $_ -like '*:FAIL' }).Count
Write-Host ("  PASS = " + $ok + "  FAIL = " + $fail)
Write-Host "================================================"
