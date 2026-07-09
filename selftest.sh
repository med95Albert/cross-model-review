#!/usr/bin/env bash
# cross-model-review 零 token 驗收 v2：hook 全分支（含 audit 修正）、CLI、Gate 4、報告。
set -u
GATE="$HOME/.claude/skills/cross-model-review/scripts/review-gate.py"
DANGERS="$HOME/.claude/skills/cross-model-review/scripts/grep_dangers.sh"
REPORT="$HOME/.claude/skills/cross-model-review/scripts/build_audit_report.py"
T="$(mktemp -d /tmp/cmr-selftest.XXXXXX)"   # 沙盒進 /tmp，不污染腳本所在資料夾
rm -rf "$T"; mkdir -p "$T/plans" "$T/myskill" "$T/plainskill" "$T/mentionskill" "$T/rdir" "$T/state"
export CROSS_REVIEW_STATE_ROOT="$T/state"

mkcal(){ # $1=date-iso $2=overall $3=codex_version → 寫 $T/state/calibration.json
python3 - "$T/state/calibration.json" "$1" "$2" "$3" <<'PY'
import json, sys
json.dump({"date": sys.argv[2], "codex_version": sys.argv[4], "overall": sys.argv[3],
           "valid_days": 30, "cases": {}}, open(sys.argv[1], "w"))
PY
}
CV=$(codex --version 2>/dev/null | head -1)
NOW=$(python3 -c "import datetime;print(datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds'))")
OLD=$(python3 -c "import datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(days=45)).isoformat(timespec='seconds'))")
mkcal "$NOW" "PASS" "$CV"   # 套件基準：校準有效（D10 專屬案例會自行切換狀態）
PASS=0; FAILN=0
ok(){ printf '＋ %s\n' "$1"; PASS=$((PASS+1)); }
bad(){ printf '－ %s\n' "$1"; FAILN=$((FAILN+1)); }

keyof(){ printf '%s' "$1" | shasum -a 256 | cut -c1-16; }

mk_evidence(){ # $1=被審檔 → 建立合法 _state 證據（五要件：含綁版 sha 與 tier）
  local k; k=$(keyof "$1")
  local d="$T/state/$k-$(basename "$1")"
  local sha; sha=$(python3 "$GATE" --sha "$1")
  mkdir -p "$d"
  cat > "$d/ledger.md" <<'L'
| 輪 | # | Issue 摘要 | 處置（FIX/PUSHBACK） | 審查者回應 | 狀態 |
|---|---|---|---|---|---|
| 1 | 1 | 測試 issue | FIX: 修了 | 已驗收 | RESOLVED-FIX |
L
  printf '## Verdict\nAPPROVED\n' > "$d/r1.txt"
  printf '{"file":"%s","reviewer":"test:unit","rounds":1,"verdict":"approved","tier":"yellow","sha":"%s"}\n' "$1" "$sha" > "$d/meta.json"
  printf 'FAIL=0 WARN=0\n' > "$d/gate4.txt"
}

mk_transcript(){ # $1=被寫檔 [$2=filler 數]
python3 - "$1" "$T/transcript.jsonl" "${2:-0}" <<'PY'
import json, sys
fp, out, filler = sys.argv[1], sys.argv[2], int(sys.argv[3])
es = [{"type": "assistant", "message": {"role": "assistant", "content": [
    {"type": "tool_use", "name": "Write", "input": {"file_path": fp}}]}}]
for i in range(filler):
    es.append({"type": "assistant", "message": {"role": "assistant",
               "content": [{"type": "text", "text": f"filler {i}"}]}})
with open(out, "w") as f:
    for e in es:
        f.write(json.dumps(e) + "\n")
PY
}

run_hook(){ # $1=stop_hook_active → stdout=hook stdout；exit=hook exit
python3 - "$T/transcript.jsonl" "$1" <<'PY' | python3 "$GATE"
import json, sys
print(json.dumps({"transcript_path": sys.argv[1], "cwd": "/tmp",
                  "stop_hook_active": sys.argv[2] == "true"}))
PY
}

