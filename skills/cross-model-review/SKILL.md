---
name: cross-model-review
description: "跨模型互審閘門：對 plan/spec/SKILL.md 做對抗式文件審查（codex 優先、fresh subagent 備援），逐輪到共識；5 輪僵局交人裁。完成後寫入 sha 綁定 marker 供 Stop hook 放行。Trigger on: 跨模型審查, 叫 codex 審, cross review, 互審這份, 這份 plan 給另一個模型看, Stop hook 攔截點名未審檔案時, tier-s-agent-builder Step 9.5 分流。分工：引用驗證→medical-citation；設計新 skill→tier-s-agent-builder；本 skill 只管文件級對抗審查與閘門。"
---

# cross-model-review v1.1.1 ・ 跨模型互審閘門

<!-- cross-model-gated -->

> **Step 0**：先讀 `albert-judgment-core`（E1 路徑解析、R2 完成定義、R3 核准規則、R4 換路訊號）。**未安裝該 skill 的環境用此一行版**——R2：宣稱完成前 read-back 驗證交付物、數字用實測值；R3：不可逆／對外動作要使用者指名核准，單獨「好／OK」不算；R4：同法失敗 2 次就換路，禁止為過驗證而放寬驗證；E5：可變狀態寫本 skill 的 STATE_ROOT（用 `scripts/review-gate.py --state-root` 查詢，環境變數 `CROSS_REVIEW_STATE_ROOT` 可覆蓋），skill 目錄視為唯讀。
> 血統：機制沿用公開的 codex-review 手法（Stop hook＋逐輪共識協定），治理層（風險分級、裁判校準、防偽指紋、輪數上限＋人類仲裁、自我進化）自建。

## 為什麼存在（一段講完）

作者無法自審自己的假設——根植於作者假設的缺陷，對作者是結構性看不見的。本 skill 讓「另一個模型」以證偽姿態審查會驅動執行的文件（plan/spec/SKILL.md），並用確定性 hook 強制執行：沒有有效 marker，回合結束不了。審查是對話不是蓋章：逐輪 FIX／PUSHBACK，審查者必須 CONCEDE 或 MAINTAIN，共識才 APPROVED；5 輪不收斂交人裁，不打消耗戰。

## 觸發判斷

- **自動**：Stop hook（`scripts/review-gate.py`）block 並點名未審檔案 → 立即跑本 skill。
- **明確**：「跨模型審查這份」「叫 codex 審」「cross review」「互審這份文件」。
- **被呼叫**：tier-s-agent-builder Step 9.5 分流（新 SKILL.md 交付前）。
- **方向 B**：「幫我審這份 codex／別人寫的東西」→ 見「方向 B」節。
- 非觸發：程式碼 diff 審查（用 /code-review）；引用正確性（medical-citation）。

## 監看範圍與風險分級

Hook 監看：任何 `plans/`、`specs/` 目錄下的 `.md`；以及**掛了 sentinel 的 SKILL.md**——sentinel 必須是獨立一行的 `<!-- cross-model-gated -->` HTML 註解，行內「提到」這字串不算 opt-in（v1.0 首日事故：tier-s 教學句被誤納管）。opt-in 制防監看過寬→審查疲勞；tier-s 產出的 🔴/🟡 新 skill 應內建 sentinel。

| 等級 | 認定 | 審查者 | 僵局 | 人類審核 |
|---|---|---|---|---|
| 🔴 | 醫療／對外發布相關（twkid、clinic、weight-loss、給病人家長的內容之 plan，或該類 skill 的 SKILL.md）| codex **強制**；不可用→停下問人 | 必人裁 | AUDIT_REPORT 必勾 |
| 🟡 | 內部 plan/spec、一般 skill | codex 優先，subagent 備援 | 人裁 | 報告產出即可 |
| 🟢 | 草稿筆記（不在監看路徑且無 sentinel）| 不觸發 | — | — |

分級模糊時：按 🟡 執行並在報告標註「分級未確認」；涉醫療字眼一律升 🔴（R3）。

## 5 Gates 總表（對抗工具禁止重複）

