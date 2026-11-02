#!/usr/bin/env python3
"""Validate a finder result against schemas/findings.schema.json.

Usage: validate-findings.py <schema.json> <findings.json>
Prints the finding count on success. Exits 1 with every violation on failure.
Covers the schema keywords the panel uses: type, required, properties,
additionalProperties false, items and enum. Standard library only.
"""
import json
import sys

TYPES = {"object": dict, "array": list, "string": str, "integer": int}


def check(schema, value, path, errors):
    want = schema.get("type")
    if want:
        ok = isinstance(value, TYPES[want]) and not (want == "integer" and isinstance(value, bool))
        if not ok:
            errors.append(f"{path}: expected {want}, got {type(value).__name__}")
            return
    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{path}: {value!r} is not one of {schema['enum']}")
    if want == "object":
        props = schema.get("properties", {})
        for key in schema.get("required", []):
            if key not in value:
                errors.append(f"{path}: missing required key '{key}'")
        if schema.get("additionalProperties") is False:
            for key in value:
                if key not in props:
                    errors.append(f"{path}: unexpected key '{key}'")
        for key, sub in props.items():
            if key in value:
                check(sub, value[key], f"{path}.{key}", errors)
    if want == "array" and "items" in schema:
        for i, item in enumerate(value):
            check(schema["items"], item, f"{path}[{i}]", errors)


def main():
    if len(sys.argv) != 3:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    schema = json.load(open(sys.argv[1]))
    try:
        data = json.load(open(sys.argv[2]))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"FAIL: {sys.argv[2]} is not readable JSON: {exc}", file=sys.stderr)
        return 1
    errors = []
    check(schema, data, "$", errors)
    if errors:
        print(f"FAIL: {sys.argv[2]} does not match {sys.argv[1]}:", file=sys.stderr)
        for err in errors:
            print(f"  {err}", file=sys.stderr)
        return 1
    print(len(data["findings"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
