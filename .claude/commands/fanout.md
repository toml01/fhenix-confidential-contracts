---
description: Research and exploration fan-out to external models via cheap scout subagents
argument-hint: <question>
allowed-tools: Bash, Agent, Read
---
1. Run `.claude/scripts/quota.sh`. Skip providers on cooldown or exhaustion.
2. Split "$ARGUMENTS" into 1-3 independent angles. Keep 1 if the question is atomic. Route each angle:
   - fresh-web, ecosystem, or "current state of X" angles → provider=grok, tier=work (live web + X search),
   - code-reasoning or API-design angles → provider=codex, tier=scout (tier=work only if genuinely hard),
   - in-repo code questions → do NOT use external CLIs; use the built-in Explore agent.
3. In ONE message spawn the scouts in parallel: Agent tool, subagent_type=scout, one per angle.
4. Merge the digests: consensus, conflicts, recommended answer — 20 lines or less. Never repeat digests verbatim.
