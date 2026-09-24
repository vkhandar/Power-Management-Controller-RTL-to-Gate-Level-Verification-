$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$target = Join-Path $repo "out"
if (Test-Path $target) {
  Remove-Item -LiteralPath $target -Recurse -Force
  Write-Host "Removed generated results at $target"
}