| Gate | 內容 | 工具 | 性質 |
|---|---|---|---|
| 1 | 審查者資格探測＋校準姿態（黃金集 fail-closed，Step 1.5） | `scripts/reviewer-probe.sh`＋`scripts/calibrate.sh` | 阻擋/升級簽核 |
| 2 | 異議帳本落盤 `$DIR/ledger.md` | 磁碟 markdown（非對話記憶） | 阻擋 |
| 3 | 逐輪對抗審查（本體） | codex CLI（跨模型）／fresh subagent（跨 context） | 阻擋 |
| 4 | deterministic 複核（D1–D13：CONCEDE 計數防代筆、校準狀態與適用性、tier＋簽核、證據綁版本、審查者身分綁定） | `scripts/grep_dangers.sh`（grep/test/sha256） | 阻擋 |
| 5 | 人類檢查點（僵局裁決、🔴 勾選） | 人類＋read-back | 阻擋(🔴)/警示(🟡) |

## Pipeline

> **腳本路徑**：本 skill 的腳本都在自己的 `scripts/` 子資料夾。以系統告知的「**Base directory for this skill**」為 `SDIR`（clone 安裝＝`~/.claude/skills/cross-model-review`，plugin 安裝＝plugin 內 skill 目錄），以下一律 `$SDIR/scripts/…` 呼叫——兩種安裝方式通用。

### Step 1｜Gate 1：探測審查者＋定風險級

```bash
bash $SDIR/scripts/reviewer-probe.sh
```

exit 0 → 審查者＝codex。exit 1 → 🟡 用 fresh subagent 備援；🔴 停下問使用者（裝 codex 或明示接受降級）。同時按上表定風險級，寫進 meta。

probe 同時回報 **POSTURE**（裁判校準姿態）：`GREEN`＝校準有效，照常。`RED`（從未校準／未通過／逾 30 天／codex 換版／**換裁判模型**）＝**fail-closed：本次所有工件視同 🔴——審查照跑，但 APPROVED 後仍需使用者簽核**，並提示跑 `calibrate.sh` 重建基線。

### Step 1.5｜裁判校準（黃金集，v1.1）

光「換個模型當裁判」不夠——**裁判本身可不可信，要能被證明，不能被假設**。機制：

- 黃金集在 `$STATE_ROOT/gold/`（首跑由 `scripts/gold-seed/` 播種）：**雷題**（已知缺陷，各測一種能力：幽靈模組／目標無交付／金鑰洩漏／錯誤分類）＋**乾淨題**（必須 APPROVED——測「不亂抓」的假陽性方向，只測抓雷會漏掉亂槍打鳥的壞裁判）。
- 跑 `bash $SDIR/scripts/calibrate.sh`（每題 1 次 codex 呼叫）→ 寫 `calibration.json`（日期、codex 版本、裁判 model@effort、逐題結果）。通過規則：**雷題全中＋乾淨題 ≥1 過**（兩類題各須至少 1 題存在——零乾淨題＝假陽性方向未測＝不得 PASS）。
- 效期 30 天；**裁判身分＝CLI 版本 × model × 推理強度（effort）**，三者任一變即失效（換模型＝換裁判；effort 從 xhigh 掉到 low 也是換裁判）。過期／失效／未過 → POSTURE=RED（fail-closed 如上）。
- 防過擬合：本機可自加題（天然 held-out）；逐題原文落檔 `gold/runs/<時間戳>/`＋跨次 `history.log`，「突然全對」看得出異常；**題目檔內嚴禁提示雷存在的文字**（劇透＝廢考卷）；**乾淨題必須相對空倉庫自足**——引用不存在的既有程式會被證偽式裁判照規則打槍（裁判對、題目錯）。
- 飛輪：Step 7 的人類仲裁、🔴 簽核被人推翻的案例，都會歸檔成 `gold-candidates/`——**人類獨立定讞**等級的題材，累積後手動挑入黃金集（「人只是同意 AI」的案例不算獨立訊號，不得入集）。

### Step 2｜每審隔離（防 stale read 與跨審互撞）

兩個致命失誤要防：**(1) stale read**——codex 呼叫失敗沒寫輸出檔，卻讀到上一輪殘檔裡的 APPROVED 就蓋章；**(2) 跨審互撞**——共用暫存路徑或 `resume --last` 抓到別的 session。因此：

