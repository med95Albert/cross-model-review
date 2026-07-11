#!/usr/bin/env bash
# cross-model-review 解除安裝：移除 skill 與 Stop hook。
# 預設保留審查證據（_state），加 --purge 一併刪除。
set -euo pipefail

CLAUDE_DIR="${HOME}/.claude"
SKILL_DEST="${CLAUDE_DIR}/skills/cross-model-review"
SETTINGS="${CLAUDE_DIR}/settings.json"
STATE_ROOT="${CROSS_REVIEW_STATE_ROOT:-${CLAUDE_DIR}/cross-model-review/state}"
PURGE="${1:-}"

say(){ printf '%s\n' "$*"; }

if [ -f "${SETTINGS}" ]; then
  python3 - "${SETTINGS}" <<'PY'
import json, sys
path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as f:
        cfg = json.load(f)
except Exception:
    sys.exit(0)
hooks = cfg.get("hooks")
if isinstance(hooks, dict) and isinstance(hooks.get("Stop"), list):
    new = []
    for g in hooks["Stop"]:
        if not isinstance(g, dict):
            new.append(g); continue
        kept = [h for h in g.get("hooks", [])
                if not ("review-gate.py" in str((h or {}).get("command", ""))
                        and "cross-model-review" in str((h or {}).get("command", "")))]
        if kept:
            g = {**g, "hooks": kept}
            new.append(g)
    if new:
        hooks["Stop"] = new
    else:
        del hooks["Stop"]
    if not hooks:
        del cfg["hooks"]
    with open(path, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
        f.write("\n")
PY
  say "✓ 已從 settings.json 移除 Stop hook"
fi

rm -rf "${SKILL_DEST}"
say "✓ 已移除 skill 目錄 ${SKILL_DEST}"

if [ "${PURGE}" = "--purge" ]; then
  rm -rf "${STATE_ROOT}"
  say "✓ 已刪除審查證據 ${STATE_ROOT}""（含 CROSS_REVIEW_STATE_ROOT 指定位置）"
else
  say "（保留審查證據 ${STATE_ROOT}；要一併刪除請加 --purge）"
fi

say "重開 Claude Code session 後生效。"
