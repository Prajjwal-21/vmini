#!/usr/bin/env python3
"""Run RISC-V test ELFs on the core testbench and report pass/fail.

For each ELF: convert it to a $readmemh hex file, look up `tohost` (and, if
present, the interrupt handler's counter `irq_handled`) in the symbol table,
run the Verilator simulator once per configuration, and parse the testbench's
"RESULT:" and "STATS:" lines.

Configurations (docs/architecture.md P2.11; D-017, D-030):
  ideal         ideal memory, interrupts off              one run
  random        random latency, interrupts off            one run per seed
  ideal+irq     ideal memory, random interrupts           one run per seed
  random+irq    random latency, random interrupts         one run per seed
The seed drives both the memory latency and the interrupt generator.

--irq-variant-dir DIR: in the +irq configurations, run DIR/<name> instead of
the given ELF when it exists (the rv32ui build with the interrupt hooks, D-028);
the interrupt-free configurations always run the given, unmodified ELF.

Directed tests declare minimum event counts in their source:
  # HAZARD-EXPECT: load_use>=6 fwd_exmem>=4        checked in `ideal` only
  # IRQ-EXPECT(any): irq_ldst>=4                   checked in every config
  # IRQ-EXPECT(ideal): irq_redirect>=4             checked with ideal memory
when --src-dir points at the sources. With --irq-coverage, the interrupt
coverage events are summed over all +irq runs and compared with the sum of the
IRQ-EXPECT floors of those runs (P2.13).

Exclusions come from --exclude (scripts/exclusions.txt; format documented
there). Exit status is non-zero if any run fails or coverage is short.
"""

import argparse
import concurrent.futures
import os
import re
import subprocess
import sys
from pathlib import Path

HAZARD_RE = re.compile(r"HAZARD-EXPECT:\s*(.*)")
IRQ_RE = re.compile(r"IRQ-EXPECT\((any|ideal)\):\s*(.*)")
TERM_RE = re.compile(r"(\w+)\s*>=\s*(\d+)")

CONFIGS = ("ideal", "random", "ideal+irq", "random+irq")
COVERAGE_EVENTS = ("irq_ex_memop", "irq_ldst", "irq_redirect", "irq_defer_csr",
                   "irq_defer_mret", "irq_defer_fencei", "exc_irq")
REPORTED_ONLY = ("irq_ex_memop_held",)


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def load_exclusions(path, phase):
    """Return {test_name: reason} for tests excluded in this phase."""
    excluded = {}
    if not path:
        return excluded
    for raw in Path(path).read_text().splitlines():
        line, _, comment = raw.partition("#")
        fields = line.split()
        if not fields:
            continue
        name, upto = fields[0], fields[1] if len(fields) > 1 else "*"
        if upto == "*" or phase <= int(upto):
            excluded[name] = comment.strip()
    return excluded


def load_expectations(src_dir, name):
    """Return (hazard floors, {'any': floors, 'ideal': floors})."""
    hazard, irq = {}, {"any": {}, "ideal": {}}
    if not src_dir:
        return hazard, irq
    src = Path(src_dir) / f"{name}.S"
    if not src.exists():
        return hazard, irq
    for line in src.read_text().splitlines():
        m = HAZARD_RE.search(line)
        if m:
            hazard.update({k: int(v) for k, v in TERM_RE.findall(m.group(1))})
        m = IRQ_RE.search(line)
        if m:
            irq[m.group(1)].update({k: int(v) for k, v in TERM_RE.findall(m.group(2))})
    return hazard, irq


def irq_floors(irq_expect, mem):
    floors = dict(irq_expect["any"])
    if mem == "ideal":
        for k, v in irq_expect["ideal"].items():
            floors[k] = floors.get(k, 0) + v
    return floors


