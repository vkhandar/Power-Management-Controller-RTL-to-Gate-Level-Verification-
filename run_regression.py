#!/usr/bin/env python3
"""Parallel Questa/UVM regression manager for the PMIC verification project."""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import shutil
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Sequence


ROOT = Path(__file__).resolve().parent
TEST_ALIASES = {
    "smoke": "pmic_smoke_test",
    "corner": "pmic_corner_test",
    "random": "pmic_random_test",
}
ALL_TESTS = list(TEST_ALIASES.values())


@dataclass
class Attempt:
    number: int
    status: str
    return_code: int | None
    elapsed_seconds: float
    uvm_errors: int
    uvm_fatals: int
    assertion_failures: int
    coverage_file: str | None
    log_file: str
    reason: str = ""


@dataclass
class SeedResult:
    test: str
    seed: int
    attempts: list[Attempt] = field(default_factory=list)

    @property
    def passed(self) -> bool:
        return bool(self.attempts) and self.attempts[-1].status == "PASS"

    @property
    def recovered(self) -> bool:
        return self.passed and len(self.attempts) > 1


def command_text(command: Sequence[str]) -> str:
    return subprocess.list2cmdline([str(arg) for arg in command])


def run_logged(
    command: Sequence[str], cwd: Path, log_path: Path, timeout: int | None = None
) -> tuple[int | None, float, bool]:
    start = time.monotonic()
    timed_out = False
    with log_path.open("w", encoding="utf-8", errors="replace") as log:
        log.write(f"COMMAND: {command_text(command)}\n\n")
        log.flush()
        try:
            completed = subprocess.run(
                [str(arg) for arg in command],
                cwd=cwd,
                stdout=log,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=timeout,
                check=False,
            )
            return_code: int | None = completed.returncode
        except subprocess.TimeoutExpired:
            return_code = None
            timed_out = True
            log.write(f"\nTIMEOUT after {timeout} seconds\n")
    return return_code, time.monotonic() - start, timed_out


def require_tool(name: str) -> str:
    path = shutil.which(name)
    if not path:
        raise RuntimeError(f"Required executable '{name}' was not found on PATH")
    return path


def resolve_tests(value: str) -> list[str]:
    requested = [part.strip() for part in value.split(",") if part.strip()]
    if not requested or "all" in requested:
        return ALL_TESTS.copy()
    resolved: list[str] = []
    for name in requested:
        test = TEST_ALIASES.get(name, name)
        if test not in ALL_TESTS:
            choices = ", ".join(["all", *TEST_ALIASES, *ALL_TESTS])
            raise ValueError(f"Unknown test '{name}'. Valid values: {choices}")
        if test not in resolved:
            resolved.append(test)
    return resolved


def compile_project(args: argparse.Namespace, session: Path, vlog: str, vlib: str) -> Path:
    build = session / "build"
    build.mkdir(parents=True, exist_ok=True)
    work = build / "work"
    code, _, _ = run_logged([vlib, "work"], build, build / "vlib.log")
    if code != 0:
        raise RuntimeError(f"vlib failed; see {build / 'vlib.log'}")

    uvm_home = args.uvm_home.resolve()
    uvm_pkg = uvm_home / "src" / "uvm_pkg.sv"
    if not uvm_pkg.exists():
        raise RuntimeError(f"UVM package not found at {uvm_pkg}")
    dut = args.gate_netlist.resolve() if args.gate_netlist else ROOT / "rtl" / "power_controller.sv"
    sources = [
        uvm_pkg,
        ROOT / "rtl" / "pmic_pkg.sv",
        dut,
        ROOT / "tb" / "interfaces" / "pmic_if.sv",
        ROOT / "tb" / "models" / "power_stage_model.sv",
        ROOT / "tb" / "uvm" / "pmic_tb_pkg.sv",
        ROOT / "tb" / "assertions" / "pmic_assertions.sv",
        ROOT / "tb" / "tb_top.sv",
    ]
    missing = [str(path) for path in sources if not path.exists()]
    if missing:
        raise RuntimeError("Missing source files: " + ", ".join(missing))

    command = [vlog, "-sv", "-timescale", "1ns/1ps", f"+incdir+{uvm_home / 'src'}"]
    if not args.no_coverage:
        command.append("+cover=bcesft")
    command.extend(str(path) for path in sources)
    code, elapsed, _ = run_logged(command, build, build / "compile.log")
    if code != 0:
        raise RuntimeError(f"Compilation failed; see {build / 'compile.log'}")
    print(f"Compiled DUT and UVM testbench in {elapsed:.1f}s")
    return work


