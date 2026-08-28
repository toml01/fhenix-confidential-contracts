---
description: Explicit dual review — Codex Sol + Grok 4.6 in parallel; Opus tiebreak only on conflict
argument-hint: [file-to-review] (default = git diff HEAD)
allowed-tools: Bash, Read, Agent
---
Dual second opinion (user opted in). Token-frugal: never restate the diff and never quote reviews verbatim.

1. Run `.claude/scripts/quota.sh`. Skip a provider on cooldown or exhaustion; if only one provider is available, fall back to /review behavior with that provider.
2. In ONE message launch TWO background Bash calls, each piping the same content:
   ```
   { echo "Review the following changes. Report real bugs, risks, and missing tests. Max 20 bullets, cite file:line. End with exactly one line: VERDICT: ship | fix-first | rethink."; if [ -n "$ARGUMENTS" ]; then cat "$ARGUMENTS"; else git diff HEAD; fi; } | .claude/scripts/consult.sh codex deep /tmp/panel-codex.md
   ```
   and the same pipeline into `.claude/scripts/consult.sh grok deep /tmp/panel-grok.md`.
3. When both complete, Read both output files. Synthesize in 15 lines or less: agreements, disagreements with your ruling, combined verdict.
4. ONLY if the two verdicts conflict on a correctness issue AND claude 5h usage is below 75%: spawn the digger subagent to arbitrate that specific disagreement (it reads the diff itself). Report its ruling in 5 lines or less.