def prepare(elf, prefix, work):
    """ELF -> hex (relative to 0x8000_0000), tohost and irq_handled addresses.

    The hex name includes the ELF's directory, because the same test name
    exists in several builds (stock, interrupt hooks, CSR-free)."""
    hexfile = work / f"{elf.parent.name}__{elf.name}.hex"
    if not hexfile.exists() or hexfile.stat().st_mtime < elf.stat().st_mtime:
        res = run([prefix + "objcopy", "-O", "verilog",
                   "--change-addresses=-0x80000000", str(elf), str(hexfile)])
        if res.returncode != 0:
            raise RuntimeError(f"objcopy failed for {elf}: {res.stderr.strip()}")
    syms = {}
    for line in run([prefix + "nm", str(elf)]).stdout.splitlines():
        parts = line.split()
        if len(parts) == 3:
            syms[parts[2]] = parts[0]
    if "tohost" not in syms:
        raise RuntimeError(f"no tohost symbol in {elf}")
    return hexfile, syms["tohost"], syms.get("irq_handled")


def simulate(sim, hexfile, tohost, irq_count, mem, irq, seed, timeout):
    args = [sim, f"+hex={hexfile}", f"+tohost={tohost}", f"+mem={mem}",
            f"+irq={'on' if irq else 'off'}", f"+timeout={timeout}"]
    if seed is not None:
        args.append(f"+seed={seed}")
    if irq_count is not None:
        args.append(f"+irq_count={irq_count}")
    res = run(args)
    out = res.stdout + res.stderr
    result, stats = None, {}
    for line in out.splitlines():
        if line.startswith("RESULT:"):
            result = line[len("RESULT:"):].strip()
        elif line.startswith("STATS:"):
            stats = {k: int(v) for k, v in re.findall(r"(\w+)=(\d+)", line)}
    if result is None:
        # No RESULT line: an assertion or a crash. Keep the first error line.
        err = next((l for l in out.splitlines() if "Fatal" in l or "Error" in l),
                   f"simulator exited with status {res.returncode}")
        result = "FAIL " + err.strip()
    elif res.returncode != 0 and result == "PASS":
        result = f"FAIL simulator exited with status {res.returncode}"
    return result, stats, " ".join(args)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--sim", required=True)
    ap.add_argument("--prefix", required=True, help="RISC-V binutils prefix")
    ap.add_argument("--work", required=True, help="directory for hex files")
    ap.add_argument("--configs", nargs="+", default=["ideal"], choices=CONFIGS)
    ap.add_argument("--seeds", nargs="*", type=int, default=[101, 202, 303])
    ap.add_argument("--timeout", type=int, default=200000)
    ap.add_argument("--exclude", help="exclusion list (scripts/exclusions.txt)")
    ap.add_argument("--phase", type=int, default=1)
    ap.add_argument("--src-dir", help="directed-test sources, for *-EXPECT lines")
    ap.add_argument("--irq-variant-dir", help="ELFs to use instead in +irq configs")
    ap.add_argument("--irq-coverage", action="store_true",
                    help="check the aggregate interrupt coverage over the +irq runs")
    ap.add_argument("-j", "--jobs", type=int, default=os.cpu_count() or 4)
    ap.add_argument("elfs", nargs="+")
    args = ap.parse_args()

    work = Path(args.work)
    work.mkdir(parents=True, exist_ok=True)
    excluded = load_exclusions(args.exclude, args.phase)

    configs = []                      # (label, mem, irq, seed)
    for c in args.configs:
        mem, irq = c.split("+")[0], c.endswith("+irq")
        if c == "ideal":
            configs.append((c, mem, irq, None))
        else:
            if not args.seeds:
                sys.exit(f"config {c} needs at least one seed")
            configs.extend((f"{c}:{s}", mem, irq, s) for s in args.seeds)

    jobs, skipped = [], []
    for elf_path in args.elfs:
        elf = Path(elf_path)
        if elf.name in excluded:
            skipped.append((elf.name, excluded[elf.name]))
            continue
        hazard, irq_expect = load_expectations(args.src_dir, elf.name)
        for label, mem, irq, seed in configs:
            run_elf = elf
            if irq and args.irq_variant_dir:
                variant = Path(args.irq_variant_dir) / elf.name
                if variant.exists():
                    run_elf = variant
            hexfile, tohost, irq_count = prepare(run_elf, args.prefix, work)
            jobs.append((elf.name, run_elf, label, hexfile, tohost, irq_count,
                         mem, irq, seed, hazard, irq_expect))

    def work_item(job):
        (name, run_elf, label, hexfile, tohost, irq_count, mem, irq, seed,
         hazard, irq_expect) = job
        result, stats, cmd = simulate(args.sim, hexfile, tohost, irq_count, mem,
                                      irq, seed, args.timeout)
        floors = irq_floors(irq_expect, mem)
        if result == "PASS":
            short = []
            if label == "ideal":
                short += [f"{k}={stats.get(k, 0)}<{v}" for k, v in hazard.items()
                          if stats.get(k, 0) < v]
            short += [f"{k}={stats.get(k, 0)}<{v}" for k, v in floors.items()
                      if stats.get(k, 0) < v]
            if short:
                result = "FAIL counts below *-EXPECT: " + " ".join(short)
        return name, run_elf, label, irq, result, stats, floors, cmd

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        results = list(pool.map(work_item, jobs))

    # Per-run report
    print(f"{'test':28} {'config':15} {'cycles':>7} {'retired':>7} {'irq':>4}  result")
    print("-" * 86)
    failures = []
    for name, run_elf, label, irq, result, stats, floors, cmd in results:
        hooked = args.irq_variant_dir and run_elf.parent == Path(args.irq_variant_dir)
        tag = name + "*" if hooked else name
        print(f"{tag:28} {label:15} {stats.get('cycles', 0):>7} "
              f"{stats.get('retired', 0):>7} {stats.get('irq', 0):>4}  {result}")
        if result != "PASS":
            failures.append((name, label, result, cmd))
    for name, reason in skipped:
        print(f"{name:28} {'-':15} {'':>7} {'':>7} {'':>4}  EXCLUDED ({reason})")
    print("-" * 86)
    if args.irq_variant_dir:
        print(f"* = interrupt-hook build from {args.irq_variant_dir}")
    n_pass = len(results) - len(failures)
    print(f"{n_pass}/{len(results)} runs passed, {len(skipped)} tests excluded, "
          f"configs: {', '.join(c[0] for c in configs)}")

    # Aggregate interrupt coverage over the +irq runs (P2.13)
    coverage_ok = True
    if args.irq_coverage:
        irq_runs = [r for r in results if r[3]]
        print(f"\nInterrupt coverage over {len(irq_runs)} random-interrupt runs "
              "(minimum = sum of the IRQ-EXPECT floors of those runs):")
        print(f"  {'event':20} {'total':>7} {'irq_cov':>8} {'others':>8} {'minimum':>8}  status")
        for ev in COVERAGE_EVENTS + REPORTED_ONLY:
            total = sum(r[5].get(ev, 0) for r in irq_runs)
            cov = sum(r[5].get(ev, 0) for r in irq_runs if r[0] == "irq_cov")
            floor = sum(r[6].get(ev, 0) for r in irq_runs)
            if ev in REPORTED_ONLY:
                status = "reported only"
            elif total >= floor and floor > 0:
                status = "ok"
            else:
                status = "SHORT" if total < floor else "NO FLOOR (irq_cov not run?)"
                coverage_ok = False
            print(f"  {ev:20} {total:>7} {cov:>8} {total - cov:>8} {floor:>8}  {status}")
        n_irq = sum(r[5].get("irq", 0) for r in irq_runs)
        print(f"  interrupts taken: {n_irq}; exceptions taken: "
              f"{sum(r[5].get('exc', 0) for r in irq_runs)}")
        if not coverage_ok:
            print("interrupt coverage: FAILED")

    if failures:
        print("\nReproduce a failure with:")
        for name, label, result, cmd in failures[:10]:
            print(f"  [{name} {label}] {cmd}")
    return 0 if (not failures and coverage_ok) else 1


if __name__ == "__main__":
    sys.exit(main())
