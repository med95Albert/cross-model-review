#!/usr/bin/env python3
"""cross-model-review Stop hook: block turn-end when a watched artifact was
written this turn but lacks a valid, content-bound, evidence-backed review
marker.

Watched artifacts (edit WATCHED_* below to tune):
  1. Markdown files under any `plans/` or `specs/` directory
  2. SKILL.md files that opt in with a STANDALONE sentinel line
     `<!-- cross-model-gated -->` — a prose mention of the string does not
     opt in (learned live: the first false positive was a doc that merely
     talked about the sentinel)

Marker, appended at EOF by the cross-model-review skill (placeholder shown
with non-matching fields so this docstring never satisfies the real regex):
  <!-- cross-model-reviewed: <ISO8601Z> rounds=<N> verdict=approved reviewer=<id> sha=<16hex> -->

`sha` = first 16 hex chars of sha256 over the file content with all real
marker lines removed (trailing blank lines excluded). Editing the file after
review invalidates the marker. Verification and marker-writing share this
single implementation via `--sha`.

A valid marker alone is NOT sufficient: the review must have left evidence
in the state archive under STATE_ROOT/<key>-<basename>/ where key =
sha256(abs path)[:16]. Evidence core (all five required): ledger.md with no
OPEN rows, at least one non-empty r*.txt, meta.json whose "sha" field
EQUALS the marker's sha (evidence is version-bound — old evidence cannot
cover newly edited content), and gate4.txt containing "FAIL=0". This stops
the cheapest bypasses (self-signing via `--sha`; reusing a stale archive).
Deliberate forgery of the whole evidence trail remains possible — the
human checkpoint is the final defence, as documented.

Anti-loop honesty: when stop_hook_active is set (this hook already blocked
once in this stop cycle) the gate DOWNGRADES to a visible warning (exit 1,
stderr) instead of blocking, so a failed review can never wedge the session
— but the leak is loudly reported, never silent. A fresh stop cycle (next
turn) re-blocks while the artifact remains unreviewed.

CLI:
  review-gate.py                      hook mode: read Stop payload from stdin
  review-gate.py --sha FILE           print the content sha the marker must carry
  review-gate.py --check FILE         print valid|stale|missing; exit 0 only if valid
  review-gate.py --state-root         print the resolved state root (single source of truth)
  review-gate.py --calibration-check  judge-calibration state; exit 0 only if valid
                                      (exists, overall PASS, within valid_days, codex
                                      version unchanged). Used by probe (posture) and
                                      Gate 4 D10 — NOT by hook mode, which stays simple.

Hook mode is fail-open on infra errors (bad payload, unreadable transcript,
evidence-store exceptions) — it must never brick a session on its own bugs.
"""

from __future__ import annotations

import glob
import hashlib
import json
import os
import re
import sys

WATCHED_DIR_SUBSTRS = ("/plans/", "/specs/")
WATCHED_SUFFIX = ".md"
SKILL_BASENAME = "SKILL.md"
SENTINEL_RE = re.compile(r"^\s*<!--\s*cross-model-gated\s*-->\s*$", re.MULTILINE)
MARKER_RE = re.compile(
    r"<!--\s*cross-model-reviewed:\s*\S+\s+rounds=(\d+)\s+"
    r"verdict=(approved|arbitrated)\s+reviewer=(\S+)\s+sha=([0-9a-f]{16})\s*-->",
    re.IGNORECASE,
)
WRITE_TOOLS = {"Write", "Edit", "MultiEdit", "NotebookEdit"}
MAX_BYTES = 2_000_000  # bigger reviewed files fail open
MAX_TRANSCRIPT_BYTES = 30_000_000  # scan the whole transcript up to this cap
STATE_ROOT = os.environ.get(
    "CROSS_REVIEW_STATE_ROOT",
    os.path.expanduser("~/.claude/cross-model-review/state"),
)


def _read_text(path: str):
    try:
        if os.path.getsize(path) > MAX_BYTES:
            return None
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return None


def content_sha(text: str) -> str:
    # Trailing blank lines are excluded so that appending the marker (which
    # adds a separating newline) cannot itself invalidate the sha.
    kept = [ln for ln in text.split("\n") if not MARKER_RE.search(ln)]
    while kept and kept[-1].strip() == "":
        kept.pop()
    return hashlib.sha256("\n".join(kept).encode("utf-8")).hexdigest()[:16]


