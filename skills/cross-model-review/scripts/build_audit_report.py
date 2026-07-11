#!/usr/bin/env python3
"""Render a human-readable report from a cross-model-review run.

Usage:
  build_audit_report.py <review_dir> [--out FILE]

Reads from review_dir (everything optional; renders what exists, names what
is missing so gaps are visible instead of silent):
  meta.json  {"file","reviewer","rounds","verdict","started","finished"}
  ledger.md  round-by-round issue ledger (Gate 2)
  r<N>.txt   reviewer output per round
  gate4.txt  saved grep_dangers output

Writes AUDIT_REPORT.md (verdict=approved) or DISAGREEMENT_REPORT.md
(anything else) into review_dir unless --out is given. Prints the path.
"""
import glob
import json
import os
import re
import sys


def read(p):
    try:
        with open(p, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return None


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    rdir = sys.argv[1]
    out = None
    if "--out" in sys.argv:
        i = sys.argv.index("--out")
        if i + 1 < len(sys.argv):
            out = sys.argv[i + 1]
    if not os.path.isdir(rdir):
        print(f"not a directory: {rdir}", file=sys.stderr)
        return 2

    meta = {}
    raw = read(os.path.join(rdir, "meta.json"))
    if raw:
        try:
            meta = json.loads(raw)
        except json.JSONDecodeError:
            pass
    ledger = read(os.path.join(rdir, "ledger.md"))
    gate4 = read(os.path.join(rdir, "gate4.txt"))
    rounds = sorted(glob.glob(os.path.join(rdir, "r[0-9]*.txt")))

    verdict = str(meta.get("verdict", "unknown"))
    title = "AUDIT_REPORT" if verdict == "approved" else "DISAGREEMENT_REPORT"

    L = [f"# {title} — cross-model-review", ""]
    L.append(f"- 被審檔：{meta.get('file', '(meta.json 缺)')}")
    L.append(
        f"- 審查者：{meta.get('reviewer', '?')}　輪數：{meta.get('rounds', '?')}"
        f"　verdict：{verdict}"
    )
    L.append(f"- 起訖：{meta.get('started', '?')} → {meta.get('finished', '?')}")
    L.append("")
    L.append("## 每輪裁決")
    if rounds:
        for p in rounds:
            t = read(p) or ""
            m = re.search(r"##\s*Verdict\s*\n\s*(.+)", t)
            v = m.group(1).strip() if m else "(無 ## Verdict——需人工看原文)"
            L.append(f"- {os.path.basename(p)}: {v}")
    else:
        L.append("- （無審查輸出檔——不正常，Gate 4 D7 應已 FAIL）")
    L.append("")
    L.append("## 異議帳本（Gate 2 ledger）")
    L.append(ledger.strip() if ledger else "（無 ledger.md——Gate 2 未落盤，不合協定）")

    if verdict == "arbitrated":
        L.append("")
        L.append("## 仲裁結果（人類裁決紀錄）")
        arb_rows = []
        if ledger:
            arb_rows = [ln for ln in ledger.splitlines() if "ARBITRATED" in ln]
        if arb_rows:
            L += [f"- {r.strip()}" for r in arb_rows]
        else:
            L.append("- （ledger 無 ARBITRATED 列——仲裁紀錄不完整，請人工核對）")
        signoff = read(os.path.join(rdir, "signoff.txt"))
        L.append("")
        L.append("### 使用者簽核原文")
        L.append(signoff.strip() if signoff else "（無 signoff.txt——仲裁 finalize 必須附簽核）")
    elif verdict != "approved":
        L.append("")
        L.append("## 待人類裁決（OPEN 項）")
        L.append("下列每項請指名裁決（R3：單獨「好／OK」不算核准）：")
        open_rows = []
        if ledger:
            open_rows = [
                ln for ln in ledger.splitlines() if re.search(r"\|\s*OPEN\s*\|", ln)
            ]
        if open_rows:
            L += [f"- [ ] {r.strip()}" for r in open_rows]
        else:
            L.append("- （ledger 無 OPEN 列——請人工核對雙方最後一輪原文）")
        L.append("")
        L.append(
            "裁決選項：ACCEPT-CLAUDE（維持原文）／ACCEPT-REVIEWER（照審查者意見改）"
            "／其他明確指示。"
        )

    L.append("")
    L.append("## Gate 4（grep_dangers）")
    if gate4:
        L.append("```")
        L.append(gate4.strip())
        L.append("```")
    else:
        L.append("（未附 gate4.txt——請跑 grep_dangers.sh 並 tee 存檔）")
    L.append("")

    dest = out or os.path.join(rdir, f"{title}.md")
    with open(dest, "w", encoding="utf-8") as f:
        f.write("\n".join(L) + "\n")
    print(dest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
