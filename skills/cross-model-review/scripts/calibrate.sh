#!/usr/bin/env bash
# cross-model-review 裁判校準：黃金集全跑，產出 calibration.json（Gate 1 姿態的依據）。
# 花費：每題 1 次 codex round-1 呼叫（種子集 6 題）。
# 觸發時機：首次安裝、codex 換版、超過效期（30 天）、或手動重跑。
# 黃金集在 $STATE_ROOT/gold/（首跑自動從 gold-seed/ 播種）。可自行加題：
#   放 gold/cases/<名>.md ＋ 在 gold/expected.json 補一筆——本機自加題天然 held-out，防過擬合。
# ⚠️ 題目檔內嚴禁任何「提示雷存在」的文字（審查者讀得到＝劇透；v1.0 踩過）。
# ⚠️ 乾淨題必須「相對空倉庫自足」：全新建、零外部引用——校準工作區是空的，
#    引用不存在的既有程式/事實會被證偽式裁判照規則打槍（裁判對、題目錯；首次基線實測踩過）。
# 通過規則：雷題全中（抓雷能力不打折）＋乾淨題至少 1 過（防裁判亂槍打鳥的假陽性）。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="${HERE}/review-gate.py"
STATE_ROOT="${CROSS_REVIEW_STATE_ROOT:-$(python3 "${GATE}" --state-root)}"
GOLD="${STATE_ROOT}/gold"

command -v codex >/dev/null 2>&1 || { echo "codex CLI 不存在——無法校準"; exit 2; }
CODEX_VER="$(codex --version 2>/dev/null | head -1)"
[ -z "${CODEX_VER}" ] && { echo "ERROR: 無法取得 codex 版本——裁判身分三要素不得缺席，拒絕產出校準紀錄。"; exit 2; }
# 只讀 config.toml——codex exec 實際用的就是它；env 變數不得影響「記錄什麼」（防記錄與真裁判脫鉤）
JUDGE_ID="$(python3 - "${GATE}" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("g", sys.argv[1])
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
print(g.current_judge_model() + "\t" + g.current_judge_effort())
PY
)"
JUDGE_MODEL="${JUDGE_ID%%$'\t'*}"
JUDGE_EFFORT="${JUDGE_ID##*$'\t'}"
if [ -z "${JUDGE_MODEL}" ]; then
  echo "ERROR: 無法識別裁判模型——請在 ~/.codex/config.toml 設定 model=\"...\"（codex 實際用誰、就記誰、就驗誰）。"
  echo "（缺模型識別的校準紀錄一律視為無效，直接失敗比產出立即無效的基線誠實。）"
  exit 2
fi
echo "裁判：${CODEX_VER}／model=${JUDGE_MODEL}@${JUDGE_EFFORT}"

if [ ! -d "${GOLD}/cases" ]; then
  mkdir -p "${GOLD}"
  cp -R "${HERE}/gold-seed/cases" "${GOLD}/cases"
  cp "${HERE}/gold-seed/expected.json" "${GOLD}/expected.json"
  echo "✓ 首跑：黃金集已播種到 ${GOLD}"
fi
[ -f "${GOLD}/expected.json" ] || { echo "缺 ${GOLD}/expected.json"; exit 2; }

TSV="$(mktemp)"
python3 - "${GOLD}/expected.json" > "${TSV}" <<'PY'
import json, sys
exp = json.load(open(sys.argv[1], encoding="utf-8"))
for name, v in exp["cases"].items():
    hit = "|".join(v.get("must_hit", [])) or "-"
    print(f"{name}\t{v['type']}\t{v['verdict']}\t{hit}")
PY

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RUNDIR="${GOLD}/runs/${STAMP}"
mkdir -p "${RUNDIR}"
RES="$(mktemp)"
while IFS=$'\t' read -r NAME TYPE WANTV HITPAT; do
  CF="${GOLD}/cases/${NAME}.md"
  if [ ! -f "${CF}" ]; then
    printf '%s\t%s\tMISSING-CASE-FILE\tfail\n' "${NAME}" "${TYPE}" >> "${RES}"
    echo "－ ${NAME}：題目檔不存在"
    continue
  fi
  D=$(mktemp -d "/tmp/cmr-cal.XXXXXXXX")
  mkdir -p "${D}/plans"
  cp "${CF}" "${D}/plans/case.md"
  codex exec --sandbox read-only --skip-git-repo-check -C "${D}" \
    -o "${D}/r1.txt" - <<CODEX_EOF > "${D}/events.jsonl" 2>&1
