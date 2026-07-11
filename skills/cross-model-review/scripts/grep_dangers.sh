#!/usr/bin/env bash
# cross-model-review Gate 4: deterministic 危險模式檢查（累積式，每次事故追加一條）。
# 用法: grep_dangers.sh <被審檔> [review_dir]
# exit code = FAIL 數。FAIL 必修；WARN 必須逐條 defend（寫進報告，不准靜默）。
set -u
FILE="${1:?用法: grep_dangers.sh <被審檔> [review_dir]}"
RDIR="${2:-}"
GATE="$(cd "$(dirname "$0")" && pwd)/review-gate.py"
FAIL=0; WARN=0
fail(){ printf -- '－ FAIL %s\n' "$*"; FAIL=$((FAIL+1)); }
warn(){ printf -- '？ WARN %s\n' "$*"; WARN=$((WARN+1)); }
pass(){ printf -- '＋ PASS %s\n' "$*"; }

[ -f "$FILE" ] || { fail "[D0] 被審檔不存在: $FILE"; echo "FAIL=$FAIL WARN=$WARN"; exit "$FAIL"; }

# D1 marker 五欄齊全（時間戳+rounds+verdict+reviewer+sha）— 審完 finalize 後才跑本腳本
if grep -qE '<!-- *cross-model-reviewed: *[^ ]+ +rounds=[0-9]+ +verdict=(approved|arbitrated) +reviewer=[^ ]+ +sha=[0-9a-f]{16} *-->' "$FILE"; then
  pass "[D1] marker 五欄齊全"
else
  fail "[D1] marker 缺欄或不存在"
fi

# D2 sha 與內容吻合（審後偷改偵測；與 hook 同一實作）
if python3 "$GATE" --check "$FILE" >/dev/null 2>&1; then
  pass "[D2] sha 與內容吻合"
else
  fail "[D2] sha 不符或無有效 marker——marker 之後改過內容？完成所有編輯後重新 finalize，或重審"
fi