echo "=== A. 非監看檔 → 放行 ==="
echo "notes" > "$T/notes.md"; mk_transcript "$T/notes.md"
OUT=$(run_hook false); RC=$?
[ -z "$OUT" ] && [ "$RC" -eq 0 ] && ok "A 放行" || bad "A 應放行卻 rc=$RC out=$OUT"

echo "=== B. plans/ 下 .md 無 marker → block ==="
printf '# 測試計劃\n步驟一\n' > "$T/plans/test-plan.md"; mk_transcript "$T/plans/test-plan.md"
OUT=$(run_hook false)
printf '%s' "$OUT" | grep -q '"decision": *"block"' && ok "B 有 block" || bad "B 未 block"
printf '%s' "$OUT" | grep -q "test-plan.md" && ok "B 點名檔案" || bad "B 未點名"

echo "=== C1. 自簽 marker（sha 有效）但無 _state 證據 → 仍 block（P0-3）==="
SHA=$(python3 "$GATE" --sha "$T/plans/test-plan.md")
printf '\n<!-- cross-model-reviewed: 2026-07-05T00:00:00Z rounds=1 verdict=approved reviewer=test:unit sha=%s -->\n' "$SHA" >> "$T/plans/test-plan.md"
ST=$(python3 "$GATE" --check "$T/plans/test-plan.md")
[ "$ST" = "valid" ] && ok "C1 --check=valid（sha 本身合法）" || bad "C1 --check=$ST"
OUT=$(run_hook false)
printf '%s' "$OUT" | grep -q '"decision": *"block"' && ok "C1 無證據仍 block" || bad "C1 自簽過關了: $OUT"
printf '%s' "$OUT" | grep -q "evidence missing" && ok "C1 理由標 evidence missing" || bad "C1 理由未標"

echo "=== C2. marker＋證據齊全 → 放行 ==="
mk_evidence "$T/plans/test-plan.md"
OUT=$(run_hook false); RC=$?
[ -z "$OUT" ] && [ "$RC" -eq 0 ] && ok "C2 放行" || bad "C2 應放行卻 rc=$RC out=$OUT"

echo "=== C3. 證據缺 gate4.txt → 仍 block（四要件，dogfood R1 issue#3）==="
K3=$(keyof "$T/plans/test-plan.md")
rm "$T/state/$K3-test-plan.md/gate4.txt"
OUT=$(run_hook false)
printf '%s' "$OUT" | grep -q '"decision": *"block"' && ok "C3 缺 gate4 → block" || bad "C3 放行了缺件證據"
printf 'FAIL=0 WARN=0\n' > "$T/state/$K3-test-plan.md/gate4.txt"

echo "=== C4. 舊證據掩護新內容的自簽 marker（R2 攻擊）→ block（證據綁版本）==="
printf '# 攻擊計劃\n原始內容\n' > "$T/plans/attack-plan.md"
SHA=$(python3 "$GATE" --sha "$T/plans/attack-plan.md")
printf '\n<!-- cross-model-reviewed: 2026-07-08T00:00:00Z rounds=1 verdict=approved reviewer=test:unit sha=%s -->\n' "$SHA" >> "$T/plans/attack-plan.md"
mk_evidence "$T/plans/attack-plan.md"
mk_transcript "$T/plans/attack-plan.md"; OUT=$(run_hook false)
[ -z "$OUT" ] && ok "C4a 首審（marker＋綁版證據）放行" || bad "C4a 應放行: $OUT"
printf '偷改的新內容\n' >> "$T/plans/attack-plan.md"
SHA2=$(python3 "$GATE" --sha "$T/plans/attack-plan.md")
printf '<!-- cross-model-reviewed: 2026-07-08T01:00:00Z rounds=1 verdict=approved reviewer=test:unit sha=%s -->\n' "$SHA2" >> "$T/plans/attack-plan.md"
OUT=$(run_hook false)
printf '%s' "$OUT" | grep -q '"decision": *"block"' && ok "C4b 新內容＋自簽新 marker＋舊證據 → 仍 block" || bad "C4b 被舊證據掩護: $OUT"

