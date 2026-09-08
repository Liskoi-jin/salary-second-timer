# ===== Salary Timer Network Deployment Service =====
# Uses TcpListener on 0.0.0.0:8765. Binding a high port does NOT need admin
# (unlike HttpListener URL ACL). Serves static files so other LAN computers
# can reach the app via http://<this-PC-IP>:8765/
# Usage: double-click "start-server.bat" OR:
#   powershell -ExecutionPolicy Bypass -File serve.ps1

$ErrorActionPreference = 'Stop'
$Port = 8765
$Root = $PSScriptRoot
if(-not $Root){ $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$IndexFile = Join-Path $Root 'index.html'

if(-not (Test-Path $IndexFile)){
  Write-Host "[ERROR] index.html not found: $IndexFile" -ForegroundColor Red
  exit 1
}

function Get-LanIPs {
  $ips = @()
  try {
    $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
      Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -notlike '192.168.56.*' } |
      Select-Object -ExpandProperty IPAddress
  } catch {
    $ips = [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
      Where-Object { $_.AddressFamily -eq 'InterNetwork' -and $_.ToString() -notlike '127.*' } |
      Select-Object -ExpandProperty IPAddress
  }
  return $ips
}

function Try-AddFirewallRule {
  $ruleName = 'SalaryTimer Web 8765'
  try {
    $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    if(-not $existing){
      New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow `
        -Protocol TCP -LocalPort $Port -Profile Any -ErrorAction Stop | Out-Null
      Write-Host "[Firewall] Inbound rule added: other PCs can now reach port $Port" -ForegroundColor Green
    } else {
      Write-Host "[Firewall] Inbound rule already exists." -ForegroundColor DarkGray
    }
    return $true
  } catch {
    Write-Host "[Firewall] Could not auto-add rule (needs admin)." -ForegroundColor Yellow
    Write-Host "          If other PCs cannot connect, run this ONCE as admin:" -ForegroundColor Yellow
    Write-Host "          New-NetFirewallRule -DisplayName '$ruleName' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -Profile Any" -ForegroundColor Yellow
    return $false
  }
}

function Get-Mime($ext){
  switch($ext.ToLower()){
    '.html' { 'text/html; charset=utf-8' }
    '.htm'  { 'text/html; charset=utf-8' }
    '.css'  { 'text/css; charset=utf-8' }
    '.js'   { 'application/javascript; charset=utf-8' }
    '.json' { 'application/json; charset=utf-8' }
    '.png'  { 'image/png' }
    '.jpg'  { 'image/jpeg' }
    '.jpeg' { 'image/jpeg' }
    '.gif'  { 'image/gif' }
    '.svg'  { 'image/svg+xml' }
    '.ico'  { 'image/x-icon' }
    '.txt'  { 'text/plain; charset=utf-8' }
    '.md'   { 'text/plain; charset=utf-8' }
    default { 'application/octet-stream' }
  }
}

function Send-File($stream, $absPath, $mime){
  $bytes = [System.IO.File]::ReadAllBytes($absPath)
  $header = "HTTP/1.1 200 OK`r`nContent-Type: $mime`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`nCache-Control: no-cache`r`n`r`n"
  $hb = [System.Text.Encoding]::UTF8.GetBytes($header)
  $stream.Write($hb, 0, $hb.Length)
  $stream.Write($bytes, 0, $bytes.Length)
}
function Send-404($stream){
  $body = [System.Text.Encoding]::UTF8.GetBytes('404 Not Found')
  $header = "HTTP/1.1 404 Not Found`r`nContent-Type: text/plain; charset=utf-8`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n"
  $hb = [System.Text.Encoding]::UTF8.GetBytes($header)
  $stream.Write($hb, 0, $hb.Length)
  $stream.Write($body, 0, $body.Length)
}
function Send-500($stream, $msg){
  $body = [System.Text.Encoding]::UTF8.GetBytes('500 Server Error: ' + $msg)
  $header = "HTTP/1.1 500 Internal Server Error`r`nContent-Type: text/plain; charset=utf-8`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n"
  $hb = [System.Text.Encoding]::UTF8.GetBytes($header)
  $stream.Write($hb, 0, $hb.Length)
  $stream.Write($body, 0, $body.Length)
}
function Send-Json($stream, $obj, $status=200){
  $json = ConvertTo-Json $obj -Compress -Depth 8
  $body = [System.Text.Encoding]::UTF8.GetBytes($json)
  $header = "HTTP/1.1 $status OK`r`nContent-Type: application/json; charset=utf-8`r`nContent-Length: $($body.Length)`r`nConnection: close`r`nAccess-Control-Allow-Origin: *`r`nAccess-Control-Allow-Methods: GET,POST,DELETE,OPTIONS`r`n`r`n"
  $hb = [System.Text.Encoding]::UTF8.GetBytes($header)
  $stream.Write($hb, 0, $hb.Length)
  $stream.Write($body, 0, $body.Length)
}
# Random hex string (for token id / salt)
function New-RandomHex($len=16){
  $bytes = New-Object byte[] $len
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  $rng.GetBytes($bytes); $rng.Dispose()
  return ($bytes | ForEach-Object { $_.ToString('x2') }) -join ''
}
function Get-Sha256Hex($text){
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try{
    $buf = [System.Text.Encoding]::UTF8.GetBytes($text)
    $hash = $sha.ComputeHash($buf)
    return ($hash | ForEach-Object { $_.ToString('x2') }) -join ''
  } finally { $sha.Dispose() }
}
# Current Unix timestamp (seconds)
function Get-UnixNow(){ return [DateTimeOffset]::Now.ToUnixTimeSeconds() }
# Token store (JSON file; single-threaded server needs no lock)
$TokensFile = Join-Path $Root 'share-tokens.json'
function Load-Tokens{
  try{
    if(Test-Path $TokensFile){ return Get-Content $TokensFile -Raw -Encoding UTF8 | ConvertFrom-Json }
  }catch{}
  return [PSCustomObject]@{}
}
function Save-Tokens($obj){
  $obj | ConvertTo-Json -Depth 8 | Set-Content $TokensFile -Encoding UTF8
}
# Validate a token record; return @{error;status} on failure or $null if OK
function Test-Token($rec){
  if(-not $rec){ return @{error='not-found'; status=404} }
  if($rec.revoked){ return @{error='revoked'; status=403} }
  if([int]$rec.expiresAt -gt 0 -and (Get-UnixNow) -gt [int]$rec.expiresAt){ return @{error='expired'; status=403} }
  if([int]$rec.maxAccess -gt 0 -and [int]$rec.accessCount -ge [int]$rec.maxAccess){ return @{error='max-access'; status=403} }
  return $null
}
# /api/share router
function Handle-ShareApi($stream, $method, $rel, $body){
  # CORS preflight
  if($method -eq 'OPTIONS'){ Send-Json $stream @{} ; return }
  $tokens = Load-Tokens
  # POST /api/share -> create token
  if($method -eq 'POST' -and ($rel -eq '/api/share' -or $rel -eq '/api/share/')){
    try{
      $req = $body | ConvertFrom-Json
      $token = New-RandomHex 24
      $salt = New-RandomHex 16
      $pwdHash = $null
      if($req.password){ $pwdHash = Get-Sha256Hex ($salt + [string]$req.password) }
      $expiresAt = 0
      if($req.expiresInHours -and [int]$req.expiresInHours -gt 0){
        $expiresAt = (Get-UnixNow) + ([int]$req.expiresInHours * 3600)
      }
      $maxAccess = 0
      if($req.maxAccess){ $maxAccess = [int]$req.maxAccess }
      $now = Get-UnixNow
      $rec = [PSCustomObject]@{
        payload    = [string]$req.payload
        salt       = $salt
        pwdHash    = $pwdHash
        createdAt  = $now
        expiresAt  = $expiresAt
        maxAccess  = $maxAccess
        accessCount= 0
        revoked    = $false
        label      = [string]($req.label)
      }
      $tokens | Add-Member -NotePropertyName $token -NotePropertyValue $rec -Force
      Save-Tokens $tokens
      Send-Json $stream @{ token = $token }
    }catch{ Send-Json $stream @{ error = 'bad-request' } 400 }
    return
  }
  # /api/share/<token> path
  $m = [regex]::Match($rel, '^/api/share/([^/]+)$')
  if(-not $m.Success){ Send-Json $stream @{ error='not-found' } 404; return }
  $token = $m.Groups[1].Value
  $rec = $null
  if($tokens.PSObject.Properties.Name -contains $token){ $rec = $tokens.$token }
  # DELETE -> revoke (idempotent)
  if($method -eq 'DELETE'){
    if($rec){ $rec.revoked = $true; Save-Tokens $tokens }
    Send-Json $stream @{ ok = $true }
    return
  }
  # GET -> read (validate then return payload or needPassword)
  if($method -eq 'GET'){
    $st = Test-Token $rec
    if($st){ Send-Json $stream @{ error=$st.error } $st.status; return }
    if($rec.pwdHash){ Send-Json $stream @{ needPassword=$true }; return }
    $rec.accessCount = [int]$rec.accessCount + 1
    Save-Tokens $tokens
    Send-Json $stream @{ payload = $rec.payload }
    return
  }
  # POST /api/share/<token> -> password check
  if($method -eq 'POST'){
    $st = Test-Token $rec
    if($st){ Send-Json $stream @{ error=$st.error } $st.status; return }
    if(-not $rec.pwdHash){ $rec.accessCount = [int]$rec.accessCount + 1; Save-Tokens $tokens; Send-Json $stream @{ payload=$rec.payload }; return }
    try{
      $req = $body | ConvertFrom-Json
      $h = Get-Sha256Hex ($rec.salt + [string]$req.password)
      if($h -eq $rec.pwdHash){
        $rec.accessCount = [int]$rec.accessCount + 1; Save-Tokens $tokens
        Send-Json $stream @{ payload = $rec.payload }
      } else { Send-Json $stream @{ error='wrong-password' } 403 }
    }catch{ Send-Json $stream @{ error='bad-request' } 400 }
    return
  }
  Send-Json $stream @{ error='method-not-allowed' } 405
}

Try-AddFirewallRule | Out-Null

$lanIPs = Get-LanIPs
Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  Salary Timer - Network Service Ready" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  Local:    http://localhost:$Port/" -ForegroundColor White
foreach($ip in $lanIPs){
  Write-Host "  LAN:      http://${ip}:$Port/" -ForegroundColor Green
}
Write-Host "------------------------------------------------" -ForegroundColor DarkGray
Write-Host "  Open the GREEN address from any PC on the same" -ForegroundColor DarkGray
Write-Host "  Wi-Fi/LAN. Keep this window open to keep running." -ForegroundColor DarkGray
Write-Host "  Press Ctrl+C to stop." -ForegroundColor DarkGray
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $Port)
try {
  $listener.Start()
} catch {
  Write-Host "[ERROR] Cannot listen on port $Port (maybe in use): $($_.Exception.Message)" -ForegroundColor Red
  exit 1
}
Write-Host "[Service] Listening on 0.0.0.0:$Port ..." -ForegroundColor DarkGray

$fullRoot = (Resolve-Path $Root).Path

try {
  while($true){
    $client = $listener.AcceptTcpClient()
    try {
      $stream = $client.GetStream()
      $stream.ReadTimeout = 8000
      # Read raw request bytes: headers up to \r\n\r\n, then body by Content-Length
      $reqBuf = New-Object System.Collections.Generic.List[byte]
      $tmp = New-Object byte[] 4096
      $headerEndIdx = -1
      while($headerEndIdx -lt 0 -and $reqBuf.Count -lt 65536){
        $n = $stream.Read($tmp, 0, $tmp.Length)
        if($n -le 0){ break }
        # Cast slice to byte[]: PowerShell slicing a byte[] yields object[],
        # which List<byte>.AddRange rejects with "Cannot convert argument".
        $reqBuf.AddRange([byte[]]($tmp[0..($n-1)]))
        $arr = $reqBuf.ToArray()
        $hdr = [System.Text.Encoding]::ASCII.GetString($arr)
        $headerEndIdx = $hdr.IndexOf("`r`n`r`n")
      }
      if($headerEndIdx -lt 0){ $client.Close(); continue }
      $allBytes = $reqBuf.ToArray()
      $hdrText = [System.Text.Encoding]::ASCII.GetString($allBytes, 0, $headerEndIdx)
      $hdrLines = $hdrText -split "`r`n"
      $requestLine = $hdrLines[0]
      $parts = $requestLine -split ' '
      $method = if($parts.Length -ge 1){ $parts[0].ToUpper() } else { 'GET' }
      $urlPath = if($parts.Length -ge 2){ $parts[1] } else { '/' }
      $contentLength = 0
      foreach($hl in $hdrLines[1..($hdrLines.Length-1)]){
        if($hl -match '^Content-Length:\s*(\d+)$'){ $contentLength = [int]$Matches[1] }
      }
      $bodyStart = $headerEndIdx + 4
      $bodyHave = $allBytes.Length - $bodyStart
      # Read remaining body bytes if not fully received
      while($bodyHave -lt $contentLength){
        $n = $stream.Read($tmp, 0, $tmp.Length)
        if($n -le 0){ break }
        $reqBuf.AddRange([byte[]]($tmp[0..($n-1)]))
        $bodyHave += $n
      }
      $allBytes = $reqBuf.ToArray()
      $bodyLen = [Math]::Min($contentLength, $allBytes.Length - $bodyStart)
      $body = ''
      if($bodyLen -gt 0){ $body = [System.Text.Encoding]::UTF8.GetString($allBytes, $bodyStart, $bodyLen) }

      $rel = [System.Uri]::UnescapeDataString($urlPath.Split('?')[0])
      # /api/share routes -> token service
      if($rel -like '/api/share*'){
        Handle-ShareApi $stream $method $rel $body
      } else {
        if($rel -eq '/' -or $rel -eq ''){ $rel = '/index.html' }
        $rel = $rel.TrimStart('/')
        $abs = Join-Path $Root $rel
        try { $absResolved = (Resolve-Path $abs -ErrorAction Stop).Path } catch { $absResolved = $abs }
        if(-not $absResolved.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)){
          Send-404 $stream
        } elseif(Test-Path $absResolved -PathType Leaf){
          $mime = Get-Mime ([System.IO.Path]::GetExtension($absResolved))
          Send-File $stream $absResolved $mime
        } else {
          Send-404 $stream
        }
      }
    } catch {
      try { Send-500 $stream $_.Exception.Message } catch {}
    } finally {
      try { $client.Close() } catch {}
    }
  }
} finally {
  $listener.Stop()
  Write-Host "[Service] Stopped." -ForegroundColor Yellow
}