def is_watched(path: str, text: str | None) -> bool:
    p = path.replace(os.sep, "/")
    if os.path.basename(p) == SKILL_BASENAME:
        return text is not None and SENTINEL_RE.search(text) is not None
    return p.endswith(WATCHED_SUFFIX) and any(s in p for s in WATCHED_DIR_SUBSTRS)


def marker_state(text: str) -> str:
    """State of the LAST marker in text: valid | stale | missing."""
    matches = list(MARKER_RE.finditer(text))
    if not matches:
        return "missing"
    return "valid" if matches[-1].group(4).lower() == content_sha(text) else "stale"


def marker_sha(text: str) -> str:
    """The LAST marker's sha field (lowercase), or '' if no marker."""
    matches = list(MARKER_RE.finditer(text))
    return matches[-1].group(4).lower() if matches else ""


def has_review_evidence(path: str, expected_sha: str) -> bool:
    """A valid marker must be backed by the archived review trail under
    STATE_ROOT/<key>-<basename>/ — all five: ledger.md with no OPEN rows,
    a non-empty r*.txt, meta.json whose "sha" equals the marker's sha
    (version binding: stale archives cannot cover re-edited content),
    gate4.txt containing FAIL=0. Missing/mismatched evidence -> treat as
    unreviewed. Unexpected infra errors fail open."""
    try:
        key = hashlib.sha256(path.encode("utf-8")).hexdigest()[:16]
        d = os.path.join(STATE_ROOT, f"{key}-{os.path.basename(path)}")
        ledger = os.path.join(d, "ledger.md")
        if not os.path.isfile(ledger):
            return False
        with open(ledger, encoding="utf-8", errors="replace") as f:
            if re.search(r"\|\s*OPEN\s*\|", f.read()):
                return False
        if not any(
            os.path.getsize(p) > 0 for p in glob.glob(os.path.join(d, "r*.txt"))
        ):
            return False
        meta_path = os.path.join(d, "meta.json")
        if not os.path.isfile(meta_path):
            return False
        try:
            with open(meta_path, encoding="utf-8", errors="replace") as f:
                meta = json.load(f)
        except json.JSONDecodeError:
            return False  # malformed evidence is not evidence
        if str(meta.get("sha", "")).lower() != expected_sha.lower():
            return False  # evidence belongs to a different content version
        gate4 = os.path.join(d, "gate4.txt")
        if not os.path.isfile(gate4):
            return False
        with open(gate4, encoding="utf-8", errors="replace") as f:
            return "FAIL=0" in f.read()
    except Exception:
        return True  # infra fail-open — never brick on evidence-store errors


def _iter_tool_inputs(transcript_path: str):
    try:
        size = os.path.getsize(transcript_path)
        with open(transcript_path, "r", encoding="utf-8", errors="replace") as f:
            if size > MAX_TRANSCRIPT_BYTES:
                f.seek(size - MAX_TRANSCRIPT_BYTES)
                f.readline()  # drop the partial line at the seek point
            lines = f.readlines()
    except (OSError, UnicodeDecodeError):
        return
    for raw in lines:
        raw = raw.strip()
        if not raw:
            continue
        try:
            entry = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if entry.get("type") != "assistant":
            continue
        msg = entry.get("message") or {}
        if msg.get("role") != "assistant":
            continue
        content = msg.get("content")
        if not isinstance(content, list):
            continue
        for block in content:
            if (
                isinstance(block, dict)
                and block.get("type") == "tool_use"
                and block.get("name", "") in WRITE_TOOLS
            ):
                inp = block.get("input") or {}
                if isinstance(inp, dict):
                    yield inp


def _touched_paths(transcript_path: str, cwd: str) -> list[str]:
    ordered: list[str] = []
    seen: set[str] = set()
    for inp in _iter_tool_inputs(transcript_path):
        fp = inp.get("file_path") or inp.get("notebook_path") or ""
        if not isinstance(fp, str) or not fp:
            continue
        ab = fp if os.path.isabs(fp) else os.path.normpath(os.path.join(cwd, fp))
        if ab not in seen:
            seen.add(ab)
            ordered.append(ab)
    ordered.reverse()  # most-recent-first
    return ordered


def _describe(state: str) -> str:
    return {
        "missing": "no review marker",
        "stale": "marker sha no longer matches content (edited after review)",
        "valid": "marker ok but review evidence missing — finish the _state archive step",
    }.get(state, state)