echo "=== D. marker 後又改內容（sha 失效）→ block ==="
mk_transcript "$T/plans/test-plan.md"   # C4 換過 transcript，切回本案標的
printf '偷偷加一行\n' >> "$T/plans/test-plan.md"
ST=$(python3 "$GATE" --check "$T/plans/test-plan.md"; true)
[ "$ST" = "stale" ] && ok "D --check=stale" || bad "D --check=$ST"
OUT=$(run_hook false)
printf '%s' "$OUT" | grep -q '"decision": *"block"' && ok "D 有 block" || bad "D 未 block"

echo "=== E1. stop_hook_active＋未審 → 放行但 exit 1＋stderr 點名（P0-2）==="
OUT=$(run_hook true 2>/dev/null); RC=$?
[ -z "$OUT" ] && [ "$RC" -eq 1 ] && ok "E1 stdout 空且 rc=1" || bad "E1 rc=$RC out=$OUT"
ERR=$(run_hook true 2>&1 >/dev/null)
printf '%s' "$ERR" | grep -q "test-plan.md" && ok "E1 stderr 點名洩漏檔" || bad "E1 stderr 未點名: $ERR"

echo "=== E2. stop_hook_active＋全數已審 → 乾淨放行 exit 0 ==="
printf '# 好計劃\n步驟一：跑測試\n' > "$T/plans/good-plan.md"
SHA=$(python3 "$GATE" --sha "$T/plans/good-plan.md")
printf '\n<!-- cross-model-reviewed: 2026-07-05T00:00:00Z rounds=1 verdict=approved reviewer=test:unit sha=%s -->\n' "$SHA" >> "$T/plans/good-plan.md"
mk_evidence "$T/plans/good-plan.md"
mk_transcript "$T/plans/good-plan.md"
OUT=$(run_hook true 2>/dev/null); RC=$?
[ -z "$OUT" ] && [ "$RC" -eq 0 ] && ok "E2 乾淨 rc=0" || bad "E2 rc=$RC out=$OUT"

echo "=== F. SKILL.md sentinel opt-in ==="
printf '# 某 skill\n<!-- cross-model-gated -->\n內容\n' > "$T/myskill/SKILL.md"
mk_transcript "$T/myskill/SKILL.md"; OUT=$(run_hook false)
printf '%s' "$OUT" | grep -q '"decision": *"block"' && ok "F1 獨立行 sentinel → block" || bad "F1 未 block"
printf '# 普通 skill\n內容\n' > "$T/plainskill/SKILL.md"
mk_transcript "$T/plainskill/SKILL.md"; OUT=$(run_hook false)
[ -z "$OUT" ] && ok "F2 無 sentinel → 放行" || bad "F2 誤攔: $OUT"

echo "=== J. 行內提及 sentinel → 不納管（sentinel 事故迴歸）==="
printf '# 說明型 skill\n請在新 skill 加一行 `<!-- cross-model-gated -->` 即可納管\n' > "$T/mentionskill/SKILL.md"
mk_transcript "$T/mentionskill/SKILL.md"; OUT=$(run_hook false)
[ -z "$OUT" ] && ok "J 提及不納管" || bad "J 誤納管: $OUT"

echo "=== L. 長回合：Write 後接 300 則 filler → 仍攔得到（P0-4）==="
printf '# 深埋計劃\n' > "$T/plans/buried-plan.md"
mk_transcript "$T/plans/buried-plan.md" 300
OUT=$(run_hook false)
printf '%s' "$OUT" | grep -q "buried-plan.md" && ok "L 全檔掃描抓到深埋 Write" || bad "L 視窗漏抓: $OUT"

echo "=== G. grep_dangers 紅線樣本 ==="
printf '# 爛計劃\n跑 /nonexistent/xx.py 就好\n這樣應該沒問題\n' > "$T/plans/bad-plan.md"
G=$(bash "$DANGERS" "$T/plans/bad-plan.md" 2>&1; echo "rc=$?")
printf '%s' "$G" | grep -q -- "－ FAIL \[D1\]" && ok "G D1 抓無 marker" || bad "G D1 漏"
printf '%s' "$G" | grep -q -- "－ FAIL \[D2\]" && ok "G D2 抓無效 sha" || bad "G D2 漏"
printf '%s' "$G" | grep -q "文件提到但不存在: /nonexistent/xx.py" && ok "G D5 抓幽靈路徑" || bad "G D5 漏"
printf '%s' "$G" | grep -q -- "\[D6\] 自我安慰語" && ok "G D6 抓安慰語" || bad "G D6 漏"
printf '%s' "$G" | grep -qE "rc=[1-9]" && ok "G exit 非零" || bad "G exit 應非零"

