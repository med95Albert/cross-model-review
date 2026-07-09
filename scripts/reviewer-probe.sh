#!/usr/bin/env bash
# cross-model-review Gate 1: 審查者資格探測（零 token）。
# 印診斷行，最後一行 REVIEWER=codex|subagent。exit 0 = codex 可用；1 = 降級 subagent。
set -u
ok=1
say(){ printf '%s\n' "$*"; }

if ! command -v codex >/dev/null 2>&1; then
  say "－ codex CLI 不存在"
  say "REVIEWER=subagent"; exit 1
fi
say "＋ codex: $(command -v codex)（$(codex --version 2>/dev/null | head -1)）"

H=$(codex exec --help 2>&1) || { say "－ codex exec --help 失敗"; say "REVIEWER=subagent"; exit 1; }
for f in "--json" "resume" "--output-last-message" "--sandbox" "--skip-git-repo-check"; do
  if printf '%s' "$H" | grep -q -- "$f"; then say "＋ 支援 $f"; else say "－ 不支援 $f"; ok=0; fi
done

LS=$(codex login status 2>&1)
if printf '%s' "$LS" | grep -qi "logged in"; then
  say "＋ 登入：$(printf '%s' "$LS" | head -1)"
else
  say "？ 登入狀態不明（$(printf '%s' "$LS" | head -1)）——round 1 失敗即降級"
fi

# 裁判校準姿態（黃金集，見 calibrate.sh）：RED = fail-closed，所有工件視同 🔴
GATE="$(cd "$(dirname "$0")" && pwd)/review-gate.py"
CALMSG=$(python3 "${GATE}" --calibration-check 2>&1)
calrc=$?
if [ "${calrc}" -eq 0 ]; then
  say "＋ 校準：${CALMSG}"
  say "POSTURE=GREEN"
else
  say "？ 校準：${CALMSG}"
  say "  → fail-closed：本次所有工件視同 🔴（APPROVED 後仍需人工簽核）；跑 scripts/calibrate.sh 重建基線"
  say "POSTURE=RED"
fi

if [ "$ok" -eq 1 ]; then say "REVIEWER=codex"; exit 0; else say "REVIEWER=subagent"; exit 1; fi
