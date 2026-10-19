#!/usr/bin/env python3
"""Owned bootstrap. Works with Python isolated mode, without pip or PYTHONPATH."""
from pathlib import Path
import sys

sys.dont_write_bytecode = True  # Keep a packaged/signed Engine directory immutable.
sys.path.insert(0, str(Path(__file__).resolve().parent / "src"))

from airs.cli import main  # noqa: E402

if __name__ == "__main__":
    raise SystemExit(main())