```bash
REVIEW_PATH="<被審檔絕對路徑>"
ROOT="<被審檔所屬 git repo 根；無 repo 則用檔案所在目錄>"
KEY=$(printf '%s' "$REVIEW_PATH" | { command -v shasum >/dev/null 2>&1 && shasum -a 256 || sha256sum; } | cut -c1-16)
DIR=$(mktemp -d "/tmp/cross-review.XXXXXXXX")   # 每審全新目錄
printf '%s' "$DIR" > "/tmp/cross-review.$KEY.dir"   # round 2+ 用 cat 讀回
date -u +%Y-%m-%dT%H:%M:%SZ > "$DIR/started"
```

**鐵律：每次 codex 呼叫後檢查 exit code；非零 → 不讀輸出檔、不寫 marker、回報錯誤。**（zsh 注意：接 `$?` 用 `rc` 之類的名字，`status` 是 zsh 唯讀變數。）

### Step 3｜Round 1（審查者首輪）

**codex 版**（rounds 2+ 靠 `--json` 抓到的 thread_id resume，絕不用 `--last`）。
注意：round 1 用 **unquoted heredoc**，讓 `$REVIEW_PATH` 真的展開成路徑——quoted 版會把字面佔位符送給審查者，整輪審查對著不存在的檔（Step 9.5 audit P0-1 實證）。代價是 body 內**禁止出現其他 `$` 與反引號**：

```bash
codex exec --json --sandbox read-only --skip-git-repo-check -C "$ROOT" \
  -o "$DIR/r1.txt" - <<CODEX_EOF > "$DIR/r1.events.jsonl"
You are peer-reviewing a spec, plan, or skill document. Claude (the user's main agent) wrote and self-reviewed it. This is a single iterative dialogue: I (Claude) will fix or push back on each issue you raise; you re-evaluate in later rounds. It runs AT MOST 5 rounds — unresolved disagreements then go to a human arbiter with both positions quoted. So never approve out of politeness, and never withhold APPROVED once your real concerns are resolved.

# Why this review exists
This document drives real implementation: it will be executed step-by-step by a zero-context engineer who will not notice its mistakes. The author wrote and self-reviewed it, so every flaw rooted in the author's own assumptions is still in it, invisible to the author by construction. Your job is exactly the review the author cannot do on themselves.

# How to review
Treat the document as a hypothesis to falsify — not a description to follow. It is written to look complete and correct; read it forwards and its own narrative carries you to "looks fine." So review reality, with the document as the claim under test. Work only from primary sources:
- The real files. You have read access — verify every claim the document makes about existing code, files, and behavior, especially completeness claims. Never accept the document's description of itself as given.
- The document's own stated scope. Every goal it commits to must be delivered by a concrete mechanism in the document. A committed goal nothing delivers is a gap.
Also judge the prescribed design: the executor has no taste and builds exactly what is written, so unsound or debt-laden design is itself a finding.

# Document to review
$REVIEW_PATH

# Reporting discipline (Edit Budget)
Report at most the 5 highest-impact MAJOR issues this round, ranked by impact. If more exist, end with one line: "N additional lower-priority issues withheld." Skip pure style and wording preferences; the bar is impact — would this ship a bug, a broken workflow, or real long-term debt?

Output in this exact format:

## Verdict
APPROVED  (or)  ISSUES FOUND

## Major issues (omit if APPROVED)
- [issue]: [why it matters]

## Recommendations (advisory, do not block)
- [optional]
CODEX_EOF
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "codex exec FAILED (exit $rc) — 不讀 r1.txt、不寫 marker"; tail -n 20 "$DIR/r1.events.jsonl"; exit "$rc"
fi
grep -m1 '"thread.started"' "$DIR/r1.events.jsonl" | sed -E 's/.*"thread_id":"([^"]+)".*/\1/' > "$DIR/thread_id"
```

`thread_id` 空 → 降級 `resume --last`，且本審期間禁止啟動其他 codex session，並在最終報告標註此限制。

