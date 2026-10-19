#!/usr/bin/env python3
"""Regenerate the documented JSON Schema v1 contracts. No network is used."""
import json
import argparse
from pathlib import Path

DESTINATION = Path(__file__).resolve().parents[1] / "schemas"
DESTINATION.mkdir(exist_ok=True)


def obj(properties, required=None):
    return {"type": "object", "properties": properties, "required": list(properties) if required is None else required, "additionalProperties": True}


def arr(items, maximum=200000):
    return {"type": "array", "items": items, "maxItems": maximum}


STRING = {"type": "string", "maxLength": 65536}
INTEGER = {"type": "integer", "minimum": 0}
ADDRESS = {"type": "string", "pattern": "^0x[0-9a-f]{1,16}$"}
ENCODING = {"type": "string", "pattern": "^0x[0-9a-f]{1,8}$"}
DIGEST = {"type": "string", "pattern": "^[0-9a-f]{64}$"}
ID = {"type": "string", "pattern": "^airsf-[0-9a-f]{64}$"}
VERDICT = {"enum": ["agreement", "inconsistency", "unresolved"]}
SCOPE = {"enum": ["synchronous_call_sites", "modeled_leaf_body", "metadata_only"]}
MODE = {"enum": ["frame", "frameless", "dwarf", "pauth_frame", "none", "unknown"]}
COVERAGE = {"enum": ["compact", "dwarf_reference", "dwarf_evaluated", "none", "unavailable"]}
GENERATOR = obj({"name": STRING, "version": STRING, "analysis_model_version": STRING})
LIMITS = {"type": "object", "additionalProperties": INTEGER}
ANALYSIS_CONFIG = obj({"limits": LIMITS})
EVIDENCE = obj({"code": STRING, "message": STRING, "address": ADDRESS, "expected": STRING, "observed": STRING}, ["code", "message"])
IMAGE = obj({"display_name": STRING, "path": STRING, "architecture": {"enum": ["arm64", "arm64e"]}, "cpu_subtype": INTEGER, "uuid": {"type": ["string", "null"]}, "container_sha256": DIGEST, "slice_sha256": DIGEST, "slice_offset": INTEGER, "slice_size": INTEGER, "preferred_base": ADDRESS, "file_type": {"enum": ["execute", "dylib", "bundle"]}}, ["display_name", "architecture", "cpu_subtype", "container_sha256", "slice_sha256", "slice_offset", "slice_size", "preferred_base", "file_type"])
FUNCTION = obj({"name": STRING, "address": ADDRESS, "end_address": ADDRESS, "image_offset": ADDRESS, "size": {"type": "integer", "minimum": 1}, "boundary_source": STRING})
ANALYSIS = {"verdict": VERDICT, "coverage": COVERAGE, "mode": MODE, "scope": SCOPE, "reason_codes": arr(STRING), "checked_pcs": arr(ADDRESS), "evidence": arr(EVIDENCE), "limitations": arr(STRING)}
FINDING = obj({"id": ID, "function": FUNCTION, **ANALYSIS, "encoding": {"anyOf": [ENCODING, {"type": "null"}]}, "instruction_count": INTEGER}, ["id", "function", *ANALYSIS, "instruction_count"])
SUMMARY = obj({key: INTEGER for key in ("function_count", "agreement_count", "inconsistency_count", "unresolved_count", "metadata_entry_count", "checked_pc_count")})
AUDIT = obj({"schema_version": {"const": 1}, "report_kind": {"const": "airs.audit"}, "generator": GENERATOR, "analysis_config": ANALYSIS_CONFIG, "image": IMAGE, "summary": SUMMARY, "issues": arr(obj({"code": STRING, "message": STRING, "offset": INTEGER}, ["code", "message"])), "metadata_ranges": arr(obj({"start": ADDRESS, "end": ADDRESS, "encoding": ENCODING, "mode": MODE})), "findings": arr(FINDING, 50000), "limitations": arr(STRING)}, ["schema_version", "report_kind", "generator", "image", "summary", "issues", "metadata_ranges", "findings", "limitations"])