echo "=== G2. 相對路徑 scripts/foo.py 不產生 /foo.py 假 WARN（P1-D5）==="
printf '# 引用相對路徑\n請看 scripts/foo.py 的說明\n' > "$T/plans/rel-plan.md"
G=$(bash "$DANGERS" "$T/plans/rel-plan.md" 2>&1)
printf '%s' "$G" | grep -q "文件提到但不存在: /foo.py" && bad "G2 仍有截斷假 WARN" || ok "G2 無截斷假 WARN"

echo "=== G3. 動態路由片段不誤報＋絕對 .tsx 幽靈要報（D5 精確化迴歸，品質測試事故）==="
printf '# 路由計劃\n改 app/growth-chart/[childId]/page.tsx 與 (group)/layout.tsx，並沿用 /nonexistent/comp.tsx 元件\n' > "$T/plans/route-plan.md"
G=$(bash "$DANGERS" "$T/plans/route-plan.md" 2>&1)
printf '%s' "$G" | grep -q "不存在: /page.ts" && bad "G3 仍誤報 /page.ts" || ok "G3 [childId]/ 片段不誤報"
printf '%s' "$G" | grep -q "不存在: /layout.ts" && bad "G3 仍誤報 (group)/ 片段" || ok "G3 (group)/ 片段不誤報"
printf '%s' "$G" | grep -q "不存在: /nonexistent/comp.tsx" && ok "G3 抓到絕對 .tsx 幽靈" || bad "G3 漏抓 .tsx 幽靈"

echo "=== H. grep_dangers 乾淨樣本＋報告渲染 ==="
K=$(keyof "$T/plans/good-plan.md"); RD="$T/state/$K-good-plan.md"
GS=$(python3 "$GATE" --sha "$T/plans/good-plan.md")
printf '{"file":"%s","reviewer":"test:unit","rounds":1,"verdict":"approved","tier":"yellow","sha":"%s","started":"t0","finished":"t1"}\n' "$T/plans/good-plan.md" "$GS" > "$RD/meta.json"
G=$(bash "$DANGERS" "$T/plans/good-plan.md" "$RD" 2>&1; echo "rc=$?")
printf '%s' "$G" | grep -q "FAIL=0" && ok "H FAIL=0" || { bad "H 有 FAIL"; printf '%s\n' "$G"; }
printf '%s' "$G" > "$RD/gate4.txt"
RP=$(python3 "$REPORT" "$RD")
[ -f "$RP" ] && grep -q "AUDIT_REPORT" "$RP" && ok "H 報告渲染" || bad "H 報告失敗"

echo "=== H2. 文中提及 verdict=arbitrated 但 marker=approved → 無 D8 假 WARN（dogfood 事故迴歸）==="
printf '# 帶教學文字的計劃\n若僵局，marker 會寫 verdict=arbitrated 並產歧見報告。\n' > "$T/plans/prose-plan.md"
SHA=$(python3 "$GATE" --sha "$T/plans/prose-plan.md")
printf '\n<!-- cross-model-reviewed: 2026-07-05T00:00:00Z rounds=1 verdict=approved reviewer=test:unit sha=%s -->\n' "$SHA" >> "$T/plans/prose-plan.md"
mk_evidence "$T/plans/prose-plan.md"
KP=$(keyof "$T/plans/prose-plan.md")
G=$(bash "$DANGERS" "$T/plans/prose-plan.md" "$T/state/$KP-prose-plan.md" 2>&1)
printf '%s' "$G" | grep -q "\[D8\]" && bad "H2 D8 仍誤 WARN 教學文字" || ok "H2 D8 不再誤 WARN"

