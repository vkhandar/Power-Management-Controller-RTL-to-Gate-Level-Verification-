param(
  [string]$Test = "pmic_smoke_test",
  [int]$Seed = 1,
  [int]$RandomOps = 80,
  [string]$OutDir = "",
  [string]$GateNetlist = "",
  [string]$Sdf = "",
  [switch]$NoCoverage
)
$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if (-not $OutDir) { $OutDir = Join-Path $repo "out\runs\${Test}_${Seed}" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path
$uvm = "C:\questasim64_10.4c\verilog_src\uvm-1.2"
if (-not (Test-Path $uvm)) { throw "Questa UVM 1.2 sources not found at $uvm" }

Push-Location $OutDir
try {
  if (Test-Path "work") { Remove-Item -Recurse -Force "work" }
  & vlib work | Out-Null
  $dutSource = if ($GateNetlist) { (Resolve-Path $GateNetlist).Path } else { Join-Path $repo "rtl\power_controller.sv" }
  $sources = @(
    (Join-Path $repo "rtl\pmic_pkg.sv"), $dutSource,
    (Join-Path $repo "tb\interfaces\pmic_if.sv"),
    (Join-Path $repo "tb\models\power_stage_model.sv"),
    (Join-Path $repo "tb\uvm\pmic_tb_pkg.sv"),
    (Join-Path $repo "tb\assertions\pmic_assertions.sv"),
    (Join-Path $repo "tb\tb_top.sv")
  )
  $coverArg = if ($NoCoverage) { @() } else { @("+cover=bcesft") }
  $compileArgs = @("-sv", "-timescale", "1ns/1ps", "+incdir+$uvm\src") + $coverArg + @("$uvm\src\uvm_pkg.sv") + $sources
  & vlog @compileArgs 2>&1 | Tee-Object -FilePath "compile.log"
  if ($LASTEXITCODE -ne 0) { throw "Compilation failed" }

  $do = if ($NoCoverage) { "run -all; quit -f" } else { "coverage save -onexit coverage.ucdb; run -all; quit -f" }
  $simArgs = @("-c", "-sv_seed", $Seed, "-l", "transcript.log")
  if (-not $NoCoverage) { $simArgs += "-coverage" }
  if ($Sdf) { $simArgs += "-sdfmax"; $simArgs += "/tb_top/dut=$(Resolve-Path $Sdf)" }
  $simArgs += @("tb_top", "+UVM_TESTNAME=$Test", "+RANDOM_OPS=$RandomOps", "-do", $do)
  & vsim @simArgs
  $toolExit = $LASTEXITCODE
  $log = if (Test-Path "transcript.log") { Get-Content "transcript.log" -Raw } else { "" }
  $uvmFatal = ([regex]::Matches($log, "UVM_FATAL\s*:\s*[1-9]")).Count -gt 0
  $uvmError = ([regex]::Matches($log, "UVM_ERROR\s*:\s*[1-9]")).Count -gt 0
  $assertFail = $log -match "\*\* Error:.*(Assertion|pmic_assertions)"
  $passed = ($toolExit -eq 0) -and !$uvmFatal -and !$uvmError -and !$assertFail
  $result = [ordered]@{
    test=$Test; seed=$Seed; passed=$passed; simulator_exit=$toolExit
    uvm_error=$uvmError; uvm_fatal=$uvmFatal; assertion_failure=$assertFail
    coverage=(Test-Path "coverage.ucdb"); timestamp=(Get-Date).ToString("o")
  }
  $result | ConvertTo-Json | Set-Content -Encoding UTF8 "result.json"
  if ($passed) { Write-Host "PASS $Test seed=$Seed" -ForegroundColor Green; exit 0 }
  Write-Host "FAIL $Test seed=$Seed (see $OutDir\transcript.log)" -ForegroundColor Red
  exit 1
} catch {
  [ordered]@{test=$Test;seed=$Seed;passed=$false;infrastructure_error=$_.Exception.Message;timestamp=(Get-Date).ToString("o")} |
    ConvertTo-Json | Set-Content -Encoding UTF8 "result.json"
  Write-Error $_
  exit 2
} finally { Pop-Location }
