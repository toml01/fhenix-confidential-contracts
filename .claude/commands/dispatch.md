---
description: Delegate an implementation task to codex, grok, or claude in an isolated git worktree; keep working meanwhile
argument-hint: <codex|grok|claude|both|auto> <kebab-name> <task description>
allowed-tools: Bash, Read, Write, Agent
---
Provider selection:
- `auto` → run `.claude/scripts/quota.sh`, then pick by fit: scoped or mechanical work → codex (work), grok (work), or claude sonnet — take the one with the most headroom; hard or repo-level work → codex deep or claude opus. `auto` never picks fable. State your pick and the reason in ONE line.
- `both` → two worktrees, `<name>-cx` (codex) and `<name>-gk` (grok), same prompt; compare the results on completion.

External providers (codex, grok):
1. `.claude/scripts/agent-worktree.sh new <name>`
2. Write `.worktrees/<name>.prompt.md`: goal, constraints, relevant paths, acceptance criteria, and this footer:
   "Work only inside this directory. Run the test suite. Commit all your work with the message 'agent/<name>: <summary>'. Do not push."
3. Launch in background Bash: `.claude/scripts/agent-worktree.sh run <provider> <name> .worktrees/<name>.prompt.md <work|deep>` — use deep only when the user calls the task hard.
4. Return to the user's other work immediately.
5. On the completion notification: report the diffstat plus the first 10 lines of `.worktrees/<name>/.agent-result.md`. If the script printed a FAILED line, report that error instead and stop. Then tell the user how to finish — the wording depends on the path taken:
   - one provider: review with `git diff HEAD...agent/<name>`, merge or cherry-pick, then `.claude/scripts/agent-worktree.sh rm <name>`.
   - `both`: the same for `agent/<name>-cx` and `agent/<name>-gk`, and remove BOTH worktrees by those names.

Claude provider:
- Spawn one Agent (general-purpose) with isolation: "worktree", model sonnet — opus only if the task is hard. Give it the same prompt content as step 2 and tell it to commit its work on its branch, and to name that branch in its final message.
- Fable: use it only when the user names fable, or when the task is a long unattended run and the user accepts your offer. If the task is broad, multi-step, and needs no check-ins, offer it in ONE line ("this looks like a long unattended run — fable?") and wait. Never assume it. The claude 25% floor in CLAUDE.md applies to fable as it does to opus.
- The harness owns this worktree path and branch name, and it clears the worktree itself. `agent-worktree.sh` does NOT apply here: never tell the user to run `rm <name>`, and never assume the branch is `agent/<name>`. Report the branch the agent gives back, and review it with `git diff HEAD...<that-branch>`.