echo "=== I. OPEN 帳本必擋（Gate 4）＋ hook 端同步擋（P0-3）==="
printf '| 2 | 2 | 僵持 issue | PUSHBACK: 理由 | MAINTAIN | OPEN |\n' >> "$RD/ledger.md"
G=$(bash "$DANGERS" "$T/plans/good-plan.md" "$RD" 2>&1)
printf '%s' "$G" | grep -q -- "－ FAIL \[D3\]" && ok "I D3 抓 OPEN" || bad "I D3 漏"
mk_transcript "$T/plans/good-plan.md"
OUT=$(run_hook false)
printf '%s' "$OUT" | grep -q '"decision": *"block"' && ok "I hook 端：證據含 OPEN → 不放行" || bad "I hook 端放行了帶 OPEN 的審查"

echo "=== M. 校準機制（--state-root／--calibration-check／D8-D11，v1.1）==="
SR=$(python3 "$GATE" --state-root)
[ "$SR" = "$T/state" ] && ok "M1 --state-root 尊重 CROSS_REVIEW_STATE_ROOT" || bad "M1 得到: $SR"
rm -f "$T/state/calibration.json"
python3 "$GATE" --calibration-check >/dev/null 2>&1 && bad "M2 無紀錄應 invalid" || ok "M2 無校準紀錄 → invalid"
mkcal "$NOW" "PASS" "$CV"
python3 "$GATE" --calibration-check >/dev/null 2>&1 && ok "M3 新鮮＋PASS＋同版 → valid" || bad "M3 應 valid: $(python3 "$GATE" --calibration-check 2>&1)"
mkcal "$OLD" "PASS" "$CV"
python3 "$GATE" --calibration-check >/dev/null 2>&1 && bad "M4 過期應 invalid" || ok "M4 逾 30 天 → invalid"
mkcal "$NOW" "PASS" "codex-cli 0.0.1"
python3 "$GATE" --calibration-check >/dev/null 2>&1 && bad "M5 版本不符應 invalid" || ok "M5 codex 換版 → invalid"
mkcal "$NOW" "FAIL" "$CV"
python3 "$GATE" --calibration-check >/dev/null 2>&1 && bad "M5b 未過應 invalid" || ok "M5b overall=FAIL → invalid"
mkcal "$NOW" "PASS" "$CV"

printf '| 3 | 9 | 測試讓步 | PUSHBACK: 理由 | CONCEDE | RESOLVED-CONCEDE |\n' >> "$RD/ledger.md"
G=$(bash "$DANGERS" "$T/plans/good-plan.md" "$RD" 2>&1)
printf '%s' "$G" | grep -q -- "－ FAIL \[D9\]" && ok "M6 D9 抓到代筆（原文 0 處 CONCEDE）" || bad "M6 D9 漏"
printf 'On pushbacks: CONCEDE — fine\n' > "$RD/r2.txt"
G=$(bash "$DANGERS" "$T/plans/good-plan.md" "$RD" 2>&1)
printf '%s' "$G" | grep -q -- "＋ PASS \[D9\]" && ok "M7 D9 足額佐證 → PASS" || bad "M7 D9 誤殺"
printf '| 3 | 10 | 第二筆讓步 | PUSHBACK: y | CONCEDE | RESOLVED-CONCEDE |\n' >> "$RD/ledger.md"
G=$(bash "$DANGERS" "$T/plans/good-plan.md" "$RD" 2>&1)
printf '%s' "$G" | grep -q -- "－ FAIL \[D9\]" && ok "M7b D9 計數下界：1 原文擋不住 2 帳列" || bad "M7b D9 被單筆原文掩護"
printf 'Round3: CONCEDE again\n' >> "$RD/r2.txt"

rm -f "$T/state/calibration.json" "$RD/signoff.txt"
G=$(bash "$DANGERS" "$T/plans/good-plan.md" "$RD" 2>&1)
printf '%s' "$G" | grep -q -- "－ FAIL \[D10\]" && ok "M8 D10 校準無效＋無簽核 → FAIL（fail-closed）" || bad "M8 D10 未擋"
printf '使用者簽核：同意放行（測試）2026-07-08\n' > "$RD/signoff.txt"
G=$(bash "$DANGERS" "$T/plans/good-plan.md" "$RD" 2>&1)
printf '%s' "$G" | grep -q -- "？ WARN \[D10\]" && ok "M8b D10 無效＋有簽核 → WARN 放行留痕" || bad "M8b D10 簽核未放行"
mkcal "$NOW" "PASS" "$CV"
G=$(bash "$DANGERS" "$T/plans/good-plan.md" "$RD" 2>&1)
printf '%s' "$G" | grep -q -- "＋ PASS \[D10\]" && ok "M9 D10 校準有效 → PASS" || bad "M9 D10 誤警"