SHORT_IMAGE = obj({"display_name": STRING, "uuid": {"type": ["string", "null"]}, "slice_sha256": DIGEST, "architecture": STRING})
DIFF_SUMMARY = obj({key: INTEGER for key in ("matched_count", "changed_count", "unchanged_count", "added_count", "removed_count", "ambiguous_count")})
CHANGE = obj({"key": STRING, "match_basis": {"enum": ["exact_image_offset", "unique_symbol", "unmatched"]}, "function_name": STRING, "change": {"enum": ["changed", "unchanged", "added", "removed", "ambiguous"]}, "notes": arr(STRING), "baseline_id": ID, "current_id": ID, "before_verdict": VERDICT, "after_verdict": VERDICT, "before_scope": SCOPE, "after_scope": SCOPE}, ["key", "match_basis", "function_name", "change", "notes"])
DIFF = obj({"schema_version": {"const": 1}, "report_kind": {"const": "airs.diff"}, "comparison": obj({"baseline_image": SHORT_IMAGE, "current_image": SHORT_IMAGE, "same_image": {"type": "boolean"}, "model_compatible": {"type": "boolean"}, "analysis_configuration_changed": {"type": "boolean"}, "matching_policy": {"const": "exact_digest_then_unique_symbol"}}, ["baseline_image", "current_image", "same_image", "model_compatible", "matching_policy"]), "summary": DIFF_SUMMARY, "changes": arr(CHANGE), "limitations": arr(STRING)})
HANDOFF_IMAGE = obj({key: value for key, value in IMAGE["properties"].items() if key not in ("path", "file_type")})
RANGE = obj({"start": ADDRESS, "end": ADDRESS})
HANDOFF = obj({"schema_version": {"const": 1}, "report_kind": {"const": "airs.macscope_handoff"}, "integration_status": {"const": "proposed_export_contract"}, "image": HANDOFF_IMAGE, "selection": obj({"finding_id": ID, "function_name": STRING, "address_space": {"const": "preferred_vm"}, "vm_range": RANGE, "image_relative_range": RANGE}), "finding": obj(ANALYSIS), "source_analysis": GENERATOR, "requirements": arr(STRING)})

SOURCE_IDENTITY = obj({key: IMAGE["properties"][key] for key in ("architecture", "cpu_subtype", "uuid", "slice_sha256", "preferred_base", "container_sha256", "slice_offset", "slice_size")})
SOURCE_ATTACHMENT = obj({"path": {"type": "string", "maxLength": 4096, "minLength": 1}, "architecture": IMAGE["properties"]["architecture"], "cpu_subtype": INTEGER, "uuid": STRING, "slice_sha256": DIGEST, "slice_offset": INTEGER, "slice_size": {"type": "integer", "minimum": 0, "maximum": 128 * 1024 * 1024}})
LOCATION = obj({"path": {"type": "string", "minLength": 1, "maxLength": 4096}, "line": INTEGER, "column": INTEGER, "discriminator": INTEGER, "source_status": {"enum": ["available_unverified", "missing", "unavailable", "relative_path_unresolved"]}})
FUNCTION_SOURCE = obj({"finding_id": ID, "pc": ADDRESS, "status": {"enum": ["mapped", "ambiguous_line", "no_line_entry"]}, "name_status": {"enum": ["unique", "duplicate"]}, "candidate_count": {"type": "integer", "minimum": 0, "maximum": 200000}, "locations": arr(LOCATION, 8)})
SOURCE = obj({"schema_version": {"const": 1}, "status": {"enum": ["matched", "missing_dsym", "missing_image_uuid", "missing_dsym_uuid", "uuid_mismatch", "architecture_mismatch", "ambiguous_dsym", "missing_line_table", "invalid_dsym", "invalid_debug_data", "unsupported_debug_format", "resource_limit"]}, "image_identity": SOURCE_IDENTITY, "attachment": {"anyOf": [SOURCE_ATTACHMENT, {"type": "null"}]}, "inline_chain": {"const": "not_evaluated"}, "functions": arr(FUNCTION_SOURCE, 50000), "message": {"type": "string", "maxLength": 4096}, "limitations": arr({"type": "string", "maxLength": 4096}, 32)})
AUDIT["properties"]["source_annotations"] = {"anyOf": [SOURCE, {"type": "null"}]}

schemas = (("audit-report", AUDIT), ("baseline-diff", DIFF), ("macscope-handoff", HANDOFF), ("source-annotations", SOURCE))
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--only", action="append", choices=[name for name, _ in schemas], help="Write only selected changed contracts")
args = parser.parse_args()
written = 0
for name, schema in schemas:
    if args.only and name not in args.only:
        continue
    schema = {"$schema": "https://json-schema.org/draft/2020-12/schema", "$id": f"urn:airs:schema:{name}:1", "title": f"AIRS {name} v1", **schema}
    (DESTINATION / f"{name}-v1.schema.json").write_text(json.dumps(schema, indent=2) + "\n", encoding="utf-8")
    written += 1
print(f"Wrote {written} JSON Schema v1 contracts")