def final_count(pattern: str, text: str) -> int:
    values = re.findall(pattern, text, flags=re.IGNORECASE | re.MULTILINE)
    return int(values[-1]) if values else 0


def parse_transcript(
    path: Path, console_path: Path, return_code: int | None, timed_out: bool
) -> tuple[str, int, int, int, str]:
    # Some startup failures (notably license checkout) occur before Questa opens
    # its -l transcript, so classification must inspect both output streams.
    text = path.read_text(encoding="utf-8", errors="replace") if path.exists() else ""
    console_text = (
        console_path.read_text(encoding="utf-8", errors="replace")
        if console_path.exists() else ""
    )
    combined_text = text + "\n" + console_text
    uvm_errors = final_count(r"^\s*UVM_ERROR\s*:\s*(\d+)", text)
    uvm_fatals = final_count(r"^\s*UVM_FATAL\s*:\s*(\d+)", text)
    assertion_failures = len(
        re.findall(r"^\s*#?\s*\*\* Error:.*(?:assert|pmic_assertions|a_[a-z])", text,
                   flags=re.IGNORECASE | re.MULTILINE)
    )
    if timed_out:
        return "TIMEOUT", uvm_errors, uvm_fatals, assertion_failures, "simulation timeout"
    infrastructure_markers = (
        "Unable to checkout a license",
        "Invalid license environment",
        "Failed to open design unit",
        "Error loading design",
    )
    marker = next((item for item in infrastructure_markers if item.lower() in combined_text.lower()), "")
    if marker:
        return "INFRA_ERROR", uvm_errors, uvm_fatals, assertion_failures, marker
    if return_code != 0:
        return "FAIL", uvm_errors, uvm_fatals, assertion_failures, f"simulator exit {return_code}"
    if uvm_errors or uvm_fatals or assertion_failures:
        reason = f"UVM errors={uvm_errors}, fatals={uvm_fatals}, assertions={assertion_failures}"
        return "FAIL", uvm_errors, uvm_fatals, assertion_failures, reason
    if not re.search(r"UVM_(?:INFO|WARNING|ERROR|FATAL)\s*:", text):
        return "INFRA_ERROR", uvm_errors, uvm_fatals, assertion_failures, "missing UVM report summary"
    return "PASS", uvm_errors, uvm_fatals, assertion_failures, ""


def run_attempt(
    result: SeedResult,
    attempt_number: int,
    args: argparse.Namespace,
    session: Path,
    work: Path,
    vsim: str,
    vmap: str,
) -> Attempt:
    attempt_dir = session / "runs" / result.test / f"seed_{result.seed}" / f"attempt_{attempt_number}"
    attempt_dir.mkdir(parents=True, exist_ok=True)
    map_code, _, _ = run_logged(
        [vmap, "work", str(work)], attempt_dir, attempt_dir / "vmap.log"
    )
    if map_code != 0:
        return Attempt(attempt_number, "INFRA_ERROR", map_code, 0.0, 0, 0, 0, None,
                       str(attempt_dir / "transcript.log"), "vmap failed")

    do_command = "run -all; quit -f"
    if not args.no_coverage:
        do_command = "coverage save -onexit coverage.ucdb; run -all; quit -f"
    command: list[str] = [vsim, "-c", "-sv_seed", str(result.seed), "-l", "transcript.log"]
    if not args.no_coverage:
        command.append("-coverage")
    if args.sdf:
        command.extend(["-sdfmax", f"/tb_top/dut={args.sdf.resolve()}"])
    command.extend([
        "tb_top",
        f"+UVM_TESTNAME={result.test}",
        f"+RANDOM_OPS={args.random_ops}",
        "-do",
        do_command,
    ])
    console_log = attempt_dir / "console.log"
    return_code, elapsed, timed_out = run_logged(command, attempt_dir, console_log, args.timeout)
    transcript = attempt_dir / "transcript.log"
    status, errors, fatals, assertions, reason = parse_transcript(
        transcript, console_log, return_code, timed_out
    )
    coverage = attempt_dir / "coverage.ucdb"
    attempt = Attempt(
        attempt_number, status, return_code, round(elapsed, 3), errors, fatals, assertions,
        str(coverage) if coverage.exists() else None,
        str(transcript if transcript.exists() else console_log), reason,
    )
    (attempt_dir / "result.json").write_text(
        json.dumps(asdict(attempt), indent=2), encoding="utf-8"
    )
    return attempt


