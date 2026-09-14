#!/usr/bin/env python3
"""Validate packages/contracts examples against their schemas.

Two example shapes exist:

* Document schemas (top-level `type: object`): `examples/<name>.example.json`
  and `examples/<name>.<variant>.example.json` are single instances.
* Message-set schemas (top-level `oneOf` over `$defs`): the example file is an
  object keyed by def name, each value an instance of that def.

Every schema must also parse as a schema. Requires `pip install jsonschema`.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

try:
    import jsonschema
except ImportError:  # pragma: no cover
    print("pip install jsonschema", file=sys.stderr)
    sys.exit(2)

ROOT = Path(__file__).resolve().parents[1] / "packages" / "contracts" / "schemas"


def examples_for(name: str) -> list[Path]:
    exact = ROOT / "examples" / f"{name}.example.json"
    variants = sorted((ROOT / "examples").glob(f"{name}.*.example.json"))
    return ([exact] if exact.exists() else []) + variants


def validate(cls, schema: dict, instance, label: str) -> bool:
    try:
        cls(schema).validate(instance)
        print(f"ok   {label}")
        return True
    except jsonschema.ValidationError as e:
        path = "/".join(str(p) for p in e.absolute_path) or "<root>"
        print(f"FAIL {label} at {path}: {e.message[:200]}")
        return False


def main() -> int:
    failures = 0
    schemas = sorted(ROOT.glob("*.schema.json"))
    if not schemas:
        print(f"no schemas under {ROOT}", file=sys.stderr)
        return 1
    for schema_path in schemas:
        schema = json.loads(schema_path.read_text())
        cls = jsonschema.validators.validator_for(schema)
        try:
            cls.check_schema(schema)
        except jsonschema.SchemaError as e:
            print(f"INVALID SCHEMA {schema_path.name}: {e.message}")
            failures += 1
            continue
        name = schema_path.name.removesuffix(".schema.json")
        defs = schema.get("$defs") or {}
        message_set = "type" not in schema and bool(defs)
        for ex in examples_for(name):
            instance = json.loads(ex.read_text())
            rel = ex.relative_to(ROOT)
            if message_set:
                if not isinstance(instance, dict):
                    print(f"FAIL {rel}: expected an object keyed by $defs name")
                    failures += 1
                    continue
                for key, value in instance.items():
                    if key not in defs:
                        print(f"FAIL {rel}: key {key!r} is not a $def of {schema_path.name}")
                        failures += 1
                        continue
                    sub = {k: v for k, v in schema.items() if k in ("$schema", "$id", "$defs")}
                    sub["$ref"] = f"#/$defs/{key}"
                    if not validate(cls, sub, value, f"{rel}#{key} ⊨ {schema_path.name}"):
                        failures += 1
            elif not validate(cls, schema, instance, f"{rel} ⊨ {schema_path.name}"):
                failures += 1
        if not examples_for(name):
            print(f"ok   {schema_path.name} (no examples)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