**subagent 版**（codex 不可用、🟡 限定）：Agent 工具 `general-purpose`、model=`opus`（或 fable）、新 context，prompt＝上面同一份證偽 prompt（含 Edit Budget 與 5 輪上限句）＋檔案路徑。**把 subagent 回覆原文存 `$DIR/r1.txt`**（Write 工具），記下 agent 名稱／id 供 rounds 2+ 用 SendMessage 續談（對應 codex 的 resume）。reviewer 記為 `subagent:<model>`。**subagent 審查一律視同 POSTURE=RED**——校準是 codex 裁判的背書，備援審查者沒有；D10 會以 reviewer 適用性強制（非 `codex:*` 不得沿用校準），finalize 需使用者簽核。

### Step 4｜Gate 2：帳本落盤（每輪審完立刻記）

`$DIR/ledger.md`，格式固定（Gate 4 會機器驗）：

```
| 輪 | # | Issue 摘要 | 處置（FIX/PUSHBACK） | 審查者回應 | 狀態 |
|---|---|---|---|---|---|
```

狀態 ∈ `RESOLVED-FIX`｜`RESOLVED-CONCEDE`（審查者讓步）｜`RESOLVED-CAPITULATED`（我方被說服而改）｜`OPEN`｜`ARBITRATED-CLAUDE`｜`ARBITRATED-REVIEWER`。沒登錄的 issue 不得出現在 finalize 報告；有 OPEN 不得 approved。

### Step 5｜迭代（rounds 2–5）

對每條 issue：有理→**FIX**（Edit 修文件）；不服→**PUSHBACK**（記具體理由，不改檔）。不 rubber-stamp、不為收斂而假投降；被說服才改（狀態記 RESOLVED-CAPITULATED，誠實留痕）。然後 resume 同一 session：

```bash
DIR=$(cat "/tmp/cross-review.$KEY.dir"); THREAD_ID=$(cat "$DIR/thread_id")
codex exec --sandbox read-only --skip-git-repo-check -C "$ROOT" -o "$DIR/r<N>.txt" \
  resume "$THREAD_ID" - <<'CODEX_EOF'
Round <N> of 5. I responded to your previous round:

FIXED (re-read the document, these are edited):
- [issue]: [what changed]

PUSHED BACK (need explicit CONCEDE or MAINTAIN on each):
- [issue]: [my reasoning]

Please: 1) re-read the document; 2) per pushback say CONCEDE or MAINTAIN (if MAINTAIN, state precisely what my reasoning misses); 3) verify FIXED items actually address what you raised; 4) raise genuinely new MAJOR issues only (Edit Budget: top 5, ranked).

Output format:

## Verdict
APPROVED  (or)  REMAINING ISSUES

## On pushbacks
- [issue]: CONCEDE / MAINTAIN — [reason]

## Remaining or new issues (omit if APPROVED)
- [issue]: [why]
CODEX_EOF
rc=$?; [ "$rc" -ne 0 ] && { echo "codex FAILED (exit $rc) — 不讀輸出、不寫 marker"; exit "$rc"; }
```

（subagent 版：SendMessage 同一 agent，同文；回覆存 `$DIR/r<N>.txt`。）

MAINTAIN 的處理：下一輪**要嘛給更利的論證，要嘛誠實投降修掉**；禁止假裝已解決、禁止替審查者代筆 CONCEDE。APPROVED → Step 6；到第 5 輪仍有 OPEN → Step 7。

### Step 6｜Finalize（APPROVED 路徑）——marker 必須是最後一次修改

