set -euo pipefail
cp -r . /tmp/mutated-repo
python3 -c "
import yaml
path = '/tmp/mutated-repo/gitops/addons/accel-nvidia-device-plugin/addon.yaml'
with open(path) as f:
    doc = yaml.safe_load(f)
doc['values']['tolerations'] = [t for t in doc['values']['tolerations'] if t.get('key') != 'CriticalAddonsOnly']
with open(path, 'w') as f:
    yaml.safe_dump(doc, f, default_flow_style=False)
"
echo "=== mutated tolerations ==="
python3 -c "
import yaml
print(yaml.safe_load(open('/tmp/mutated-repo/gitops/addons/accel-nvidia-device-plugin/addon.yaml'))['values']['tolerations'])
"
echo "=== running check_startup_taint_renders.py against the MUTATED copy (expect FAIL) ==="
uv run --no-project -q --with pyyaml==6.0.2 python3 gitops/tests/check_startup_taint_renders.py /tmp/mutated-repo || echo "(exit code: $?)"
echo "=== running check_startup_taint_renders.py against the REAL committed branch (expect PASS) ==="
uv run --no-project -q --with pyyaml==6.0.2 python3 gitops/tests/check_startup_taint_renders.py "$(pwd)" || echo "(exit code: $?)"
