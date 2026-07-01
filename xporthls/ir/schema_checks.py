from __future__ import annotations

from typing import Any


def check_application_ir_schema(app: dict[str, Any]) -> list[dict[str, Any]]:
    issues: list[dict[str, Any]] = []

    facts = app.get("facts")
    if not isinstance(facts, dict):
        issues.append({
            "severity": "error",
            "code": "APP_IR_NO_FACTS",
            "message": "ApplicationIR v1 requires a facts object."
        })
        return issues

    if facts.get("schema_version") != "application_ir.v1":
        issues.append({
            "severity": "warning",
            "code": "APP_IR_SCHEMA_VERSION_UNKNOWN",
            "message": f"Unexpected ApplicationIR schema version: {facts.get('schema_version')}"
        })

    for key in ["xrt", "hls", "build", "tests"]:
        if key not in facts or not isinstance(facts[key], dict):
            issues.append({
                "severity": "error",
                "code": f"APP_IR_FACTS_MISSING_{key.upper()}",
                "message": f"ApplicationIR facts.{key} is missing or not an object."
            })

    if not isinstance(app.get("llm_annotations", []), list):
        issues.append({
            "severity": "error",
            "code": "APP_IR_LLM_ANNOTATIONS_NOT_LIST",
            "message": "ApplicationIR llm_annotations must be a list."
        })

    if not isinstance(app.get("unknowns", []), list):
        issues.append({
            "severity": "error",
            "code": "APP_IR_UNKNOWNS_NOT_LIST",
            "message": "ApplicationIR unknowns must be a list."
        })

    # Safety rule: LLM annotations must be marked as annotations, not facts.
    for idx, ann in enumerate(app.get("llm_annotations", [])):
        if not isinstance(ann, dict):
            issues.append({
                "severity": "warning",
                "code": "APP_IR_LLM_ANNOTATION_NOT_OBJECT",
                "message": f"llm_annotations[{idx}] is not an object."
            })
            continue

        if ann.get("source") != "llm":
            issues.append({
                "severity": "warning",
                "code": "APP_IR_LLM_ANNOTATION_SOURCE",
                "message": f"llm_annotations[{idx}] should explicitly use source='llm'."
            })

        if "requires_validation" not in ann:
            issues.append({
                "severity": "warning",
                "code": "APP_IR_LLM_ANNOTATION_VALIDATION_FLAG",
                "message": f"llm_annotations[{idx}] should include requires_validation."
            })

    return issues