```bash
GATE=$SDIR/scripts/review-gate.py
# 1) 確認所有內容編輯已完成，然後才算 sha
SHA=$(python3 "$GATE" --sha "$REVIEW_PATH")
cat >> "$REVIEW_PATH" <<MARKER

<!-- cross-model-reviewed: $(date -u +%Y-%m-%dT%H:%M:%SZ) rounds=<N> verdict=approved reviewer=<審查者id> sha=$SHA -->
MARKER
python3 "$GATE" --check "$REVIEW_PATH"   # 必須印 valid，否則停
# 2) meta + Gate 4 + 報告
cat > "$DIR/meta.json" <<META
{"file":"$REVIEW_PATH","reviewer":"<審查者id：codex 路徑必須恰為 codex:<校準模型>，D10/D13 會機器驗>","rounds":<N>,"verdict":"approved","tier":"<red|yellow>","sha":"$SHA","started":"$(cat "$DIR/started")","finished":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
META
bash $SDIR/scripts/grep_dangers.sh "$REVIEW_PATH" "$DIR" | tee "$DIR/gate4.txt"
python3 $SDIR/scripts/build_audit_report.py "$DIR"

# 2.5) 簽核工件（🔴 工件或 POSTURE=RED 時，D10/D11 會以 FAIL 強制）：
#      向使用者出示報告、取得指名核准（R3——單獨「好/OK」不算），把核准原文＋日期
#      寫入 "$DIR/signoff.txt"，然後重跑上面的 grep_dangers 與報告——
#      沒有簽核工件，gate4 有 FAIL ⇒ 證據不齊 ⇒ hook 不放行（fail-closed 是機械的，不是自律的）

# 3) 歸檔——閘門放行的必要條件（marker＋證據四要件，缺一 hook 不放行）
STATE_ROOT=$(python3 $SDIR/scripts/review-gate.py --state-root)   # 單一事實來源
STATE="${STATE_ROOT}/$KEY-$(basename "$REVIEW_PATH")"
mkdir -p "$STATE"
cp "$DIR/ledger.md" "$DIR/meta.json" "$DIR/gate4.txt" "$STATE/"
cp "$DIR"/r*.txt "$STATE/" && cp "$DIR"/*REPORT*.md "$DIR/signoff.txt" "$STATE/" 2>/dev/null
printf '%s | %s | %s | rounds=%s | %s\n' "$(date -u +%F)" "$REVIEW_PATH" "<審查者id>" "<N>" "<approved|arbitrated>" \
  >> "${STATE_ROOT}/reviews.log"
```

grep_dangers FAIL>0 → 修完重跑（改內容後 marker 失效屬正常：重算 sha 重寫 marker）。WARN → 逐條 defend 寫進回報。歸檔完成後回報使用者：輪數、審查者原始主要疑慮 1-3 條、改了什麼、我方 pushback 而審查者讓步的（展示判斷）、我方被說服的（透明——但注意：**被說服而改〔RESOLVED-CAPITULATED〕不得當作「審查有效」的證據**，讓步可能只是讓步）。**🔴 工件或 POSTURE=RED**：附 AUDIT_REPORT 路徑，等使用者勾選才算完成。

### Step 7｜Deadlock（第 5 輪仍未共識）

1. ledger 未解項全標 `OPEN`；meta verdict 記 `deadlock`；跑 `build_audit_report.py`（自動產 DISAGREEMENT_REPORT，含雙方立場與裁決欄）。
2. 呈給使用者**指名裁決**（R3：單獨「好／OK」不算）。逐項採 ACCEPT-CLAUDE／ACCEPT-REVIEWER／其他指示；照裁決改檔、ledger 改 `ARBITRATED-*`；**把裁決原文＋日期寫入 `$DIR/signoff.txt`——仲裁＝人裁，簽核不分 tier／姿態一律必附（D8 驗三要件：報告＋裁決列＋簽核）**。
3. finalize 同 Step 6，但 **verdict 三處一致寫 `arbitrated`**：marker、`meta.json`、`reviews.log` 該列。順序：先寫 meta（verdict=arbitrated）再跑 `build_audit_report.py`——renderer 依 meta.verdict 自動產 DISAGREEMENT_REPORT（D8 驗其存在，缺＝FAIL）。報告留存歧見全文。
4. **校準飛輪（v1.1）**：仲裁歸檔時額外寫 `$STATE_ROOT/gold-candidates/<KEY>-<日期>.md`——案情摘要、雙方立場、人類裁決、標記 `provenance: human-independent`。這是「人類獨立定讞」等級的黃金題材（🔴 簽核時使用者**推翻** APPROVED 的案例同樣要寫一筆）。累積後由使用者手動挑入 `gold/`；「人只是同意 AI」的案例不算獨立訊號、不得入集。

## 方向 B｜Claude 當審查者（審非 Claude 寫的工件）