RVR=""
[ -n "$RDIR" ] && [ -f "$RDIR/meta.json" ] && RVR=$(grep -oE '"reviewer" *: *"[^"]+"' "$RDIR/meta.json" | head -1 | cut -d'"' -f4)
if [ -n "$RDIR" ] && [ -f "$RDIR/ledger.md" ]; then
  # D3 ledger 無未解 MAINTAIN（OPEN）
  if grep -q '| *OPEN *|' "$RDIR/ledger.md"; then
    fail "[D3] ledger 有 OPEN（未解 MAINTAIN）——approved 禁止；僵局走仲裁改 ARBITRATED-*"
  else
    pass "[D3] ledger 無未解項"
  fi
  # D4 marker rounds ≥ ledger 最大輪（防謊報輪數）
  MR=$(grep -oE 'rounds=[0-9]+' "$FILE" | tail -1 | grep -oE '[0-9]+' || true)
  LR=$(awk -F'|' 'NR>2 && $2 ~ /[0-9]/ {gsub(/ /,"",$2); if($2+0>m) m=$2+0} END{print m+0}' "$RDIR/ledger.md")
  # 注意：$VAR 緊貼全形字元必須寫 ${VAR}——bash 3.2＋UTF-8 locale 會把全形括號
  # 的位元組誤併入變數名（2026-07-05 使用者實機事故，set -u 下整支中止）
  if [ "${MR:-0}" -ge "${LR:-0}" ]; then
    pass "[D4] 輪數一致（marker=${MR:-0} ledger_max=${LR:-0}）"
  else
    fail "[D4] 輪數不符：marker=${MR:-0} < ledger_max=${LR:-0}"
  fi
  # D7 各輪審查輸出檔存在且非空（stale read 兜底）
  n=0; empty=0
  for f in "$RDIR"/r*.txt; do
    [ -e "$f" ] || continue
    n=$((n+1))
    [ -s "$f" ] || { empty=$((empty+1)); fail "[D7] 空的審查輸出: $f"; }
  done
  if [ "$n" -eq 0 ]; then
    fail "[D7] review_dir 無任何 r*.txt 審查輸出"
  elif [ "$empty" -eq 0 ]; then
    pass "[D7] $n 個審查輸出檔皆非空"
  fi
  # D9 CONCEDE 防代筆：審查者原文（r*.txt）的 CONCEDE 出現次數，必須 ≥ ledger 的 RESOLVED-CONCEDE 列數
  #（計數下界——一次真讓步不能掩護多列假讓步；仍非逐列語意比對，誠實界線已註明）
  NC_ROWS=$(grep -c 'RESOLVED-CONCEDE' "$RDIR/ledger.md" 2>/dev/null || true)
  NC_ROWS=${NC_ROWS:-0}
  if [ "${NC_ROWS}" -gt 0 ]; then
    NC_TXT=$(cat "$RDIR"/r*.txt 2>/dev/null | grep -o 'CONCEDE' | wc -l | tr -d ' ')
    if [ "${NC_TXT:-0}" -ge "${NC_ROWS}" ]; then
      pass "[D9] CONCEDE 原文佐證足額（原文 ${NC_TXT} ≥ 帳列 ${NC_ROWS}）"
    else
      fail "[D9] ledger 稱 ${NC_ROWS} 筆 CONCEDE 但原文僅 ${NC_TXT} 處——疑似代筆（協定禁止）"
    fi
  fi
  # D8 arbitrated 必有歧見報告——只看「真 marker」的 verdict 欄，不 grep 全文
  #（教訓同 sentinel 事故：文件教學文字會「提及」verdict=arbitrated，提及不是狀態）
  # v1.1 R1 審查後升為 FAIL：仲裁而無歧見紀錄＝協定違規，不是提醒級
  MV=$(grep -oE '<!-- *cross-model-reviewed: *[^ ]+ +rounds=[0-9]+ +verdict=(approved|arbitrated) +reviewer=[^ ]+ +sha=[0-9a-f]{16} *-->' "$FILE" \
       | tail -1 | grep -oE 'verdict=[a-z]+' | cut -d= -f2)
  if [ "${MV:-}" = "arbitrated" ]; then
    # 仲裁三要件（v1.1.1b R2）：歧見報告＋至少一列 ARBITRATED 裁決＋使用者簽核原文
    [ -f "$RDIR/DISAGREEMENT_REPORT.md" ] || fail "[D8] 仲裁缺 DISAGREEMENT_REPORT.md"
    grep -q 'ARBITRATED' "$RDIR/ledger.md" || fail "[D8] 仲裁但 ledger 無任何 ARBITRATED-* 裁決列"
    [ -s "$RDIR/signoff.txt" ] || fail "[D8] 仲裁缺 signoff.txt——人裁必留簽核原文（不分 tier/姿態）"
    if [ -f "$RDIR/DISAGREEMENT_REPORT.md" ] && grep -q 'ARBITRATED' "$RDIR/ledger.md" && [ -s "$RDIR/signoff.txt" ]; then
      pass "[D8] 仲裁三要件齊備（報告＋裁決列＋簽核）"
    fi
  fi
  # D11 風險層級＋簽核工件：meta.json 必須有合法 tier（red|yellow）；red 必附 signoff.txt
  #（R2 審查：缺漏／亂填 tier 不得 fail-open——否則 🔴 工件漏填就繞過簽核）
  if [ -f "$RDIR/meta.json" ]; then
    TIER=$(grep -oE '"tier" *: *"[a-z]+"' "$RDIR/meta.json" | head -1 | cut -d'"' -f4)
    case "${TIER:-}" in
      red)
        if [ -s "$RDIR/signoff.txt" ]; then
          pass "[D11] 🔴 工件已附使用者簽核（signoff.txt）"
        else
          fail "[D11] 🔴 工件缺 signoff.txt——取得使用者指名核准並落檔後才可 finalize（R3）"
        fi ;;
      yellow)
        pass "[D11] tier=yellow（簽核需求由 D10 校準姿態決定）" ;;
      *)
        fail "[D11] meta.json 缺 tier 或非法值（需 red|yellow，現值='${TIER:-}'）——風險分級不得留白" ;;
    esac
  fi
  # D13 審查者身分綁定：marker 的 reviewer 欄必須等於 meta.json 的 reviewer（v1.1.1 審查：防兩處各說各話）
  MRV=$(grep -oE '<!-- *cross-model-reviewed: *[^ ]+ +rounds=[0-9]+ +verdict=(approved|arbitrated) +reviewer=[^ ]+ +sha=[0-9a-f]{16} *-->' "$FILE"        | tail -1 | grep -oE 'reviewer=[^ ]+' | cut -d= -f2)
  if [ -n "${MRV:-}" ] && [ -n "${RVR:-}" ] && [ "${MRV}" = "${RVR}" ]; then
    pass "[D13] 審查者身分一致（marker＝meta：${MRV}）"
  else
    fail "[D13] 審查者身分不一致：marker=${MRV:-缺} vs meta=${RVR:-缺}"
  fi
  # D12 證據綁版本：meta.json 的 sha 必須等於 marker 的 sha（R2 審查：舊證據不得掩護新內容）
  MSHA=$(grep -oE '<!-- *cross-model-reviewed: *[^ ]+ +rounds=[0-9]+ +verdict=(approved|arbitrated) +reviewer=[^ ]+ +sha=[0-9a-f]{16} *-->' "$FILE" \
        | tail -1 | grep -oE 'sha=[0-9a-f]{16}' | cut -d= -f2)
  ESHA=$(grep -oE '"sha" *: *"[0-9a-f]{16}"' "$RDIR/meta.json" 2>/dev/null | head -1 | cut -d'"' -f4)
  if [ -n "${MSHA:-}" ] && [ "${MSHA}" = "${ESHA:-}" ]; then
    pass "[D12] 證據綁定本版內容（meta.sha＝marker.sha）"
  else
    fail "[D12] meta.json 的 sha（${ESHA:-缺}）≠ marker sha（${MSHA:-缺}）——證據不屬於本版內容"
  fi