You are peer-reviewing a plan document. Treat it as a hypothesis to falsify — not a description to follow. Work only from primary sources: verify every claim about existing files against the real filesystem you can read; and check the document's own stated scope — every goal it commits to must be delivered by a concrete step in the document. Unsound or insecure design is itself a finding. If you genuinely cannot break the document from primary sources, it passes — do not manufacture issues.

# Document to review
${D}/plans/case.md

# Reporting discipline
Report at most the 5 highest-impact MAJOR issues, ranked by impact. Skip style preferences; the bar is: would this ship a bug, a broken workflow, or a security hole?

Output in this exact format:

## Verdict
APPROVED  (or)  ISSUES FOUND

## Major issues (omit if APPROVED)
- [issue]: [why it matters]
CODEX_EOF
  rc=$?
  if [ "${rc}" -ne 0 ] || [ ! -s "${D}/r1.txt" ]; then
    printf '%s\t%s\tCODEX-FAILED\tfail\n' "${NAME}" "${TYPE}" >> "${RES}"
    echo "－ ${NAME}：codex 失敗（exit ${rc}）"
    continue
  fi
  cp "${D}/r1.txt" "${RUNDIR}/${NAME}.txt"   # 逐題原文落檔（稽核用，不留在暫存區）
  GOTV=$(grep -A3 '## Verdict' "${D}/r1.txt" | grep -m1 -oE 'APPROVED|ISSUES FOUND' || echo "UNPARSEABLE")
  CASEOK="pass"
  [ "${GOTV}" = "${WANTV}" ] || CASEOK="fail"
  if [ "${HITPAT}" != "-" ] && [ "${CASEOK}" = "pass" ]; then
    grep -qiE "${HITPAT}" "${D}/r1.txt" || CASEOK="fail"
  fi
  printf '%s\t%s\t%s\t%s\n' "${NAME}" "${TYPE}" "${GOTV}" "${CASEOK}" >> "${RES}"
  if [ "${CASEOK}" = "pass" ]; then
    echo "＋ ${NAME}（${TYPE}）：${GOTV} ✓"
  else
    echo "－ ${NAME}（${TYPE}）：判 ${GOTV}、期望 ${WANTV}${HITPAT:+，或未命中特徵}——原文 ${D}/r1.txt"
  fi
done < "${TSV}"

python3 - "${RES}" "${STATE_ROOT}/calibration.json" "${CODEX_VER}" "${RUNDIR}" "${JUDGE_MODEL}" "${JUDGE_EFFORT}" <<'PY'
import json, sys, datetime, os
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
cases = {r[0]: {"type": r[1], "got": r[2], "pass": r[3] == "pass",
                "output": os.path.join(sys.argv[4], r[0] + ".txt")} for r in rows}
traps = [c for c in cases.values() if c["type"] == "trap"]
clean = [c for c in cases.values() if c["type"] == "clean"]
traps_pass = bool(traps) and all(c["pass"] for c in traps)
clean_pass = bool(clean) and any(c["pass"] for c in clean)  # 零乾淨題＝假陽性方向未測，不得 PASS
overall = "PASS" if (traps_pass and clean_pass) else "FAIL"
out = {
    "date": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
    "codex_version": sys.argv[3],
    "model": sys.argv[5],
    "effort": sys.argv[6],
    "valid_days": 30,
    "run_dir": sys.argv[4],
    "cases": cases,
    "traps_pass": traps_pass,
    "clean_pass": clean_pass,
    "overall": overall,
}
json.dump(out, open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False, indent=2)
# 累積歷史（「突然全對」要看得出異常，得先有歷史可比）
hist = os.path.join(os.path.dirname(sys.argv[4]), "history.log")
with open(hist, "a", encoding="utf-8") as h:
    detail = ",".join(f"{k}:{'P' if v['pass'] else 'F'}" for k, v in sorted(cases.items()))
    h.write(f"{out['date']} | {sys.argv[3]} | {sys.argv[5]}@{sys.argv[6]} | {overall} | {detail}\n")
print("————")
print(f"雷題：{'全中' if traps_pass else '有漏'}（{sum(c['pass'] for c in traps)}/{len(traps)}）"
      f"｜乾淨題：{sum(c['pass'] for c in clean)}/{len(clean)} 過（需 ≥1）")
print(f"校準結果：{overall}（已寫入 {sys.argv[2]}，效期 30 天，codex={sys.argv[3]}／model={sys.argv[5]}@{sys.argv[6]}）")
sys.exit(0 if overall == "PASS" else 1)
PY