def _block_reason(unreviewed: list[tuple[str, str]]) -> str:
    lines = "\n".join(f"  - {p}  [{_describe(s)}]" for p, s in unreviewed)
    return (
        "Cross-model review pending.\n\n"
        f"Watched artifact(s) written this turn without a valid, evidence-backed "
        f"review marker:\n{lines}\n\n"
        "Invoke the `cross-model-review` skill (Skill tool) now and review before "
        "ending the turn. Protocol: reviewer probe -> iterative falsification "
        "dialogue (round cap 5) -> verdict APPROVED, or human arbitration on "
        "deadlock -> finalize (sha-bound marker + _state evidence archive). The "
        "sha is recomputed by this hook, so any edit after review re-triggers the "
        "gate; finish ALL content edits first, then finalize."
    )


def calibration_state() -> tuple[bool, str]:
    """Is the judge's gold-set calibration currently trustworthy?"""
    import datetime
    import subprocess

    cal = os.path.join(STATE_ROOT, "calibration.json")
    try:
        with open(cal, encoding="utf-8") as f:
            c = json.load(f)
    except (OSError, json.JSONDecodeError):
        return False, "無校準紀錄（calibration.json 不存在或不可讀）"
    if c.get("overall") != "PASS":
        return False, f"最近一次校準未通過（{c.get('date', '?')}）"
    try:
        d = datetime.datetime.fromisoformat(str(c.get("date", "")).replace("Z", "+00:00"))
        age = (datetime.datetime.now(datetime.timezone.utc) - d).days
    except ValueError:
        return False, "校準日期無法解析"
    valid_days = int(c.get("valid_days", 30))
    if age > valid_days:
        return False, f"校準已過期（{age} 天前，效期 {valid_days} 天）"
    try:
        cur = subprocess.run(
            ["codex", "--version"], capture_output=True, text=True, timeout=10
        ).stdout.strip().splitlines()[0]
    except Exception:
        cur = ""  # codex 不可得時不以版本否決（缺席由 probe 另行處理）
    rec = str(c.get("codex_version", ""))
    if cur and rec and cur != rec:
        return False, f"codex 版本已變（{rec} → {cur}），需重校準"
    return True, f"有效（{c.get('date', '?')}，{rec or '版本未記'}，{age} 天前）"


def main() -> int:
    if len(sys.argv) >= 2 and sys.argv[1] == "--state-root":
        print(STATE_ROOT)
        return 0
    if len(sys.argv) >= 2 and sys.argv[1] == "--calibration-check":
        ok, msg = calibration_state()
        print(msg)
        return 0 if ok else 1
    if len(sys.argv) >= 3 and sys.argv[1] in ("--sha", "--check"):
        text = _read_text(sys.argv[2])
        if text is None:
            print("unreadable or too large", file=sys.stderr)
            return 2
        if sys.argv[1] == "--sha":
            print(content_sha(text))
            return 0
        state = marker_state(text)
        print(state)
        return 0 if state == "valid" else 1

    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0
    if not isinstance(payload, dict):
        return 0
    stop_active = bool(payload.get("stop_hook_active"))
    transcript_path = payload.get("transcript_path")
    if not isinstance(transcript_path, str) or not os.path.exists(transcript_path):
        return 0
    cwd = payload.get("cwd") or os.getcwd()
    if not isinstance(cwd, str):
        cwd = os.getcwd()

    unreviewed: list[tuple[str, str]] = []
    for p in _touched_paths(transcript_path, cwd):
        if not os.path.exists(p):
            continue
        text = _read_text(p)
        if text is None:  # unreadable/huge: fail open for this file
            continue
        if not is_watched(p, text):
            continue
        state = marker_state(text)
        if state == "valid" and has_review_evidence(p, marker_sha(text)):
            continue
        unreviewed.append((p, state))

    if not unreviewed:
        return 0

    if stop_active:
        # Already blocked once this stop cycle. Never wedge the session —
        # downgrade to a loud, visible warning instead of a silent pass.
        print(
            "cross-model-review: unreviewed watched artifact(s) still present "
            "(released to avoid a stop loop — a fresh turn will re-block):\n"
            + "\n".join(f"  - {p}  [{_describe(s)}]" for p, s in unreviewed),
            file=sys.stderr,
        )
        return 1  # non-blocking error: shown to the user, does not block

    print(json.dumps({"decision": "block", "reason": _block_reason(unreviewed)}))
    return 0


if __name__ == "__main__":
    if len(sys.argv) > 1:
        sys.exit(main())  # CLI modes surface real errors
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)  # hook mode: absolute fail-open