def merge_coverage(vcover: str, inputs: Sequence[Path], output: Path, log_dir: Path) -> bool:
    """Hierarchically merge UCDBs to stay below the Windows command-line limit."""
    if not inputs:
        return False
    log_dir.mkdir(parents=True, exist_ok=True)
    current = list(inputs)
    level = 0
    while len(current) > 50:
        next_level: list[Path] = []
        for index in range(0, len(current), 50):
            partial = log_dir / f"merge_l{level}_{index // 50}.ucdb"
            command = [vcover, "merge", str(partial), *map(str, current[index:index + 50])]
            code, _, _ = run_logged(command, ROOT, log_dir / f"merge_l{level}_{index // 50}.log")
            if code != 0:
                return False
            next_level.append(partial)
        current = next_level
        level += 1
    command = [vcover, "merge", str(output), *map(str, current)]
    code, _, _ = run_logged(command, ROOT, log_dir / "merge_final.log")
    return code == 0 and output.exists()


def collect_coverage(args: argparse.Namespace, session: Path, results: Sequence[SeedResult]) -> dict[str, str]:
    if args.no_coverage:
        return {}
    vcover = shutil.which("vcover")
    if not vcover:
        print("WARNING: vcover not found; UCDB files were retained but not merged", file=sys.stderr)
        return {}
    coverage_dir = session / "coverage"
    coverage_dir.mkdir(parents=True, exist_ok=True)
    reports: dict[str, str] = {}
    groups: dict[str, list[Path]] = {"all": []}
    for test in sorted({result.test for result in results}):
        groups[test] = []
    for result in results:
        if result.passed and result.attempts[-1].coverage_file:
            path = Path(result.attempts[-1].coverage_file)
            groups["all"].append(path)
            groups[result.test].append(path)
    for name, paths in groups.items():
        if not paths:
            continue
        merged = coverage_dir / f"{name}.ucdb"
        logs = coverage_dir / f"merge_{name}"
        if not merge_coverage(vcover, paths, merged, logs):
            print(f"WARNING: coverage merge failed for {name}; see {logs}", file=sys.stderr)
            continue
        report = coverage_dir / f"{name}.txt"
        command = [vcover, "report", "-details", "-output", str(report), str(merged)]
        run_logged(command, ROOT, coverage_dir / f"report_{name}.log")
        reports[name] = str(report)
        if name == "all":
            html = coverage_dir / "html"
            command = [vcover, "report", "-html", "-htmldir", str(html), str(merged)]
            run_logged(command, ROOT, coverage_dir / "report_html.log")
    return reports


