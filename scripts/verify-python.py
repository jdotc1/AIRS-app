#!/usr/bin/env python3
"""Run AIRS's owned Python unittest suite and write a JSON verification receipt.

This is source-test evidence. It does not qualify a packaged app, its private
interpreter, signing, notarization, or a clean Mac. Requires Python 3.11+ and no
third-party packages. Run with -I -B to isolate Python imports and avoid caches.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import time
import unittest


CI_KEYS = (
    "GITHUB_ACTIONS", "GITHUB_REPOSITORY", "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT",
    "GITHUB_JOB", "GITHUB_SHA", "RUNNER_OS", "RUNNER_ARCH", "ImageOS", "ImageVersion",
)


def utc_now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def source_identity(root):
    """Do not attribute a parent checkout's HEAD to an extracted source tree."""
    def git(*arguments):
        return subprocess.run(
            ["git", "-C", str(root), *arguments], capture_output=True,
            text=True, check=True, timeout=10,
        ).stdout.strip()

    try:
        if Path(git("rev-parse", "--show-toplevel")).resolve() != root:
            return {"status": "not_a_checkout", "revision": None, "dirty": None}
        return {
            "status": "git",
            "revision": git("rev-parse", "HEAD"),
            "dirty": bool(git("status", "--porcelain", "--untracked-files=normal")),
        }
    except (OSError, subprocess.SubprocessError):
        return {"status": "not_a_checkout", "revision": None, "dirty": None}


def write_receipt(path, receipt):
    """Publish a complete JSON document through a same-directory replacement."""
    path.parent.mkdir(parents=True, exist_ok=True)
    staged = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=path.parent,
            prefix=".python-receipt-", suffix=".json", delete=False,
        ) as stream:
            staged = Path(stream.name)
            json.dump(receipt, stream, indent=2, sort_keys=True)
            stream.write("\n")
        os.replace(staged, path)
    finally:
        if staged is not None:
            staged.unlink(missing_ok=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--pattern", default="test_*.py", help="unittest filename pattern")
    parser.add_argument("--fail-on-skip", action="store_true",
                        help="Return failure when any discovered test is skipped")
    args = parser.parse_args(argv)
    root = args.root.resolve()
    receipt_path = args.receipt.resolve()
    started = time.monotonic()
    receipt = {
        "schema_version": 1,
        "check": "python-unittest",
        "scope": "source-tests",
        "status": "running",
        "exit_code": None,
        "started_at": utc_now(),
        "source": source_identity(root),
        "discovery": {"directory": "tests", "pattern": args.pattern, "test_cases": None},
        "policy": {"fail_on_skip": args.fail_on_skip},
        "environment": {
            "python_version": platform.python_version(),
            "python_implementation": platform.python_implementation(),
            "system": platform.system(),
            "release": platform.release(),
            "machine": platform.machine(),
            "ci": {key: os.environ[key] for key in CI_KEYS if key in os.environ},
        },
    }
    # An interrupted/killed run must not leave an earlier passing receipt behind.
    try:
        write_receipt(receipt_path, receipt)
    except OSError as error:
        print(f"Cannot create verification receipt: {error}", file=sys.stderr)
        return 2

    observed = None
    def make_result(*arguments, **keywords):
        nonlocal observed
        observed = unittest.TextTestResult(*arguments, **keywords)
        return observed

    try:
        if not (root / "tests").is_dir():
            raise ValueError("The selected source root has no tests directory")
        os.chdir(root)
        sys.dont_write_bytecode = True
        sys.path.insert(0, str(root / "src"))
        suite = unittest.TestLoader().discover(str(root / "tests"), pattern=args.pattern)
        receipt["discovery"]["test_cases"] = suite.countTestCases()
        if receipt["discovery"]["test_cases"] == 0:
            receipt.update(status="empty", exit_code=2)
        else:
            result = unittest.TextTestRunner(verbosity=2, resultclass=make_result).run(suite)
            if not result.wasSuccessful() or (args.fail_on_skip and result.skipped):
                receipt.update(status="failed", exit_code=1)
            elif result.skipped:
                receipt.update(status="passed_with_skips", exit_code=0)
            else:
                receipt.update(status="passed", exit_code=0)
    except KeyboardInterrupt:
        receipt.update(status="interrupted", exit_code=130)
    except (Exception, SystemExit) as error:
        receipt.update(status="error", exit_code=2,
                       runner_error=f"{type(error).__name__}: {error}")

    result = observed if observed is not None else unittest.TestResult()
    receipt.update({
        "completed_at": utc_now(),
        "duration_seconds": round(time.monotonic() - started, 6),
        "counts": {
            "tests_run": result.testsRun,
            "failures": len(result.failures),
            "errors": len(result.errors),
            "skipped": len(result.skipped),
            "expected_failures": len(result.expectedFailures),
            "unexpected_successes": len(result.unexpectedSuccesses),
        },
        "failures": [{"test": test.id(), "detail": detail} for test, detail in result.failures],
        "errors": [{"test": test.id(), "detail": detail} for test, detail in result.errors],
        "skipped": [{"test": test.id(), "reason": reason} for test, reason in result.skipped],
        "expected_failures": [
            {"test": test.id(), "detail": detail} for test, detail in result.expectedFailures
        ],
        "unexpected_successes": [test.id() for test in result.unexpectedSuccesses],
    })
    try:
        write_receipt(receipt_path, receipt)
    except OSError as error:
        print(f"Cannot complete verification receipt: {error}", file=sys.stderr)
        return 2
    print(f"Verification {receipt['status']}; receipt: {receipt_path}", file=sys.stderr)
    return receipt["exit_code"]


if __name__ == "__main__":
    raise SystemExit(main())
