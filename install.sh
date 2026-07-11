#!/usr/bin/env bash
# cross-model-review 一鍵安裝器（標準 skills/<name>/ 佈局）
# 在任何位置執行皆可：從 repo 的 skills/cross-model-review/ 複製到 ~/.claude/skills/ 並註冊 hook
# 全程只寫入你自己的 ~/.claude/，可安全重複執行（idempotent）。
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${HOME}/.claude"
SKILL_DEST="${CLAUDE_DIR}/skills/cross-model-review"
SETTINGS="${CLAUDE_DIR}/settings.json"
STATE_DIR="${CLAUDE_DIR}/cross-model-review/state"
HOOK_CMD="python3 ${SKILL_DEST}/scripts/review-gate.py"

say(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }

say "== cross-model-review 安裝器 v1.1 =="

command -v python3 >/dev/null 2>&1 || die "找不到 python3——閘門與腳本需要它，請先安裝 Python 3。"
say "✓ python3：$(python3 --version 2>&1)"
SKILL_SRC="${SELF_DIR}/skills/cross-model-review"
[ -f "${SKILL_SRC}/SKILL.md" ] || die "找不到 ${SKILL_SRC}/SKILL.md（請在 repo 資料夾內執行本腳本）。"

if command -v codex >/dev/null 2>&1; then
  say "✓ codex CLI：$(codex --version 2>&1 | head -1)"
  if codex login status >/dev/null 2>&1; then
    say "✓ codex 已登入（可跨模型審查）"
  else
    say "⚠ codex 未登入——請先完成登入；否則審查降級為同模型 subagent。"
  fi
else
  say "⚠ 找不到 codex CLI——審查將降級為『同模型、新視角』subagent（仍可用，少了跨模型去相關）。"
fi

mkdir -p "${CLAUDE_DIR}"

mkdir -p "${SKILL_DEST}/scripts"
cp "${SKILL_SRC}/SKILL.md" "${SKILL_SRC}/CHANGELOG.md" "${SKILL_DEST}/"
cp "${SKILL_SRC}/scripts/"*.py "${SKILL_SRC}/scripts/"*.sh "${SKILL_DEST}/scripts/"
rm -rf "${SKILL_DEST}/scripts/gold-seed"
cp -R "${SKILL_SRC}/scripts/gold-seed" "${SKILL_DEST}/scripts/"
cp "${SELF_DIR}/uninstall.sh" "${SELF_DIR}/selftest.sh" "${SKILL_DEST}/" 2>/dev/null || true
chmod +x "${SKILL_DEST}/uninstall.sh" "${SKILL_DEST}/selftest.sh" 2>/dev/null || true
say "✓ skill 已複製到 ${SKILL_DEST}（含 uninstall.sh／selftest.sh 常駐維運工具）"
chmod +x "${SKILL_DEST}/scripts/"*.sh "${SKILL_DEST}/scripts/"*.py

mkdir -p "${STATE_DIR}"
say "✓ 審查證據目錄：${STATE_DIR}"

set +e
RESULT="$(python3 - "${SETTINGS}" "${HOOK_CMD}" <<'PY'
import json, os, sys
path, cmd = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as f:
        cfg = json.load(f)
except FileNotFoundError:
    cfg = {}
except json.JSONDecodeError as e:
    print(f"SETTINGS_CORRUPT: {e}", file=sys.stderr)
    sys.exit(3)
if not isinstance(cfg, dict):
    print("SETTINGS_CORRUPT: root is not an object", file=sys.stderr)
    sys.exit(3)
hooks = cfg.setdefault("hooks", {})
if not isinstance(hooks, dict):
    hooks = cfg["hooks"] = {}
stop = hooks.setdefault("Stop", [])
if not isinstance(stop, list):
    stop = hooks["Stop"] = []
found = False
for group in stop:
    if not isinstance(group, dict):
        continue
    for h in group.get("hooks", []):
        if isinstance(h, dict) and "review-gate.py" in str(h.get("command", "")):
            h["command"] = cmd
            found = True
if not found:
    stop.append({"hooks": [{"type": "command", "command": cmd}]})
os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
with open(path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
    f.write("\n")
print("updated" if found else "added")
PY
)"
merge_rc=$?
set -e
if [ "${merge_rc}" -ne 0 ]; then
  die "偵測到 ${SETTINGS} 已損壞（非合法 JSON 或根非物件）。為保護你的既有設定，安裝器不會覆寫它——請先手動修復該檔再重跑。原檔未被更動。"
fi
if [ "${RESULT}" = "added" ]; then
  say "✓ Stop hook 已註冊於 ${SETTINGS}"
else
  say "✓ Stop hook 已更新路徑於 ${SETTINGS}（偵測到既有安裝）"
fi

say ""
say "== 煙霧測試（零 token）=="
bash "${SKILL_DEST}/scripts/reviewer-probe.sh" || true
TMP="$(mktemp -d)"; printf '# smoke\n' > "${TMP}/x.md"
python3 "${SKILL_DEST}/scripts/review-gate.py" --sha "${TMP}/x.md" >/dev/null 2>&1 \
  && say "✓ review-gate.py 可執行" || say "⚠ review-gate.py 自檢異常，請回報"
rm -rf "${TMP}"

say ""
say "== 安裝完成 =="
say "① 重開一個 Claude Code session 讓 hook 生效。"
say "② 建議首跑裁判校準（約 6 次 codex 呼叫）：bash \"${SKILL_DEST}/scripts/calibrate.sh\""
say "   未校準時系統 fail-closed：審查照跑，但 APPROVED 仍需你簽核。"
say "③ 驗證：請 Claude 在任意專案 plans/ 下寫一份 .md，回合結束應被攔下審查。"
say "④ 進階自測（零 token，結尾自報條數）：bash \"${SKILL_DEST}/selftest.sh\""
say "⑤ 解除安裝：bash \"${SKILL_DEST}/uninstall.sh\"（--purge 連證據一併刪）"
