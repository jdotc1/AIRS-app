#!/usr/bin/env python3
"""Check batch CLI wiring with an explicit owned differing fixture pair.

The evidence directory must be new. Only the CLI is executed; fixture apps are
read as data. No signing, dependency setup, GUI or existing evidence mutation.
"""
import argparse
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("cli", "previous", "current", "evidence"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--architecture", choices=("arm64", "x86_64"), required=True)
    args = parser.parse_args()
    cli, previous, current, root = (
        p.absolute() for p in (args.cli, args.previous, args.current, args.evidence)
    )
    root.mkdir(parents=True, exist_ok=False)

    def run(name, options, status, summary=False):
        process = subprocess.run([str(cli), *options], cwd=root,
                                 capture_output=True, timeout=30, check=False)
        (root / (name + ".stdout")).write_bytes(process.stdout)
        (root / (name + ".stderr")).write_bytes(process.stderr)
        if process.returncode != status:
            raise RuntimeError(f"{name}: expected {status}, got {process.returncode}")
        if status == 2:
            if not process.stderr.startswith(b"airs-entitlements: ") or (not summary and process.stdout):
                raise RuntimeError(f"{name}: incorrect failure streams")
        elif process.stderr:
            raise RuntimeError(f"{name}: unexpected diagnostic")
        print(f"PASS {name}: exit {status}", flush=True)
        return process.stdout

    pair = {"previousPath": str(previous), "currentPath": str(current), "architecture": args.architecture}
    equal = dict(pair, currentPath=str(previous))
    missing = dict(pair, previousPath=str(root / "Absent.app"))

    def manifest(name, selections):
        path = root / (name + ".json")
        path.write_text(json.dumps({"kind": "airs-entitlement-batch-manifest", "version": 1,
                                    "pairs": selections}), encoding="utf-8")
        return path

    def check_summary(data, output, statuses, status):
        summary = json.loads(data)
        if summary["kind"] != "airs-entitlement-batch-result" or summary["version"] != 1:
            raise RuntimeError("Wrong summary format")
        if summary["exitStatus"] != status or [r["status"] for r in summary["rows"]] != statuses:
            raise RuntimeError("Wrong ordered outcomes")
        if [r["index"] for r in summary["rows"]] != list(range(1, len(statuses) + 1)):
            raise RuntimeError("Manifest positions lost")
        if (output / "summary.json").read_bytes() != data:
            raise RuntimeError("Saved summary differs from stdout")
        for row in summary["rows"]:
            if row["status"] == "completed":
                report = json.loads((output / row["reportFile"]).read_bytes())
                if report["schemaVersion"] != 1 or report["tool"] != "EntitlementDiff":
                    raise RuntimeError("Pair report format changed")
                if report["previous"]["architecture"] != args.architecture:
                    raise RuntimeError("Architecture lost")
            elif "reportFile" in row:
                raise RuntimeError("Uncompleted row claims an export")

    plan = manifest("mixed plan", [pair, pair, missing, equal])
    mixed_output = root / "mixed output"
    command = ["batch", "--manifest", plan.name, "--output-directory", mixed_output.name]
    mixed = run("partial-failure", command, 2, summary=True)
    check_summary(mixed, mixed_output, ["completed", "duplicate", "failed", "completed"], 2)
    run("existing-directory-refused", command, 2)
    if (mixed_output / "summary.json").read_bytes() != mixed:
        raise RuntimeError("Existing summary changed")

    valid = manifest("successful plan", [pair, equal])
    successful_output = root / "successful output"
    successful = run("successful-batch", ["batch", "--manifest", valid.name,
                     "--output-directory", successful_output.name], 1)
    check_summary(successful, successful_output, ["completed", "completed"], 1)

    # The dispatcher changed; exercise the preserved pair branch once.
    single = run("single-pair-routing", ["--previous", str(previous), "--current", str(current),
                 "--architecture", args.architecture], 1)
    if json.loads(single)["schemaVersion"] != 1:
        raise RuntimeError("Pair routing changed")
    print("Four packaged process checks passed. Targets were not executed.", flush=True)


if __name__ == "__main__":
    main()
