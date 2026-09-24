# Verification plan

## Scope

The DUT boundary is the synthesizable `power_controller`. The plant is a
verification model, not a transistor-accurate converter. Voltage is represented
as an unsigned millivolt value and evolves as a first-order discrete-time
response with load droop and controllable OV/UV excursions.

## Feature-to-check mapping

| Feature | Stimulus | Primary checking | Coverage |
|---|---|---|---|
| register reset/read/write | smoke + random bus operations | reference-model mirror/readback | code + address activity |
| voltage and operating modes | all legal values | mirrored output pins and readback | mode × vset cross |
| enable and soft start | enable from zero and after recovery | command/PGOOD assertions and scoreboard | PGOOD cover property |
| load response | light/medium/heavy values | voltage window and PGOOD safety | load bins and main cross |
| OC/UV/OV shutdown | directed and random injection | fault/shutdown assertions | fault bins + assertion cover |
| W1C/manual recovery | remove source then clear status | reference model and shutdown checks | recovery bins |
| auto retry | random CTRL settings | shutdown/PGOOD safety | code and fault/recovery cross |
| gate-level equivalence smoke | synthesized netlist, optional SDF | same UVM environment and scoreboard | gate code/assertion/functional |

## Test intent

- `pmic_smoke_test`: basic programming, settling, PGOOD, load step, OC,
  shutdown, W1C recovery, and readback.
- `pmic_corner_test`: exhaustive legal modes and voltage settings at three load
  classes, with each fault and explicit recovery. This is the principal
  deterministic coverage-closure test.
- `pmic_random_test`: weighted constrained-random register, timing, load, and
  fault operations. `+RANDOM_OPS=N` controls sequence length.

## Closure criteria

- zero UVM errors/fatals and zero assertion failures over the agreed seed set;
- 100% reachable functional bins, including the main five-way cross;
- 100% assertion coverage for request acknowledgement, fault shutdown, PGOOD,
  PWM disable, and command disable properties;
- line/toggle/branch/FSM coverage reviewed, with exclusions documented rather
  than silently removed;
- all failed seeds reproducible from `summary.csv` and `failed_seeds.txt`.

The `fault=none × recovery=yes` cross combinations are ignored because recovery
retains and samples the preceding fault type. Combined-fault bins remain legal
and are expected to be reached by random regressions.

## RTL-to-gate flow

`scripts/synth.ps1` produces a generic Yosys netlist when Yosys is available.
For an ASIC/FPGA tool, export a netlist preserving the module/port contract and
run it with `scripts/run.ps1 -GateNetlist <file>`. Add `-Sdf <file>` for maximum
delay annotation. The same tests, assertions, reference model, scoreboard, and
coverage collectors are reused unchanged.

