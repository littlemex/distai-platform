import sys
import re
import yaml

path, kind = sys.argv[1], sys.argv[2]
name_re = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else None
field = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else None

with open(path, encoding="utf-8") as f:
    docs = [d for d in yaml.safe_load_all(f) if d]

for d in docs:
    if d.get("kind") != kind:
        continue
    name = (d.get("metadata") or {}).get("name", "")
    if name_re and not re.search(name_re, name):
        continue
    if field:
        cur = d
        for part in field.split("."):
            cur = cur.get(part) if isinstance(cur, dict) else None
        print(f"{name}: {cur!r}")
    else:
        print(name)
