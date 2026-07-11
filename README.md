# cross-model-review — 跨模型互審閘門

讓 Claude 寫的計劃／規格／skill 文件，在回合結束時被**另一家公司的模型（OpenAI Codex）**以「找碴模式」逐輪審查，達成共識才放行。整個流程由 Stop hook 強制執行——沒有有效的審查標記＋證據，回合結束會被攔下（每個結束週期硬擋一次，其後降為醒目警告、下一回合再攔，避免把 session 卡死；詳見誠實限制）。**不靠自覺，靠結構。**

白話懶人包（機制、好處、誠實限制）👉 https://med95albert.github.io/cross-model-review/

---

## 安裝（三選一）

### ① 一句話安裝（推薦，零技術門檻）

打開 Claude Code，貼上這句話：

> 幫我 clone github.com/med95Albert/cross-model-review 到一個暫存資料夾，然後執行裡面的 install.sh 完成安裝

裝完重開一個 Claude Code session 即生效。

### ② Plugin 兩行（原生外掛）

```
/plugin marketplace add med95Albert/cross-model-review
/plugin install cross-model-review@cross-model-review
```

hook 由 plugin 系統自動註冊，重開 session 生效。

### ③ 手動

```bash
git clone https://github.com/med95Albert/cross-model-review /tmp/cmr && bash /tmp/cmr/install.sh
```

---

## 前置需求

| 需求 | 必要性 |
|---|---|
| Claude Code | 必要 |
| Python 3 | 必要 |
| OpenAI Codex CLI（已登入） | 建議——跨模型審查的另一方；沒有它時，一般（🟡）文件降級為「同模型、新視角」subagent 審查（仍可用，APPROVED 後需你簽核），高風險（🔴）文件不自動降級——會停下請你決定 |

> 校準前請確認 `~/.codex/config.toml` 有明確的 `model = "..."`——校準紀錄綁定裁判模型（codex 實際用誰、就記誰、就驗誰），config 無明確模型時 calibrate.sh 直接拒跑、校準檢查一律視為無效。

## 裁判校準（v1.1，建議首跑）

「換一個模型當裁判」還不夠——**裁判本身要被證明可信，不能被假設**。安裝後對 Claude 說「幫我跑 cross-model-review 的 calibrate.sh」（約 6 次 codex 呼叫）。內建黃金集＝4 題已知缺陷（各測一種抓雷能力）＋2 題乾淨計劃（測「不亂抓」）；雷題全中＋乾淨題 ≥1 過才 PASS。**未校準／逾 30 天／codex 換版／換裁判模型 → fail-closed**：審查照跑，但 APPROVED 後仍需你簽核才放行。逐題原文與跨次歷史存於 `gold/runs/`。

## 怎麼用

九成情境不用主動呼叫：Claude 用 Write/Edit 寫了 `plans/`、`specs/` 下的 `.md`，或含獨立一行 `<!-- cross-model-gated -->` 的 SKILL.md，回合結束自動被攔下審查。手動點名：「叫 codex 審這份 `<路徑>`」。納管既有 skill：在它的 SKILL.md 加獨立一行 sentinel。

審查達成 APPROVED（或 5 輪僵局交你裁決）才蓋防偽標記；標記綁內容指紋，審後改一字即失效重審。放行需「有效標記＋四件歸檔證據」齊備且綁定本版內容：帳本（無未解項）、逐輪審查原文、meta（含內容指紋）、finalize 當下的 Gate 4 全綠紀錄（校準狀態與簽核要求在此時強制）。已完成的審查不因日後校準過期而追溯失效——校準約束的是「下一次審查」。

## 驗證與維運

安裝方式 ①③（skill 落在 `~/.claude/skills/`）：

```bash
bash ~/.claude/skills/cross-model-review/scripts/reviewer-probe.sh   # 審查者＋校準姿態
bash ~/.claude/skills/cross-model-review/selftest.sh                  # 全套合成測試，零 token（安裝時已常駐，結尾自報條數）
```

安裝方式 ②（plugin，skill 在 plugin 目錄內）：對 Claude 說「跑 cross-model-review 的 reviewer-probe」即可；要跑 selftest 就把 `CROSS_REVIEW_SKILL_DIR` 指向 plugin 內的 skill 目錄再執行。

| 內容 | 路徑 |
|---|---|
| skill 本體 | `~/.claude/skills/cross-model-review/` |
| Stop hook | `~/.claude/settings.json` 的 `hooks.Stop`（或 plugin 自帶） |
| 審查證據＋黃金集 | `~/.claude/cross-model-review/state/`（`CROSS_REVIEW_STATE_ROOT` 可覆蓋） |

解除安裝——依安裝方式：①③ 執行 `bash ~/.claude/skills/cross-model-review/uninstall.sh`（安裝時已常駐；`--purge` 連證據一併刪除，尊重 `CROSS_REVIEW_STATE_ROOT`）；② 用 `/plugin uninstall cross-model-review@cross-model-review`（再 `/plugin marketplace remove cross-model-review`），證據目錄如要刪除需手動。

## 誠實限制

- **防無心，不防蓄意**——標記與證據皆為 agent 自我落檔；防偽設計把抄捷徑堵死，擋不住刻意偽造。高風險輸出保留人類簽核。
- **跨模型「降低」而非「消除」共同盲點**——兩個模型可能一起錯；真值在人。
- **只攔 Write/Edit 類工具寫的檔**——shell 腳本產的檔要手動送審。另有刻意的 fail-open 邊界：單檔逾 2MB、寫入落在 transcript 掃描上限（最後 30MB）之外、或閘門自身遭遇基礎設施異常（檔案讀取失敗、transcript 解析失敗、證據庫存取錯誤）時，一律放行不擋——寧可漏攔一次，不把你的 session 卡死。防的是無心抄捷徑，不是完備防護。
- **審查有 token 成本**——只審會被照著執行的文件；草稿別放監看路徑。

MIT License ・ 環境：Claude Code × OpenAI Codex CLI

<!-- cross-model-reviewed: 2026-07-11T04:31:49Z rounds=2 verdict=approved reviewer=subagent:claude-opus-4-8 sha=126b677cbf3d3d91 -->

<!-- cross-model-reviewed: 2026-07-11T06:28:43Z rounds=3 verdict=approved reviewer=codex:gpt-5.6-sol sha=20f0979e1ad12ce0 -->
