# Use $PSScriptRoot so we never hardcode the Chinese folder path (avoids
# UTF-8/GBK mojibake when PowerShell 5.1 reads this file as ANSI).
$dir = $PSScriptRoot
if (-not $dir) { $dir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$path = Join-Path $dir 'serve.ps1'
$content = Get-Content $path -Raw
$errors = $null
$null = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$null, [ref]$errors)
if($errors -and $errors.Count -gt 0){
  Write-Host ("ERROR COUNT: " + $errors.Count)
  foreach($e in $errors){
    Write-Host ("  Line " + $e.Extent.StartLineNumber + " Col " + $e.Extent.StartColumnNumber + ": " + $e.Message)
  }
} else {
  Write-Host "NO SYNTAX ERRORS"
}
