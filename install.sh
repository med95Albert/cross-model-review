#!/usr/bin/env bash
# cross-model-review 一鍵安裝器（根目錄即技能佈局）
# 兩種執行情境皆支援：
#   A) repo 已被 clone 到 ~/.claude/skills/cross-model-review（一句話安裝路徑）→ 原地註冊，跳過複製
#   B) repo 在任何其他位置（下載解壓／clone 到別處）→ 複製 skill 後註冊
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
[ -f "${SELF_DIR}/SKILL.md" ] || die "找不到 ${SELF_DIR}/SKILL.md（請在 repo 資料夾內執行本腳本）。"

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

if [ "${SELF_DIR}" = "${SKILL_DEST}" ]; then
  say "✓ 偵測到 repo 已在 ${SKILL_DEST}（一句話安裝路徑）——原地使用，跳過複製"
else
  mkdir -p "${SKILL_DEST}/scripts"
  cp "${SELF_DIR}/SKILL.md" "${SELF_DIR}/CHANGELOG.md" "${SKILL_DEST}/"
  cp "${SELF_DIR}/scripts/"*.py "${SELF_DIR}/scripts/"*.sh "${SKILL_DEST}/scripts/"
  rm -rf "${SKILL_DEST}/scripts/gold-seed"
  cp -R "${SELF_DIR}/scripts/gold-seed" "${SKILL_DEST}/scripts/"
  say "✓ skill 已複製到 ${SKILL_DEST}"
fi
chmod +x "${SKILL_DEST}/scripts/"*.sh "${SKILL_DEST}/scripts/"*.py

mkdir -p "${STATE_DIR}"
say "✓ 審查證據目錄：${STATE_DIR}"

RESULT="$(python3 - "${SETTINGS}" "${HOOK_CMD}" <<'PY'
import json, os, sys
path, cmd = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as f:
        cfg = json.load(f)
    if not isinstance(cfg, dict):
        cfg = {}
except (FileNotFoundError, json.JSONDecodeError):
    cfg = {}
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
say "④ 進階自測（52 條，零 token）：bash \"${SELF_DIR}/selftest.sh\""
say "⑤ 解除安裝：bash \"${SELF_DIR}/uninstall.sh\"（--purge 連證據一併刪）"
