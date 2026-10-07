#!/usr/bin/env bash
set -euo pipefail

manager=/usr/bin/denial-plugins
log_dir=$(mktemp -d /tmp/nextdenial-activate.XXXXXX)
printf '构建日志：%s\n' "$log_dir"

"$manager" prepare
"$manager" plan > "$log_dir/plan.log" 2>&1 || {
  cat "$log_dir/plan.log"
  exit 1
}
"$manager" status > "$log_dir/planned-status.json"
candidate=$(python3 - "$log_dir/planned-status.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    candidate = json.load(f)['lastPlan']['id']
if not isinstance(candidate, str) or not candidate or '/' in candidate:
    raise SystemExit('无法读取新候选 ID')
print(candidate)
PY
)
printf '构建候选：%s\n' "$candidate"
"$manager" build "$candidate" 2>&1 | tee "$log_dir/build.log"
"$manager" activate "$candidate" 2>&1 | tee "$log_dir/activate.log"
"$manager" status > "$log_dir/activated-status.json"
python3 - "$log_dir/activated-status.json" "$candidate" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    status = json.load(f)
candidate = sys.argv[2]
def states(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from states(child)
    elif isinstance(value, list):
        for child in value:
            yield from states(child)
for state in states(status.get('native', {})):
    if (state.get('plugin_healthy') is True
            and str(state.get('plugin_bundle', '')).rstrip('/').endswith('/' + candidate + '/bundle')):
        print('构建并激活成功：' + candidate)
        print('plugin_healthy: true')
        raise SystemExit(0)
raise SystemExit('未确认新候选健康运行，请检查日志；不要将此结果视为激活成功。')
PY