else
  warn "[D3/D4/D7] 未提供 review_dir 或無 ledger.md——帳本/輪數/輸出檔檢查跳過（僅事後補查可接受）"
fi

# D5 文件引用的檔案路徑存在（tier-s v1.0 事故：列了 10 個不存在的檔）
# 只驗絕對路徑與 ~/ 路徑；含空白的路徑與 $VAR 路徑不在驗證範圍。
# 擷取用 python regex：左界排除 ]、)、}（Next.js 動態路由 [childId]/、群組 (group)/ 片段
# 會偽裝成絕對路徑——2026-07-05 品質測試實測誤報 /page.ts）；右界防 .ts 吃進 .tsx。
MISS=0
while IFS= read -r tok; do
  [ -z "$tok" ] && continue
  case "$tok" in http*|*example*|*placeholder*|*'<'*) continue;; esac
  p="$tok"
  case "$p" in "~/"*) p="$HOME/${p#\~/}";; esac
  if [ ! -e "$p" ]; then
    grep -nF -- "$tok" "$FILE" | grep -qiE '新建|將建立|to-be-created|will create|範例|舉例' && continue
    warn "[D5] 文件提到但不存在: $tok"
    MISS=$((MISS+1)); [ "$MISS" -ge 10 ] && break
  fi
done < <(python3 - "$FILE" <<'PYEOF'
import re, sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
pat = re.compile(
    r'(?<![\]\)\}A-Za-z0-9._~/-])(?:/|~/)[A-Za-z0-9._~/-]+'
    r'\.(?:py|sh|md|json|toml|js|jsx|ts|tsx|yaml|yml)(?![A-Za-z0-9])'
)
print("\n".join(sorted({m.group(0) for m in pat.finditer(text)})))
PYEOF
)
[ "$MISS" -eq 0 ] && pass "[D5] 引用的絕對/家目錄路徑皆存在（相對與 \$VAR 路徑略過）"

# D10 裁判校準狀態（fail-closed 的機械強制，v1.1 R1 審查後定型）：
#   校準有效 → PASS
#   校準無效＋已附使用者簽核（signoff.txt）→ WARN（有人背書，放行但留痕）
#   校準無效＋無簽核 → FAIL（擋 finalize；gate4 有 FAIL ⇒ 證據不齊 ⇒ hook 不放行——
#   強制鏈經由既有證據四要件流動，hook 本身仍不碰校準、保持 fail-open）
CALMSG=$(python3 "$GATE" --calibration-check 2>&1)
calrc=$?
# 校準是「codex 裁判」的背書——且只背書「被校準的那一位」（v1.1.1 審查收緊）：
#   meta 缺 reviewer → 不適用（缺漏不得 fail-open）；前綴須 codex:（冒號防 codex-subagent 類矇混）；
#   且 reviewer 必須恰為 codex:<校準紀錄的 model>——校準給誰、就只背書誰
if [ "${calrc}" -eq 0 ]; then
  if [ -z "${RVR}" ]; then
    calrc=2; CALMSG="校準不適用：meta.json 缺 reviewer（缺漏不得沿用校準）"
  elif ! printf '%s' "${RVR}" | grep -q '^codex:'; then
    calrc=2; CALMSG="校準不適用：本審審查者為 ${RVR}（校準只背書 codex: 裁判）"
  else
    CAL_MODEL=$(grep -oE '"model" *: *"[^"]+"' "$(python3 "$GATE" --state-root)/calibration.json" 2>/dev/null | head -1 | cut -d'"' -f4)
    if [ "${RVR}" != "codex:${CAL_MODEL:-}" ]; then
      calrc=2; CALMSG="校準不適用：reviewer=${RVR} ≠ codex:${CAL_MODEL:-?}（校準只背書被校準的那一位裁判）"
    fi
  fi
fi
if [ "${calrc}" -eq 0 ]; then
  pass "[D10] 裁判校準有效：${CALMSG}"
elif [ -n "$RDIR" ] && [ -s "$RDIR/signoff.txt" ]; then
  warn "[D10] 校準無效（${CALMSG}）但已附使用者簽核——放行留痕；仍建議跑 calibrate.sh"
else
  fail "[D10] 校準無效（${CALMSG}）且無 signoff.txt——fail-closed：取得使用者指名核准落檔、或跑 calibrate.sh 重建基線"
fi

# D6 自我安慰語（結論應由 Gate 給，不由形容詞給）
if HITS=$(grep -nE '應該沒問題|大致正確|理論上可行|大概沒錯|想必沒' "$FILE" 2>/dev/null) && [ -n "$HITS" ]; then
  warn "[D6] 自我安慰語：$(printf '%s' "$HITS" | head -3 | tr '\n' ' ')"
else
  pass "[D6] 無自我安慰語"
fi

echo "FAIL=$FAIL WARN=$WARN"
exit "$FAIL"
