# Kill any process listening on port 8765 so we can restart with the latest serve.ps1
$c = Get-NetTCPConnection -LocalPort 8765 -State Listen -ErrorAction SilentlyContinue
if($c){
  $pids = $c.OwningProcess | Select-Object -Unique
  foreach($p in $pids){
    try {
      Stop-Process -Id $p -Force -ErrorAction Stop
      Write-Host ("Killed PID " + $p)
    } catch {
      Write-Host ("Failed to kill PID " + $p + " : " + $_.Exception.Message)
    }
  }
} else {
  Write-Host "No listener on 8765"
}
