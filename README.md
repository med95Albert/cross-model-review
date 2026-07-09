# cross-model-review — 跨模型互審閘門

讓 Claude 寫的計劃／規格／skill 文件，在回合結束時被**另一家公司的模型（OpenAI Codex）**以「找碴模式」逐輪審查，達成共識才放行。整個流程由 Stop hook 強制執行——沒有有效的審查標記＋證據，回合結束不了。**不靠自覺，靠結構。**

白話懶人包（機制、好處、誠實限制）👉 https://med95albert.github.io/cross-model-review/

---

## 安裝（三選一）

### ① 一句話安裝（推薦，零技術門檻）

打開 Claude Code，貼上這句話：

> 幫我把 github.com/med95Albert/cross-model-review 這個技能裝到 ~/.claude/skills/cross-model-review，然後執行裡面的 install.sh 完成 Stop hook 註冊

裝完重開一個 Claude Code session 即生效。

### ② Plugin 兩行（原生外掛）

```
/plugin marketplace add med95Albert/cross-model-review
/plugin install cross-model-review@cross-model-review
```

hook 由 plugin 系統自動註冊，重開 session 生效。

### ③ 手動

```bash
git clone https://github.com/med95Albert/cross-model-review ~/.claude/skills/cross-model-review
bash ~/.claude/skills/cross-model-review/install.sh
```

---

## 前置需求

| 需求 | 必要性 |
|---|---|
| Claude Code | 必要 |
| Python 3 | 必要 |
| OpenAI Codex CLI（已登入） | 建議——跨模型審查的另一方；沒有它自動降級為「同模型、新視角」subagent（仍可用，少了跨模型去相關） |

## 裁判校準（v1.1，建議首跑）

「換一個模型當裁判」還不夠——**裁判本身要被證明可信，不能被假設**。安裝後對 Claude 說「幫我跑 cross-model-review 的 calibrate.sh」（約 6 次 codex 呼叫）。內建黃金集＝4 題已知缺陷（各測一種抓雷能力）＋2 題乾淨計劃（測「不亂抓」）；雷題全中＋乾淨題 ≥1 過才 PASS。**未校準／逾 30 天／codex 換版 → fail-closed**：審查照跑，但 APPROVED 後仍需你簽核才放行。逐題原文與跨次歷史存於 `gold/runs/`。

## 怎麼用

九成情境不用主動呼叫：Claude 用 Write/Edit 寫了 `plans/`、`specs/` 下的 `.md`，或含獨立一行 `<!-- cross-model-gated -->` 的 SKILL.md，回合結束自動被攔下審查。手動點名：「叫 codex 審這份 `<路徑>`」。納管既有 skill：在它的 SKILL.md 加獨立一行 sentinel。

審查達成 APPROVED（或 5 輪僵局交你裁決）才蓋防偽標記；標記綁內容指紋，審後改一字即失效重審；證據（帳本／逐輪原文／校準狀態／簽核）綁版本歸檔，缺一不放行。

## 驗證與維運

```bash
bash ~/.claude/skills/cross-model-review/scripts/reviewer-probe.sh   # 審查者＋校準姿態
bash selftest.sh                                                      # 52 條合成測試，零 token
```

| 內容 | 路徑 |
|---|---|
| skill 本體 | `~/.claude/skills/cross-model-review/` |
| Stop hook | `~/.claude/settings.json` 的 `hooks.Stop`（或 plugin 自帶） |
| 審查證據＋黃金集 | `~/.claude/cross-model-review/state/`（`CROSS_REVIEW_STATE_ROOT` 可覆蓋） |

解除安裝：`bash uninstall.sh`（`--purge` 連證據一併刪除）。

## 誠實限制

- **防無心，不防蓄意**——標記與證據皆為 agent 自我落檔；防偽設計把抄捷徑堵死，擋不住刻意偽造。高風險輸出保留人類簽核。
- **跨模型「降低」而非「消除」共同盲點**——兩個模型可能一起錯；真值在人。
- **只攔 Write/Edit 類工具寫的檔**——shell 腳本產的檔要手動送審。
- **審查有 token 成本**——只審會被照著執行的文件；草稿別放監看路徑。

MIT License ・ 環境：Claude Code × OpenAI Codex CLI