前置 Gate：**先確認作者不是 Claude**（問使用者或查來源）；作者是 Claude 的檔案禁止走方向 B——那是自審偽裝成互審。流程：Claude 以同一份證偽 prompt 自任審查者（讀檔＋讀 codebase 一手驗證），輪次、ledger、marker 全同，reviewer 記 `claude:<model>`。誠實標註：此方向無 hook 強制（codex 端閘門不在本 skill 控制內），屬自覺觸發。

## Failure Modes

| 症狀 | 動作 |
|---|---|
| codex exec 非零 exit | 回報錯誤；不讀輸出檔、不寫 marker。連 2 次失敗（R4）→ 換 subagent 或停問 |
| 輸出無 `## Verdict` | 視同 ISSUES FOUND，原文全文當 issue 清單，繼續 |
| `thread_id` 空 | 降級 `resume --last`＋本審期間不開其他 codex session＋報告標註 |
| 5 輪未共識 | Step 7 仲裁，不延長爭辯 |
| codex 與 subagent 都不可用 | 停下問使用者（R3）；🔴 絕不静默跳過審查 |
| D2 sha 不符 | 找出 marker 後的改動：只是忘了順序→重 finalize；內容實質變了→重審 |
| 想大量 briefing 審查者 | 文件不自足的訊號——修文件，不是餵 context |
| 審查者每輪丟瑣碎新題 | 反嗆校準：要嘛 APPROVED 要嘛解釋為何是承重牆（Edit Budget 已限 5）|
| probe 回 POSTURE=RED | 照常審，但 finalize 後必須使用者簽核（視同 🔴）；跑 `calibrate.sh` 重建基線後恢復 GREEN |
| calibrate.sh 未過（雷題漏抓或乾淨題全被打槍） | 裁判當下不可信——維持 RED 姿態，向使用者回報漏了哪類能力，勿放寬題目遷就裁判（R4-3）|
| hook block 理由標「review evidence missing」 | marker 有效但 `_state` 歸檔缺——補跑 Step 6 第 3 段 |
| 回合結束 stderr 警告「unreviewed watched artifact(s) still present」 | 本 stop 週期已硬擋過一次（防迴圈降為警告）。補完成審查＋finalize；下一回合會重新硬擋 |

## Don't

- **rounds 2+ 不准開新 session**——codex 用 `resume "$THREAD_ID"`、subagent 用 SendMessage；審查者必須記得每一輪。
- **不准 `resume --last`**（除 thread_id 空的降級況）；**不准共用暫存路徑**——一律 `$DIR`。
- **不准手寫 sha**——必用 `review-gate.py --sha`（與 hook 同一實作）；**不准 marker 後再改檔**。
- **不准為過 D5 刪真引用、為過 D3 改 ledger 狀態**——修內容不是修 Gate（R4-3）。
- **不准 rubber-stamp、不准假投降、不准把 MAINTAIN 當已解、不准替審查者代筆 CONCEDE。**
- **不准修審查者沒提的東西**（scope creep）；**不准在 round 1 prompt 洩漏我方結論**（禁忌②）。
- **不准跳過 marker 與 `_state` 歸檔**——兩者是閘門放行的雙要件。同一 stop 週期只硬擋一次（防迴圈），之後降為 stderr 可見警告，且每個新回合重新硬擋；也不准教人繞 hook。

## Bundled Resources（全部真實存在，交付時 read-back）

- `scripts/review-gate.py` — Stop hook 本體＋`--sha`／`--check`／`--state-root`／`--calibration-check` CLI
- `scripts/reviewer-probe.sh` — Gate 1 探測＋POSTURE 姿態
- `scripts/grep_dangers.sh` — Gate 4（D1-D13，累積式，事故後追加）
- `scripts/build_audit_report.py` — AUDIT／DISAGREEMENT 報告渲染
- `scripts/calibrate.sh` — 裁判校準（黃金集全跑 → `calibration.json`）
- `scripts/gold-seed/` — 黃金集種子（4 雷題＋2 乾淨題＋`expected.json`）
- 安裝：`~/.claude/settings.json` 的 `hooks.Stop` 指向 review-gate.py；審查端模型設定在 `~/.codex/config.toml`（model／effort 交 codex 預設，**不傳 `-m`**）

