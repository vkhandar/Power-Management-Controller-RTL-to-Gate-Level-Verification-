param(
  [int]$Seeds = 100,
  [int]$FirstSeed = 1,
  [int]$Jobs = 1,
  [int]$RandomOps = 120,
  [string[]]$Tests = @("pmic_random_test")
)
$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$root = Join-Path $repo "out\regression"
New-Item -ItemType Directory -Force -Path $root | Out-Null
$runs = @()
foreach ($test in $Tests) {
  for ($seed=$FirstSeed; $seed -lt ($FirstSeed+$Seeds); $seed++) {
    $runs += [pscustomobject]@{ Test=$test; Seed=$seed; Dir=(Join-Path $root "${test}_${seed}") }
  }
}

# Start independent simulator processes in throttled batches. Each run owns its
# own Questa work library, so parallel compilation cannot corrupt another run.
$active = @()
foreach ($run in $runs) {
  while ($active.Count -ge [Math]::Max(1,$Jobs)) {
    $done = $active | Where-Object { $_.Job.State -ne "Running" }
    if (!$done) { Start-Sleep -Milliseconds 250; continue }
    foreach ($d in $done) { Receive-Job $d.Job; Remove-Job $d.Job; $active = @($active | Where-Object {$_.Job.Id -ne $d.Job.Id}) }
  }
  $j = Start-Job -ScriptBlock {
    param($script,$test,$seed,$ops,$dir)
    & powershell -NoProfile -ExecutionPolicy Bypass -File $script -Test $test -Seed $seed -RandomOps $ops -OutDir $dir
  } -ArgumentList (Join-Path $PSScriptRoot "run.ps1"),$run.Test,$run.Seed,$RandomOps,$run.Dir
  $active += [pscustomobject]@{Job=$j;Run=$run}
}
foreach($a in $active) { Wait-Job $a.Job | Out-Null; Receive-Job $a.Job; Remove-Job $a.Job }

$results = foreach($run in $runs) {
  $path=Join-Path $run.Dir "result.json"
  if(Test-Path $path) { Get-Content $path -Raw | ConvertFrom-Json }
  else { [pscustomobject]@{test=$run.Test;seed=$run.Seed;passed=$false;infrastructure_error="missing result.json"} }
}
$results | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $root "summary.json")
$results | Select-Object test,seed,passed,simulator_exit,uvm_error,uvm_fatal,assertion_failure,infrastructure_error |
  Export-Csv -NoTypeInformation (Join-Path $root "summary.csv")
$failed=@($results | Where-Object {!$_.passed})
$failed | ForEach-Object { "$($_.test) $($_.seed)" } | Set-Content -Encoding UTF8 (Join-Path $root "failed_seeds.txt")

$ucdbs = @(Get-ChildItem $root -Recurse -Filter coverage.ucdb | Select-Object -ExpandProperty FullName)
if ($ucdbs.Count -gt 0 -and (Get-Command vcover -ErrorAction SilentlyContinue)) {
  & vcover merge (Join-Path $root "merged.ucdb") @ucdbs
  if ($LASTEXITCODE -eq 0) {
    & vcover report -details -output (Join-Path $root "coverage.txt") (Join-Path $root "merged.ucdb")
    & vcover report -html -htmldir (Join-Path $root "coverage_html") (Join-Path $root "merged.ucdb")
  }
  foreach($test in $Tests) {
    $testUcdbs = @(Get-ChildItem $root -Directory -Filter "${test}_*" |
      ForEach-Object { Join-Path $_.FullName "coverage.ucdb" } | Where-Object { Test-Path $_ })
    if($testUcdbs.Count -gt 0) {
      $testDb=Join-Path $root "coverage_${test}.ucdb"
      & vcover merge $testDb @testUcdbs
      if($LASTEXITCODE -eq 0) {
        & vcover report -details -output (Join-Path $root "coverage_${test}.txt") $testDb
      }
    }
  }
}
Write-Host "Regression: $($results.Count-$failed.Count)/$($results.Count) passed. Results: $root"
if($failed.Count) { exit 1 }
