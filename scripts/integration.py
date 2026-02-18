# /// script
# requires-python = ">=3.10"
# dependencies = ["pytest"]
# ///
"""
Integration tests for fuzzmate.

Finds the Zig binary, builds fuzzmate once, then for each test .c file:
  1. Runs fuzzmate to produce .zon and fuzzer.c
  2. Compiles the generated fuzzer.c with ``zig cc``
  3. Compares the .zon output against a golden file

Run with:  uv run scripts/integration.py
"""
import os
import shutil
import subprocess
from pathlib import Path

import pytest

PROJECT_ROOT = Path(__file__).resolve().parents[1]


def _find_zig() -> Path:
    """Locate the Zig binary from Cursor/VSCode extensions, falling back to PATH."""
    home = Path.home()
    search_dirs = [
        home / ".cursor-server/data/User/globalStorage/ziglang.vscode-zig/zig",
        home / ".vscode-server/data/User/globalStorage/ziglang.vscode-zig/zig",
        *sorted(home.glob(".cursor/extensions/ziglang.vscode-zig-*/zig"), reverse=True),
        *sorted(home.glob(".vscode/extensions/ziglang.vscode-zig-*/zig"), reverse=True),
    ]
    for d in search_dirs:
        if d.is_dir():
            for candidate in sorted(d.rglob("zig"), reverse=True):
                if candidate.is_file() and os.access(candidate, os.X_OK):
                    return candidate

    system_zig = shutil.which("zig")
    if system_zig:
        return Path(system_zig)

    pytest.fail("Could not find Zig binary — install the Zig extension or add zig to PATH")


ZIG = _find_zig()
FUZZMATE = PROJECT_ROOT / "zig-out/bin/fuzzmate"


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session", autouse=True)
def _build_fuzzmate():
    """Build fuzzmate once before the whole test session."""
    subprocess.check_call([str(ZIG), "build", "install"], cwd=PROJECT_ROOT)
    assert FUZZMATE.is_file(), f"fuzzmate binary not found at {FUZZMATE}"


# ---------------------------------------------------------------------------
# Test discovery
# ---------------------------------------------------------------------------

def _discover_tests():
    """Yield (c_file, golden_zon) pairs for parametrize, skipping as needed."""
    tests_dir = PROJECT_ROOT / "tests"
    for c_file in sorted(tests_dir.rglob("*.c")):
        golden = c_file.with_name(c_file.name + ".zon")
        skip_marker = c_file.with_name(c_file.name + ".zon.skip-arocc-bug")

        if skip_marker.exists():
            yield pytest.param(
                c_file, golden,
                id=f"{c_file.parent.name}/{c_file.name}",
                marks=pytest.mark.skip(reason=f"arocc parser bug ({skip_marker.name})"),
            )
            continue

        if not golden.exists():
            continue

        yield pytest.param(c_file, golden, id=f"{c_file.parent.name}/{c_file.name}")


# ---------------------------------------------------------------------------
# The actual test
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("c_file,golden_zon", list(_discover_tests()))
def test_fuzzmate(c_file: Path, golden_zon: Path, tmp_path: Path):
    include_dir = c_file.parent

    # fuzzmate expects paths relative to PROJECT_ROOT (matches golden files)
    rel = lambda p: str(p.relative_to(PROJECT_ROOT))

    # -- extra flags from .flags sidecar --
    flags_file = c_file.with_name(c_file.name + ".flags")
    extra_flags: list[str] = []
    if flags_file.exists():
        flags = [
            line for line in flags_file.read_text().splitlines()
            if line.strip() and not line.startswith("#")
        ]
        if flags:
            extra_flags = ["--"] + flags

    # -- target list from .targets sidecar, or the .c file itself --
    targets_file = c_file.with_name(c_file.name + ".targets")
    target_args: list[str] = []
    if targets_file.exists():
        for tgt in targets_file.read_text().splitlines():
            if tgt.strip() and not tgt.startswith("#"):
                target_args += ["--targets", rel(include_dir / tgt)]
    else:
        target_args = ["--targets", rel(c_file)]

    out_zon = tmp_path / "out.zon"
    out_fuzzer = tmp_path / "fuzzer.c"
    out_redef = tmp_path / "redef.txt"
    out_obj = tmp_path / "fuzzer.o"

    # 1. Run fuzzmate
    subprocess.check_call(
        [str(FUZZMATE)] + target_args
        + ["--zon", str(out_zon), "--out", str(out_fuzzer), "--redef", str(out_redef)]
        + extra_flags,
        cwd=PROJECT_ROOT,
    )

    # 2. Compile generated fuzzer.c with zig cc
    subprocess.check_call(
        [str(ZIG), "cc", "-c", str(out_fuzzer), "-o", str(out_obj), "-I", str(include_dir)],
    )

    # 3. Golden-file comparison (pytest shows a rich diff on assertion failure)
    actual = out_zon.read_text()
    expected = golden_zon.read_text()
    assert actual == expected, f"Output differs from golden file {golden_zon}"


# Allow `uv run scripts/integration.py` as the entry point.
if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
