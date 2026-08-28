#!/usr/bin/env bash
# Relay one prompt (stdin) to an external CLI and print its final answer.
# usage: <prompt on stdin> | consult.sh <codex|grok> <scout|work|deep> [outfile] [cwd]
set -euo pipefail

provider=${1:?usage: consult.sh <codex|grok> <scout|work|deep> [outfile] [cwd]}
tier=${2:?tier: scout|work|deep}
out=${3:-}
dir=${4:-$PWD}
cache="${XDG_CACHE_HOME:-$HOME/.cache}/agent-kit"
mkdir -p "$cache"

tmp=$(mktemp)
[ -n "$out" ] || { out=$(mktemp); own_out=1; }
cleanup() {
  rm -f "$tmp"
  if [ -n "${err:-}" ]; then rm -f "$err"; fi
  if [ -n "${own_out:-}" ]; then rm -f "$out"; fi
  return 0
}
trap cleanup EXIT
cat > "$tmp"

# shellcheck source=tiers.sh
. "$(cd "$(dirname "$0")" && pwd)/tiers.sh"
tier_map "$provider" "$tier"

# PID-suffixed: /fanout runs several consults at once.
err="$cache/$provider-last-err.$$"
rc=0
case "$provider" in
  codex)
    # MCP-free on purpose: headless codex auto-cancels MCP tool approvals.
    codex exec -C "$dir" --sandbox read-only \
      -m "$model" -c model_reasoning_effort="$effort" \
      --output-last-message "$out" - < "$tmp" >/dev/null 2>"$err" || rc=$?
    ;;
  grok)
    # </dev/null: grok blocks on an open stdin pipe in non-tty shells
    grok --cwd "$dir" --prompt-file "$tmp" \
      -m "$model" --reasoning-effort "$effort" \
      --permission-mode dontAsk --no-subagents \
      --output-format plain </dev/null > "$out" 2>"$err" || rc=$?
    ;;
esac

if [ "$rc" -ne 0 ]; then
  if grep -qiE 'rate.?limit|too many requests|429|usage limit|quota' "$err" "$out" 2>/dev/null; then
    date +%s > "$cache/$provider-cooldown"
  fi
  echo "consult $provider:$tier ($model@$effort) failed rc=$rc:" >&2
  tail -3 "$err" >&2 || true
  exit "$rc"
fi
cat "$out"