def write_reports(
    args: argparse.Namespace,
    session: Path,
    results: Sequence[SeedResult],
    coverage_reports: dict[str, str],
    elapsed: float,
) -> None:
    persistent = [result for result in results if not result.passed]
    recovered = [result for result in results if result.recovered]
    summary = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "elapsed_seconds": round(elapsed, 3),
        "tests": sorted({result.test for result in results}),
        "seed_count_per_test": args.seeds,
        "total_runs": len(results),
        "passed": sum(result.passed for result in results),
        "persistent_failures": len(persistent),
        "recovered_on_rerun": len(recovered),
        "coverage_reports": coverage_reports,
        "results": [
            {
                "test": result.test,
                "seed": result.seed,
                "passed": result.passed,
                "recovered": result.recovered,
                "attempts": [asdict(attempt) for attempt in result.attempts],
            }
            for result in results
        ],
    }
    (session / "summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    with (session / "summary.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(["test", "seed", "passed", "recovered", "attempts", "final_status",
                         "uvm_errors", "uvm_fatals", "assertion_failures", "reason", "log"])
        for result in results:
            final = result.attempts[-1]
            writer.writerow([result.test, result.seed, result.passed, result.recovered,
                             len(result.attempts), final.status, final.uvm_errors,
                             final.uvm_fatals, final.assertion_failures, final.reason, final.log_file])

    failed_data = [{"test": result.test, "seed": result.seed} for result in persistent]
    (session / "failed_seeds.json").write_text(json.dumps(failed_data, indent=2), encoding="utf-8")
    replay = session / "rerun_failed.txt"
    replay.write_text("\n".join(
        f'python run_regression.py --test {result.test} --seeds 1 --first-seed {result.seed}'
        for result in persistent
    ) + ("\n" if persistent else ""), encoding="utf-8")

    lines = [
        "# Regression summary", "",
        f"- Total seeds/tests: {len(results)}",
        f"- Passed: {summary['passed']}",
        f"- Recovered on automatic rerun: {len(recovered)}",
        f"- Persistent failures: {len(persistent)}",
        f"- Elapsed: {elapsed:.1f} seconds", "",
        "| Test | Seed | Result | Attempts | Reason |", "|---|---:|---|---:|---|",
    ]
    for result in results:
        final = result.attempts[-1]
        label = "RECOVERED" if result.recovered else final.status
        lines.append(f"| {result.test} | {result.seed} | {label} | {len(result.attempts)} | {final.reason} |")
    (session / "summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Compile and run the PMIC Questa/UVM regression")
    parser.add_argument("--test", default="all",
                        help="all, smoke, corner, random, or a comma-separated list")
    parser.add_argument("--seeds", type=int, default=1, help="number of seeds per selected test")
    parser.add_argument("--first-seed", type=int, default=1, help="first random seed")
    parser.add_argument("--jobs", type=int, default=max(1, min(4, os.cpu_count() or 1)),
                        help="maximum concurrent simulations")
    parser.add_argument("--random-ops", type=int, default=120,
                        help="operations in each constrained-random sequence")
    parser.add_argument("--rerun-failures", type=int, default=1,
                        help="automatic rerun attempts after the initial failure")
    parser.add_argument("--timeout", type=int, default=300, help="per-simulation timeout in seconds")
    parser.add_argument("--out", type=Path, help="output directory (default: timestamped under out/)")
    parser.add_argument("--uvm-home", type=Path,
                        default=Path(r"C:\questasim64_10.4c\verilog_src\uvm-1.2"))
    parser.add_argument("--gate-netlist", type=Path, help="compile this netlist instead of RTL")
    parser.add_argument("--sdf", type=Path, help="maximum-delay SDF annotation for tb_top.dut")
    parser.add_argument("--no-coverage", action="store_true", help="disable coverage instrumentation")
    parser.add_argument("--compile-only", action="store_true", help="compile without launching simulations")
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if args.seeds < 1 or args.jobs < 1 or args.rerun_failures < 0 or args.timeout < 1:
        parser.error("seeds/jobs/timeout must be positive and rerun-failures cannot be negative")
    try:
        tests = resolve_tests(args.test)
        vlog, vlib = require_tool("vlog"), require_tool("vlib")
        vsim, vmap = require_tool("vsim"), require_tool("vmap")
        stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        session = (args.out or (ROOT / "out" / f"regression_{stamp}")).resolve()
        session.mkdir(parents=True, exist_ok=False)
        start = time.monotonic()
        work = compile_project(args, session, vlog, vlib)
        if args.compile_only:
            print(f"Compile-only run passed. Output: {session}")
            return 0

        results = [SeedResult(test, seed) for test in tests
                   for seed in range(args.first_seed, args.first_seed + args.seeds)]
        manifest = {
            "tests": tests,
            "seeds": list(range(args.first_seed, args.first_seed + args.seeds)),
            "jobs": args.jobs,
            "rerun_failures": args.rerun_failures,
        }
        (session / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")

        pending = results
        for attempt_number in range(1, args.rerun_failures + 2):
            if not pending:
                break
            if attempt_number > 1:
                print(f"Rerunning {len(pending)} failed seed(s), attempt {attempt_number}")
            with ThreadPoolExecutor(max_workers=args.jobs) as executor:
                futures = {
                    executor.submit(run_attempt, result, attempt_number, args, session, work, vsim, vmap): result
                    for result in pending
                }
                for future in as_completed(futures):
                    result = futures[future]
                    try:
                        attempt = future.result()
                    except Exception as exc:  # retain the seed and continue the regression
                        attempt = Attempt(attempt_number, "INFRA_ERROR", None, 0.0, 0, 0, 0,
                                          None, "", str(exc))
                    result.attempts.append(attempt)
                    print(f"[{attempt.status:11}] {result.test} seed={result.seed} "
                          f"attempt={attempt_number} ({attempt.elapsed_seconds:.1f}s)")
            pending = [result for result in pending if not result.passed]

        reports = collect_coverage(args, session, results)
        elapsed = time.monotonic() - start
        write_reports(args, session, results, reports, elapsed)
        failures = sum(not result.passed for result in results)
        recovered = sum(result.recovered for result in results)
        print(f"Regression complete: {len(results) - failures}/{len(results)} passed, "
              f"{recovered} recovered on rerun, {failures} persistent failure(s)")
        print(f"Summary: {session / 'summary.md'}")
        return 1 if failures else 0
    except (RuntimeError, ValueError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
