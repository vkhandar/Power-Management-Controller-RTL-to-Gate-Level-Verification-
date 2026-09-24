param([switch]$RunSmoke)
$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if (-not (Get-Command yosys -ErrorAction SilentlyContinue)) {
  throw "Yosys is not on PATH. Install Yosys or pass a vendor-produced netlist to scripts/run.ps1 -GateNetlist."
}
$gateDir = Join-Path $repo "out\gate"
New-Item -ItemType Directory -Force -Path $gateDir | Out-Null
Push-Location $repo
try {
  & yosys -l (Join-Path $gateDir "synthesis.log") -s (Join-Path $PSScriptRoot "synth.ys")
  if ($LASTEXITCODE -ne 0) { throw "Synthesis failed" }
  $netlist = Join-Path $gateDir "power_controller_netlist.v"
  Write-Host "Created $netlist"
  if ($RunSmoke) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "run.ps1") `
      -Test pmic_smoke_test -Seed 1 -GateNetlist $netlist -OutDir (Join-Path $gateDir "smoke")
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  }
} finally { Pop-Location }

