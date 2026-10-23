"""Select summary detail rows without changing the full-report denominator."""
from __future__ import annotations

from copy import deepcopy

from .types import InputError
from .coverage import validate_reason_selection

VERDICT_ORDER = ("agreement", "inconsistency", "unresolved")


def validate_summary_verdicts(verdicts: list[str] | tuple[str, ...] | None) -> tuple[str, ...] | None:
    """Validate before report I/O; return unique codes in stable verdict order.

    None means no selection. An explicitly empty selection is rejected, as are
    bare strings and unknown/non-string values. This helper performs no I/O.
    """
    if verdicts is None:
        return None
    if (not isinstance(verdicts, (list, tuple)) or not verdicts
            or any(not isinstance(v, str) or v not in VERDICT_ORDER for v in verdicts)):
        raise InputError("invalid_summary_verdict", "Select one or more of: agreement, inconsistency, unresolved")
    return tuple(v for v in VERDICT_ORDER if v in verdicts)


def validate_summary_reasons(reason_codes: list[str] | tuple[str, ...] | None) -> list[str] | None:
    """Validate literal reason identifiers before report I/O using shared limits."""
    if reason_codes is not None and not isinstance(reason_codes, (list, tuple)):
        raise InputError("invalid_reason_code", "Reason selection must be a list or tuple of identifiers")
    return validate_reason_selection(reason_codes)


def select_summary_findings(summary: dict, verdicts: list[str] | tuple[str, ...] | None = None,
                            *, reason_codes: list[str] | tuple[str, ...] | None = None) -> dict:
    """Detach an existing summarize_report output and optionally select details.

    Counts, identity, limits, metadata and reasons continue to describe the full
    source report. The input must be the complete, unselected summary. This is
    presentation-only: no new verdicts or whole-image conclusions are produced.
    """
    requested = validate_summary_verdicts(verdicts)
    requested_reasons = validate_summary_reasons(reason_codes)
    result = deepcopy(summary)
    if requested is None and requested_reasons is None:
        return result
    original_count = len(result["findings"])
    result["findings"] = [finding for finding in result["findings"]
                          if (requested is None or finding["verdict"] in requested)
                          and (requested_reasons is None or any(
                              reason in requested_reasons for reason in finding["reason_codes"]))]
    selected_count = len(result["findings"])
    result["finding_selection"] = {
        "requested": list(requested) if requested is not None else [],
        "selected_count": selected_count,
        "omitted_count": original_count - selected_count,
        "original_count": original_count,
    }
    if requested_reasons is not None:
        result["finding_selection"]["requested_reasons"] = requested_reasons
    return result
