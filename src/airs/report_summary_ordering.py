"""Order saved summary details without altering evidence or source counts."""
from __future__ import annotations

from copy import deepcopy

from .types import InputError


def validate_summary_order(value: str) -> str:
    """Validate the requested presentation order before saved-report I/O."""
    if not isinstance(value, str) or value not in ("source", "verdict"):
        raise InputError("invalid_summary_order", "Summary order must be source or verdict")
    return value


def order_summary_findings(summary: dict, order: str = "source") -> dict:
    """Detach summary rows; optionally group existing verdicts stably.

    Apply after detail selection and before a display limit. This changes only
    row presentation; source counts, identity and selection metadata retain their
    original meanings. Source order preserves the exact existing summary shape.
    """
    selected_order = validate_summary_order(order)
    result = deepcopy(summary)
    if selected_order == "source":
        return result
    ranks = {"inconsistency": 0, "unresolved": 1, "agreement": 2}
    result["findings"].sort(key=lambda finding: ranks[finding["verdict"]])
    result["finding_order"] = "verdict"
    return result
