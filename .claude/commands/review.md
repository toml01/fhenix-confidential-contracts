---
description: Default code review — one external reviewer (Codex Sol @ xhigh); second opinion only on triggers
argument-hint: [file-to-review] (default = git diff HEAD)
allowed-tools: Bash, Read, Agent
---
Review the current changes with ONE external reviewer. Be token-frugal: never restate the diff and never quote the review verbatim.

1. Run `.claude/scripts/quota.sh`. If codex is exhausted in both its windows, use `.claude/scripts/consult.sh grok deep` instead and say so in one line.
2. Launch ONE background Bash call:
   ```
   { echo "Review the following changes. Report real bugs, risks, and missing tests. Max 20 bullets, cite file:line. End with exactly one line: VERDICT: ship | fix-first | rethink."; if [ -n "$ARGUMENTS" ]; then cat "$ARGUMENTS"; else git diff HEAD; fi; } | .claude/scripts/consult.sh codex deep /tmp/review-codex.md
   ```
3. When it completes, Read /tmp/review-codex.md. Synthesize in 10 lines or less: the material findings and the verdict.
4. Escalate to a SECOND reviewer ONLY if at least one condition holds:
   - the verdict is fix-first or rethink,
   - the diff touches security, crypto, auth, or key-handling paths,
   - the user explicitly asked for a second opinion.
   Second reviewer: spawn the digger subagent (it runs the diff command itself and reviews with the same instructions) — but only if claude 5h usage is below 75%; otherwise use `.claude/scripts/consult.sh grok deep`. Report agreements, disagreements, and your ruling in 8 lines or less.
