# Mixed-Signal Power-Management Controller Verification

This repository is a compact RTL-to-gate-ready UVM project for a digitally
controlled buck converter.  The analog behavior is deliberately abstract: the
power stage is a clocked real-number model expressed in millivolts, while the
controller is synthesizable RTL.

## Features

- programmable 0.8/1.0/1.2/1.5 V set points and PWM/PFM operating modes
- enable, soft start, PWM generation, PGOOD qualification, UV/OV detection
- external over-current input, latched faults, shutdown, clear/recovery
- small memory-mapped configuration/status interface
- reusable UVM agent, sequences, monitor, reference model, scoreboard
- directed and constrained-random tests, SVA, functional cross coverage
- seed regression with UCDB merge and machine-readable pass/fail summaries
- an RTL or synthesized gate-level DUT selected from the command line

## Register map

| Address | Name | Access | Description |
|---:|---|---|---|
| `0x00` | CTRL | RW | bit 0 enable, bits 2:1 mode, bit 3 auto-retry |
| `0x04` | VSET | RW | bits 1:0: 0.8, 1.0, 1.2, 1.5 V |
| `0x08` | STATUS | RO | enabled, soft-start, PGOOD, fault, mode, vset |
| `0x0c` | FAULT | RO/W1C | OC, UV, OV latched fault bits |
| `0x10` | TIMING | RW | soft-start divider (low byte), PGOOD cycles (high byte) |

The bus is a one-request/one-response teaching interface.  Requests are held
until `cfg_ready`; reads return data in the same response cycle.

## Run

From a Questa-enabled PowerShell:

```powershell
./scripts/run.ps1 -Test pmic_smoke_test -Seed 1
./scripts/run.ps1 -Test pmic_corner_test -Seed 7
./scripts/run.ps1 -Test pmic_random_test -Seed 42
./scripts/regress.ps1 -Seeds 100 -Jobs 4
./scripts/synth.ps1 -RunSmoke
```

For larger regressions, the Python manager compiles once, runs simulations in
parallel, retries failed seeds, merges coverage, and writes JSON/CSV/Markdown
reports:

```powershell
python run_regression.py --test all --seeds 500
python run_regression.py --test random --seeds 100 --jobs 8 --rerun-failures 2
```

`--test all` runs smoke, corner, and random tests for every requested seed.
Results are placed in a timestamped `out/regression_*` directory. Persistent
failures are recorded in `failed_seeds.json` and as directly executable replay
commands in `rerun_failed.txt`.

Results go beneath `out/`. Every simulation writes `result.json` and
`transcript.log`; regression additionally writes `summary.json`, `summary.csv`,
`failed_seeds.txt`, and (when Questa coverage tools are licensed) merged UCDB
and text/HTML coverage reports.

Use `-GateNetlist path/to/controller.v -Sdf path/to/controller.sdf` to replace
the RTL with a synthesized netlist. The netlist must retain module name
`power_controller` and the same ports. SDF annotation is applied to
`tb_top.dut`.

See [`docs/verification-plan.md`](docs/verification-plan.md) for the feature
matrix, closure criteria, and RTL-to-gate handoff.

## Coverage closure workflow

1. Run a reproducible baseline: `./scripts/regress.ps1 -Seeds 200 -Jobs 4`.
2. Inspect `out/regression/coverage.txt` and per-test UCDB files.
3. Find uncovered bins in `pmic_coverage`, uncovered assertions, and RTL lines.
4. Add a targeted sequence/test; do not waive a bin until its illegality is
   documented in the covergroup.
5. Re-run the failed/target seed, then the complete regression.

The main closure target is the cross `mode x voltage x load x fault x recovery`.
Illegal combinations are intentionally kept to a minimum so holes represent
useful missing stimulus rather than decorative coverage.
