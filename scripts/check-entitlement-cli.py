#!/usr/bin/env python3
"""Focused packaged CLI check using an explicitly supplied, owned differing pair.

Only the CLI is executed. App fixtures are read as data. No signing or setup.
The evidence directory must be new; this script never replaces prior evidence.
"""
import argparse
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--previous", type=Path, required=True)
    parser.add_argument("--current", type=Path, required=True)
    parser.add_argument("--architecture", choices=("arm64", "x86_64"), required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    cli, previous, current, evidence = (
        value.absolute() for value in (args.cli, args.previous, args.current, args.evidence)
    )
    evidence.mkdir(parents=True, exist_ok=False)
    base = ["--previous", str(previous), "--current", str(current),
            "--architecture", args.architecture]

    def run(name, options, status):
        result = subprocess.run([str(cli), *options], cwd=evidence,
                                capture_output=True, timeout=30, check=False)
        (evidence / (name + ".stdout")).write_bytes(result.stdout)
        (evidence / (name + ".stderr")).write_bytes(result.stderr)
        if result.returncode != status:
            raise RuntimeError(f"{name}: expected exit {status}, got {result.returncode}")
        if status == 2:
            if result.stdout or not result.stderr.startswith(b"airs-entitlements: "):
                raise RuntimeError(f"{name}: incorrect failure streams")
        elif result.stderr:
            raise RuntimeError(f"{name}: unexpected diagnostics")
        print(f"PASS {name}: exit {status}", flush=True)
        return result.stdout

    help_text = run("help", ["--help"], 0)
    if not help_text.startswith(b"Usage: airs-entitlements "):
        raise RuntimeError("help: wrong executable name")
    run("missing-architecture", base[:4], 2)
    different = run("native-differences", base, 1)

    def report(data, equal):
        value = json.loads(data)
        if value["schemaVersion"] != 1 or value["tool"] != "EntitlementDiff":
            raise RuntimeError("Report schema marker changed")
        if value["signatureValidation"] != "notPerformed":
            raise RuntimeError("Incorrect signature-validation claim")
        for side in ("previous", "current"):
            if value[side]["architecture"] != args.architecture:
                raise RuntimeError("Requested architecture was not preserved")
        if (len(value["changes"]) == 0) != equal:
            raise RuntimeError("Unexpected comparison outcome for supplied fixtures")
        if any(str(path).encode() in data for path in (previous, current)):
            raise RuntimeError("Source path exposed in report")

    report(different, equal=False)
    output = evidence / "equal report.json"
    equal_args = ["--previous", str(previous), "--current", str(previous),
                  "--architecture", args.architecture, "--output", output.name]
    if run("native-equal-file", equal_args, 0):
        raise RuntimeError("File output also wrote to stdout")
    original = output.read_bytes()
    report(original, equal=True)
    run("existing-output-refused", equal_args, 2)
    if output.read_bytes() != original:
        raise RuntimeError("Existing report was changed")
    run("missing-input", ["--previous", str(evidence / "Missing.app"), *base[2:]], 2)
    print("Six packaged CLI cases passed. Targets were not executed.", flush=True)


if __name__ == "__main__":
    main()