rm -f "$RD/signoff.txt"
python3 - "$RD/meta.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); m["tier"] = "red"
json.dump(m, open(sys.argv[1], "w"))
PY
G=$(bash "$DANGERS" "$T/plans/good-plan.md" "$RD" 2>&1)
printf '%s' "$G" | grep -q -- "－ FAIL \[D11\]" && ok "M10 D11 🔴 無簽核 → FAIL" || bad "M10 D11 漏"
printf '使用者簽核：同意放行（測試）2026-07-08\n' > "$RD/signoff.txt"
G=$(bash "$DANGERS" "$T/plans/good-plan.md" "$RD" 2>&1)
printf '%s' "$G" | grep -q -- "＋ PASS \[D11\]" && ok "M11 D11 🔴 有簽核 → PASS" || bad "M11 D11 誤擋"

python3 - "$RD/meta.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); m.pop("tier", None)
json.dump(m, open(sys.argv[1], "w"))
PY
G=$(bash "$DANGERS" "$T/plans/good-plan.md" "$RD" 2>&1)
printf '%s' "$G" | grep -q -- "－ FAIL \[D11\].*缺 tier" && ok "M11b D11 缺 tier → FAIL（不 fail-open）" || bad "M11b D11 缺 tier 被放過"
python3 - "$RD/meta.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); m["tier"] = "yellow"
json.dump(m, open(sys.argv[1], "w"))
PY

python3 - "$RD/meta.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); m["sha"] = "0" * 16
json.dump(m, open(sys.argv[1], "w"))
PY
G=$(bash "$DANGERS" "$T/plans/good-plan.md" "$RD" 2>&1)
printf '%s' "$G" | grep -q -- "－ FAIL \[D12\]" && ok "M13 D12 證據 sha 竄改 → FAIL" || bad "M13 D12 漏"
python3 - "$RD/meta.json" "$GS" <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); m["sha"] = sys.argv[2]
json.dump(m, open(sys.argv[1], "w"))
PY
G=$(bash "$DANGERS" "$T/plans/good-plan.md" "$RD" 2>&1)
printf '%s' "$G" | grep -q -- "＋ PASS \[D12\]" && ok "M13b D12 sha 相符 → PASS" || bad "M13b D12 誤擋"

printf '# 仲裁計劃\n內容\n' > "$T/plans/arb-plan.md"
SHA=$(python3 "$GATE" --sha "$T/plans/arb-plan.md")
printf '\n<!-- cross-model-reviewed: 2026-07-08T00:00:00Z rounds=5 verdict=arbitrated reviewer=codex:gpt-5.5 sha=%s -->\n' "$SHA" >> "$T/plans/arb-plan.md"
mk_evidence "$T/plans/arb-plan.md"
KA=$(keyof "$T/plans/arb-plan.md"); RA="$T/state/$KA-arb-plan.md"
G=$(bash "$DANGERS" "$T/plans/arb-plan.md" "$RA" 2>&1)
printf '%s' "$G" | grep -q -- "－ FAIL \[D8\]" && ok "M12 D8 仲裁無歧見報告 → FAIL（升級後）" || bad "M12 D8 未升級"
printf '# DISAGREEMENT_REPORT\n' > "$RA/DISAGREEMENT_REPORT.md"
G=$(bash "$DANGERS" "$T/plans/arb-plan.md" "$RA" 2>&1)
printf '%s' "$G" | grep -q -- "－ FAIL \[D8\]" && bad "M12b D8 誤擋" || ok "M12b D8 有歧見報告 → 不擋"

echo ""
echo "結果：PASS=$PASS FAIL=$FAILN"
exit "$FAILN"
