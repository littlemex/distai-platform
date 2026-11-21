"""Writes kubeconform JSON schemas from the openAPIV3Schema of CRD manifests.

kubeconform's pinned Kubernetes schemas cover built-in kinds only, so the
custom resources vllm/disagg-pd-llmd renders (Gateway API's HTTPRoute,
Gateway API Inference Extension's InferencePool) are validated against the
schemas in those projects' own pinned release manifests instead. Each served
version of each CRD becomes <out>/<group>/<kind lowercase>_<version>.json,
the layout kubeconform's -schema-location template
"<out>/{{ .Group }}/{{ .ResourceKind }}_{{ .ResourceAPIVersion }}.json"
reads. Objects with declared properties reject undeclared ones
(additionalProperties: false), unless the CRD marks them
x-kubernetes-preserve-unknown-fields, so a misspelled field fails rather
than passing unnoticed.

Usage: crd_to_jsonschema.py --out DIR CRD_MANIFEST.yaml [...]
"""

import argparse
import json
import os
import sys

import yaml


def close_objects(node):
    if isinstance(node, dict):
        if (
            "properties" in node
            and "additionalProperties" not in node
            and not node.get("x-kubernetes-preserve-unknown-fields")
        ):
            node["additionalProperties"] = False
        for v in node.values():
            close_objects(v)
    elif isinstance(node, list):
        for v in node:
            close_objects(v)
    return node


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("manifests", nargs="+")
    a = ap.parse_args()
    written = 0
    for path in a.manifests:
        with open(path, encoding="utf-8") as f:
            for doc in yaml.safe_load_all(f):
                if not isinstance(doc, dict) or doc.get("kind") != "CustomResourceDefinition":
                    continue
                spec = doc.get("spec") or {}
                group = spec.get("group")
                kind = ((spec.get("names") or {}).get("kind") or "").lower()
                for v in spec.get("versions") or []:
                    schema = ((v.get("schema") or {}).get("openAPIV3Schema"))
                    if not (group and kind and schema and v.get("served")):
                        continue
                    d = os.path.join(a.out, group)
                    os.makedirs(d, exist_ok=True)
                    with open(os.path.join(d, f"{kind}_{v['name']}.json"), "w", encoding="utf-8") as out:
                        json.dump(close_objects(schema), out)
                    written += 1
    if written == 0:
        print("no served CRD versions found", file=sys.stderr)
        return 1
    print(f"wrote {written} schema(s) under {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
