"""Export-only MacScope companion contract. No undocumented API is invoked."""
from __future__ import annotations

from copy import deepcopy
import re
import uuid as uuid_module

from .report import validate_report
from .types import InputError


def make_handoff(report: dict, finding_id: str) -> dict:
    validate_report(report)
    finding = next((item for item in report["findings"] if item["id"] == finding_id), None)
    if finding is None:
        raise InputError("unknown_finding", "The selected finding ID is not present in this report")
    function, image = finding["function"], report["image"]
    return {
        "schema_version": 1,
        "report_kind": "airs.macscope_handoff",
        "integration_status": "proposed_export_contract",
        "image": {key: image.get(key) for key in ("display_name", "uuid", "architecture", "cpu_subtype", "container_sha256", "slice_sha256", "slice_offset", "slice_size", "preferred_base")},
        "selection": {"finding_id": finding_id, "function_name": function["name"], "address_space": "preferred_vm", "vm_range": {"start": function["address"], "end": function["end_address"]}, "image_relative_range": {"start": function["image_offset"], "end": hex(int(function["image_offset"], 16) + function["size"])}},
        "finding": deepcopy({key: finding[key] for key in ("verdict", "coverage", "mode", "scope", "reason_codes", "checked_pcs", "evidence", "limitations")}),
        "source_analysis": deepcopy(report["generator"]),
        "requirements": ["Verify architecture and selected-slice SHA-256 before applying an address to an open image.", "Use UUID as additional image identity when present; a matching filename is insufficient.", "Addresses are preferred unslid VM addresses; apply a verified runtime slide only in a runtime-aware adapter.", "This export defines a proposed adapter contract. It does not assume an existing MacScope GUI deep link or import command."],
    }


def destination_matches(handoff: dict, *, architecture: str, slice_sha256: str, uuid: str | None = None) -> bool:
    """Minimum identity gate for a future adapter. Does not open or modify apps."""
    if not isinstance(handoff, dict) or type(handoff.get("schema_version")) is not int or handoff.get("schema_version") != 1 or handoff.get("report_kind") != "airs.macscope_handoff":
        return False
    image = handoff.get("image")
    if not isinstance(image, dict) or architecture not in ("arm64", "arm64e"):
        return False
    if not isinstance(slice_sha256, str) or not re.fullmatch(r"[0-9a-f]{64}", slice_sha256):
        return False
    if image.get("architecture") != architecture or image.get("slice_sha256") != slice_sha256:
        return False
    source_uuid = image.get("uuid")
    if source_uuid is None:
        return True
    if not isinstance(source_uuid, str) or not isinstance(uuid, str):
        return False
    try:
        return uuid_module.UUID(source_uuid) == uuid_module.UUID(uuid)
    except ValueError:
        return False
