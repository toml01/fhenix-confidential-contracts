#!/usr/bin/env bash
# Manage isolated git worktrees for delegated implementation agents.
# usage: agent-worktree.sh new <name> [base]
#        agent-worktree.sh run <codex|grok> <name> <promptfile> [work|deep]
#        agent-worktree.sh status
#        agent-worktree.sh rm <name>
set -euo pipefail

root=$(git rev-parse --show-toplevel)
wtdir="$root/.worktrees"
cache="${XDG_CACHE_HOME:-$HOME/.cache}/agent-kit"
# shellcheck source=tiers.sh
. "$(cd "$(dirname "$0")" && pwd)/tiers.sh"
cmd=${1:?usage: new|run|status|rm}; shift

case "$cmd" in
  new)
    name=${1:?name}; base=${2:-HEAD}
    git worktree add -b "agent/$name" "$wtdir/$name" "$base"
    # --git-path maps info/ to the shared dir, so this rule is repo-wide. Add it once only.
    ( cd "$wtdir/$name" \
      && ex=$(git rev-parse --git-path info/exclude) \
      && mkdir -p "$(dirname "$ex")" \
      && { grep -qxF '.agent-result.md' "$ex" 2>/dev/null \
           || printf '%s\n' '.agent-result.md' >> "$ex"; } )
    # Agent commits must not wait on gpg pinentry; signing stays on in the main tree.
    git -C "$wtdir/$name" config extensions.worktreeConfig true
    git -C "$wtdir/$name" config --worktree commit.gpgsign false
    git -C "$wtdir/$name" config --worktree tag.gpgsign false
    ;;
  run)
    provider=${1:?codex|grok}; name=${2:?name}; pf=${3:?promptfile}; tier=${4:-work}
    wt="$wtdir/$name"
    [ -d "$wt" ] || { echo "no worktree $wt — run: agent-worktree.sh new $name" >&2; exit 1; }
    [ -f "$pf" ] || { echo "no prompt file $pf" >&2; exit 1; }
    # Absolute path: grok resolves --prompt-file relative to its --cwd, not ours.
    pf="$(cd "$(dirname "$pf")" && pwd)/$(basename "$pf")"
    tier_map "$provider" "$tier"
    mkdir -p "$cache"
    err="$cache/$provider-run.$$"
    rc=0
    case "$provider" in
      codex)
        # --full-auto keeps writes inside -C. Grok has no equivalent flag: for grok
        # the only limit is the "work only inside this directory" line in the prompt.
        codex exec -C "$wt" --full-auto \
          -m "$model" -c model_reasoning_effort="$effort" \
          --output-last-message "$wt/.agent-result.md" - < "$pf" >/dev/null 2>"$err" || rc=$?
        ;;
      grok)
        # </dev/null: grok blocks on an open stdin pipe in non-tty shells
        grok --cwd "$wt" --prompt-file "$pf" \
          -m "$model" --reasoning-effort "$effort" \
          --permission-mode acceptEdits --output-format plain \
          </dev/null > "$wt/.agent-result.md" 2>"$err" || rc=$?
        ;;
    esac
    if [ "$rc" -ne 0 ]; then
      if grep -qiE 'rate.?limit|too many requests|429|usage limit|quota' "$err" 2>/dev/null; then
        date +%s > "$cache/$provider-cooldown"
      fi
      echo "== agent/$name ($provider $model@$effort) FAILED rc=$rc ==" >&2
      tail -3 "$err" >&2 || true
    fi
    rm -f "$err"
    # Auto-commit fallback if the agent left uncommitted work.
    git -C "$wt" add -A
    git -C "$wt" diff --cached --quiet || git -C "$wt" commit -q --no-verify -m "agent/$name: $provider auto-commit"
    base=$(git -C "$root" merge-base HEAD "agent/$name")
    if [ "$(git -C "$root" rev-parse "agent/$name")" = "$base" ]; then
      echo "== agent/$name ($provider $model@$effort) WARNING: no changes produced =="
      echo "-- first lines of result:"
      head -5 "$wt/.agent-result.md" 2>/dev/null || echo "(no result file)"
    else
      echo "== agent/$name ($provider $model@$effort) done =="
      git -C "$wt" log --oneline -3
      git -C "$root" diff --stat "$base" "agent/$name" || true
    fi
    ;;
  status)
    git worktree list
    git branch --list 'agent/*' --format='%(refname:short)' | while read -r b; do
      echo "-- $b"
      git diff --stat "HEAD...$b" || true
    done
    ;;
  rm)
    name=${1:?name}
    git worktree remove "$wtdir/$name" --force
    echo "removed worktree; branch agent/$name kept (delete with: git branch -D agent/$name)"
    ;;
  *) echo "unknown command '$cmd'" >&2; exit 2 ;;
esac
