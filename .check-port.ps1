$c = Get-NetTCPConnection -LocalPort 8765 -State Listen -ErrorAction SilentlyContinue
if($c){
  $pids = $c.OwningProcess | Select-Object -Unique
  Write-Host ("LISTENING PIDs: " + ($pids -join ','))
  foreach($p in $pids){
    try {
      $proc = Get-Process -Id $p -ErrorAction Stop
      Write-Host ("  PID " + $p + " -> " + $proc.ProcessName)
    } catch {
      Write-Host ("  PID " + $p + " -> (unknown)")
    }
  }
} else {
  Write-Host "NO LISTENER on 8765"
}
