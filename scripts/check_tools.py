#!/usr/bin/env python3
"""Toolchain check for the Mini RISC-V SoC (CLAUDE.md section 2).

Prints every tool the project uses, the phase that first needs it, and its
version or an install hint. Exits non-zero if any tool required by phases
0..--phase is missing, so `make check-tools PHASE=N` can gate a phase.

Usage: check_tools.py [--phase N]
"""

import argparse
import shutil
import subprocess
import sys
from dataclasses import dataclass, field

# Cross-compiler prefixes accepted, in order of preference. Keep in sync with
# RISCV_PREFIX_CANDIDATES in the Makefile.
# riscv64-elf- (Homebrew core) is the project standard (docs/decisions.md D-002).
RISCV_PREFIXES = ["riscv64-elf-", "riscv32-unknown-elf-", "riscv64-unknown-elf-"]

# Flags the project compiles software with (CLAUDE.md section 2).
RV32_FLAGS = ["-march=rv32i_zicsr_zifencei", "-mabi=ilp32"]


@dataclass
class Tool:
    name: str
    phase: int              # first phase that needs the tool
    required: bool          # False = recommended only; never fails the check
    install: str            # install hint shown when missing
    commands: list = field(default_factory=list)  # candidate executables
    version_args: list = field(default_factory=lambda: ["--version"])


TOOLS = [
    Tool("make", 0, True, "xcode-select --install", ["make"]),
    Tool("git", 0, True, "xcode-select --install", ["git"]),
    Tool("python3", 0, True, "brew install python", ["python3"]),
    Tool("verilator (>= 5)", 0, True, "brew install verilator", ["verilator"]),
    Tool("riscv gcc (rv32)", 0, True, "brew install riscv64-elf-gcc",
         [p + "gcc" for p in RISCV_PREFIXES]),
    # Verilator's constrained randomization calls out to an SMT solver; the
    # UVM smoke test (Phase 0) already uses a constraint.
    Tool("z3 (SMT solver)", 0, True, "brew install z3", ["z3"]),
    Tool("surfer (waveforms)", 1, False, "brew install surfer", ["surfer"]),
    Tool("spike", 3, True,
         "brew install dtc && brew tap riscv-software-src/riscv && brew install riscv-isa-sim",
         ["spike"], ["--help"]),
    Tool("nix (for LibreLane)", 8, True,
         "see https://librelane.readthedocs.io (Nix installation, macOS)", ["nix"]),
]


def first_line(cmd):
    """Return the first non-empty line a command prints (stdout or stderr)."""
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return None, str(exc)
    for line in (res.stdout + res.stderr).splitlines():
        if line.strip():
            return res.returncode, line.strip()
    return res.returncode, ""


def check(tool):
    """Return (ok, detail) for one tool."""
    for exe in tool.commands:
        path = shutil.which(exe)
        if not path:
            continue
        _, version = first_line([path] + tool.version_args)
        if tool.name.startswith("verilator"):
            ok, detail = check_verilator_version(version)
            return ok, detail
        if tool.name.startswith("riscv gcc"):
            return check_rv32_compile(path, version)
        return True, f"{version}  ({path})"
    return False, f"not found - install: {tool.install}"


def check_verilator_version(version):
    # "Verilator 5.052 2026-..." -> major 5
    try:
        major = int(version.split()[1].split(".")[0])
    except (IndexError, ValueError):
        return False, f"cannot parse version from '{version}'"
    if major < 5:
        return False, f"{version} - need Verilator 5.x: brew upgrade verilator"
    return True, version


def check_rv32_compile(gcc, version):
    """The compiler must accept the project's RV32 -march/-mabi flags."""
    cmd = [gcc] + RV32_FLAGS + ["-c", "-x", "c", "/dev/null", "-o", "/dev/null"]
    rc, msg = first_line(cmd)
    if rc != 0:
        return False, f"{gcc} rejects {' '.join(RV32_FLAGS)}: {msg}"
    return True, f"{version}  ({gcc})"


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--phase", type=int, default=0,
                    help="fail if a tool needed by phases 0..N is missing")
    args = ap.parse_args()

    print(f"{'tool':22} {'phase':6} {'status':8} details")
    print("-" * 78)
    blocking = []
    for tool in TOOLS:
        ok, detail = check(tool)
        needed_now = tool.required and tool.phase <= args.phase
        status = "ok" if ok else ("MISSING" if needed_now else "later" if tool.required else "optional")
        print(f"{tool.name:22} {'P' + str(tool.phase):6} {status:8} {detail}")
        if needed_now and not ok:
            blocking.append(tool.name)

    print("-" * 78)
    if blocking:
        print(f"FAIL: phase {args.phase} is blocked on: {', '.join(blocking)}")
        return 1
    print(f"OK: every tool required up to phase {args.phase} is available")
    return 0


if __name__ == "__main__":
    sys.exit(main())