## 完成定義（R2，缺一不得宣稱完成）

marker `--check` 印 `valid`（read-back）＋ grep_dangers `FAIL=0` 且 WARN 逐條 defend ＋ 報告已渲染且路徑可開 ＋ ledger 歸檔 `_state` ＋ 回報中的輪數／檔名／sha 是驗過的實際值 ＋ 🔴 工件另需使用者勾選。

## 自我回饋

- 每審歸檔：`$WORK_DIR/_state/cross-model-review/<KEY>-<檔名>/`（ledger、meta、報告）＋ `reviews.log` 追加一列（date/file/reviewer/rounds/verdict/majors）。
- **事故驅動**：每次僵局、或事後發現假 APPROVED／漏審 → `grep_dangers.sh` 追加一條 D 檢查＋CHANGELOG 記錄；同類事故若屬「裁判該抓沒抓」→ 同時做成一題新雷題入 `gold/`（校準集跟著事故長大）。
- **校準飛輪**：仲裁與被人推翻的簽核 → `gold-candidates/`（Step 7），人類獨立定讞的題材免費累積。
- pushback 模式寫 `_state/cross-model-review/pushback-patterns.md` 供人檢視；**刻意不注入審查 prompt**——預載「已知非問題」會誘導審查者，犧牲 fresh-eyes（與 tier-s rejected buffer 用法不同，原因在此）。

## 誠實界線（R6）

1. **自我認證防不了刻意造假**——marker 與 `_state` 證據都是被管的 agent 寫的。sha＋證據五要件（ledger 無 OPEN、r*.txt 非空、**meta.json 綁 marker sha**〔舊證據掩護不了新內容〕、gate4.txt 含 FAIL=0）把「無意抄捷徑」堵死，但對蓄意偽造非密碼學保證；D9 的 CONCEDE 佐證是**計數下界**、非逐列語意比對；signoff.txt 同為 agent 落檔的自我認證。最後防線是 Gate 5 的人。
2. **閘門的強制是「每回合硬擋一次」**——同一 stop 週期第二次起降為 stderr 可見警告（絕不把 session 卡死）；新回合恢復硬擋。marker 寫失敗不會靜默溜過，但也不會無限封鎖。
3. **本 skill 自我納管**——改這份 SKILL.md 就要重審（或吞一次可見警告、下回合補審）。刻意設計：管別人的 skill 自己先被管。
4. **subagent 備援只有 fresh context，沒有跨模型去相關、也沒有校準背書**——🔴 工件因此強制真 codex；🟡 走 subagent 時一律視同 RED（需簽核），codex 的校準不得被備援審查者沿用（D10 驗 reviewer 適用性）。
5. **token 成本真實**——每審一次多輪推理。值不值由風險分級決定；🟢 就別掛 sentinel。
6. **閘門只監看 Write/Edit 類工具的檔案寫入**——經 shell／腳本／批次工具寫出的監看檔不會被攔（解析任意 shell 指令不可靠，寧可明示範圍也不給假安全感）。工作流若用腳本產 plan/spec，須自覺觸發本 skill。
7. **跨模型「降低」而非「消除」共同盲點**——兩個模型可能一起錯（同行實測：在人類唯一獨立判斷的題上，Claude 與 Codex 一起判錯）。校準與閘門都不改變這件事：**真值在人**，這正是 Gate 5 與黃金集都以人類定讞為錨的原因。
8. **模型一致性驗的是「宣告」不是「執行取證」**——校準與 D10 比對的是 config.toml 與紀錄的宣告一致；審查執行當下實際載入的模型並未從事件流獨立取證。審查中途換模再換回這類操縱，屬「蓄意造假」範疇（見 #1），不在機械防線承諾內。
9. **校準是「姿態級」不是「逐審級」**——calibration.json 證明的是裁判「最近、在這個版本上」可信，不是本次判決正確。hook 本身不讀校準（保持簡單、fail-open），但 fail-closed 是**機械的**：校準無效或 🔴 而無 signoff.txt ⇒ D10/D11 FAIL ⇒ gate4 無法 FAIL=0 ⇒ 證據不齊 ⇒ hook 不放行——強制經由既有證據鏈流動。
