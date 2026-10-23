"""Bound displayed summary rows without changing saved-report counts."""
from __future__ import annotations

from copy import deepcopy

from .types import InputError


def validate_summary_limit(value: int | None) -> int | None:
    """Validate an exact integer row limit before any saved-report file I/O."""
    if value is None:
        return None
    if type(value) is not int or not 0 <= value <= 200_000:
        raise InputError("invalid_summary_limit", "Summary limit must be an integer from 0 to 200000")
    return value


def limit_summary_findings(summary: dict, maximum_findings: int | None = None) -> dict:
    """Detach a summary and optionally retain its first selected detail rows.

    Full source counts, identity and selection metadata remain intact. This is a
    presentation bound only; omitted rows do not become supported or resolved.
    """
    maximum = validate_summary_limit(maximum_findings)
    result = deepcopy(summary)
    if maximum is None:
        return result
    selected_count = len(result["findings"])
    result["findings"] = result["findings"][:maximum]
    returned_count = len(result["findings"])
    result["finding_limit"] = {
        "maximum": maximum,
        "returned_count": returned_count,
        "omitted_count": selected_count - returned_count,
        "selected_count": selected_count,
    }
    return result
