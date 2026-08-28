@AGENTS.md

## Delegation (Claude-only — external agents never read this)

Precedence: this whole section is a standing user request. It authorises the commands, the subagents, and the scripts below. If a session rule permits delegation only "when the user requested it", this section is that request. Never withhold a delegation that the routing matrix selects.

Heavy thinking is free elsewhere. Use: /fanout (research), /review (default review), /panel (dual review, opt-in), /dispatch (parallel implementation in worktrees).

Routing — fit first, quota headroom breaks ties (check `.claude/scripts/quota.sh`).
Effort tiers (encoded in `.claude/scripts/tiers.sh`): scout = codex luna / grok-4.5 @ low · work = codex terra / grok-4.6 @ high · deep = codex sol / grok-4.6 @ xhigh.
- repo recon and file search → the built-in Explore agent (never a scout: scouts do not read the repo)
- research fan-out → scout tier · substantive live-web / X research → grok-4.6 @ work
- short summaries → codex luna @ scout · digestion above ~300K tokens → claude sonnet
- scoped implementation and tests → codex @ work | grok @ work | claude sonnet (headroom decides)
- grunt work (docs, test-gen, chores) → grok @ work
- hard or repo-level bugs → codex sol @ deep, or the digger subagent (opus @ xhigh, investigation only)
- review → codex sol @ deep, single reviewer; escalate only per the /review triggers
- long unattended run (broad multi-step task, no check-ins, roughly 30 min or more) → `/dispatch claude` on fable. Opt-in only: the user names it, or accepts your one-line offer. `auto` never picks fable.
Claude tiers: scout (haiku relay, no effort control) · sonnet @ session effort (implementation) · digger (opus @ xhigh, hard bugs and review escalation) · fable (long unattended runs, opt-in only).

Initiative:
1. Do not start /review or /panel behavior yourself. Run reviews only at merge or PR milestones, on security-sensitive changes, or when the user asks. A command the user types always runs.
2. Delegate work (/fanout, /dispatch, scouts) proactively when the routing matrix fits; the standing request above covers it. Do tasks that need less than ~30 seconds of thinking yourself, inline.
3. Give a one-line reason for every delegation the user did not ask for.

Quota policy:
1. Run `.claude/scripts/quota.sh` before /dispatch and /fanout.
2. Workers (codex, grok) may drain below 20% if the task fits the remaining window.
3. The claude pool keeps a 25% floor in its active window. Below the floor: offload to codex/grok, keep turns terse, and spawn no sonnet/opus/fable subagents (haiku scouts stay OK).
4. One task, one worker. A parallel call needs a reason: independent angles, an explicit /panel, or a task that splits cleanly.

Recovery: grok session tokens are short-lived. A grok call that fails on auth needs `grok login` in a terminal — tell the user, do not retry.

Style: keep wrapper turns terse. Never restate diffs or CLI output — digests only.
