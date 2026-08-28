#!/usr/bin/env bash
# Print usage headroom for codex, claude, grok. Degrades to "unknown" per provider — never fails hard.
# usage: quota.sh
set -uo pipefail

cache="${XDG_CACHE_HOME:-$HOME/.cache}/agent-kit"
mkdir -p "$cache"
now=$(date +%s)

# --- codex: app-server JSON-RPC. Free — consumes no model tokens.
# 180s cache, as for claude and grok: the probe itself costs a 4s handshake wait. ---
raw="$cache/codex-rl.json"
age=$(( now - $(stat -f %m "$raw" 2>/dev/null || echo 0) ))
if [ ! -s "$raw" ] || [ "$age" -ge 180 ]; then
  { printf '%s\n' \
      '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"clientInfo":{"name":"agent-kit","title":"agent-kit","version":"0.1.0"}}}' \
      '{"jsonrpc":"2.0","method":"initialized","params":{}}' \
      '{"jsonrpc":"2.0","id":1,"method":"account/rateLimits/read","params":{}}'
    sleep 4
  } | codex app-server > "$raw.tmp" 2>/dev/null
  if [ -s "$raw.tmp" ]; then mv "$raw.tmp" "$raw"; else rm -f "$raw.tmp"; fi
fi

codex_line=$(python3 - "$raw" <<'PY' 2>/dev/null
import sys, json, datetime

def when(ts):
    try:
        t = datetime.datetime.fromtimestamp(int(float(ts)))
    except (TypeError, ValueError):
        return "?"
    d = (t.date() - datetime.date.today()).days
    return t.strftime("%H:%M") + (" (+%dd)" % d if d > 0 else "")

for line in open(sys.argv[1]):
    try:
        msg = json.loads(line)
    except json.JSONDecodeError:
        continue
    if msg.get("id") == 1 and "result" in msg:
        r = msg["result"]
        rl = r.get("rateLimits") or {}
        p = rl.get("primary") or {}
        s = rl.get("secondary") or {}
        credits = (r.get("rateLimitResetCredits") or {}).get("availableCount", 0)
        print("5h %s%% used (resets %s) | weekly %s%% used (resets %s) | reset-credits %s"
              % (p.get("usedPercent", "?"), when(p.get("resetsAt")),
                 s.get("usedPercent", "?"), when(s.get("resetsAt")), credits))
        break
PY
)

# Fallback: parse the newest session rollout (stale-by-design, still useful).
if [ -z "${codex_line:-}" ]; then
  codex_line=$(python3 - <<'PY' 2>/dev/null
import glob, os, json, datetime

def when(ts):
    try:
        t = datetime.datetime.fromtimestamp(int(float(ts)))
    except (TypeError, ValueError):
        return "?"
    d = (t.date() - datetime.date.today()).days
    return t.strftime("%H:%M") + (" (+%dd)" % d if d > 0 else "")

files = sorted(glob.glob(os.path.expanduser("~/.codex/sessions/*/*/*/rollout-*.jsonl")),
               key=os.path.getmtime)
for f in reversed(files[-5:] if len(files) >= 5 else files):
    last = None
    for line in open(f, errors="replace"):
        if '"rate_limits"' in line:
            last = line
    if not last:
        continue
    try:
        obj = json.loads(last)
    except json.JSONDecodeError:
        continue
    rl = (obj.get("payload") or {}).get("rate_limits") or obj.get("rate_limits") or {}
    p = rl.get("primary") or {}
    s = rl.get("secondary") or {}

    def pct(d):
        return d.get("used_percent", d.get("usedPercent", "?"))

    def rst(d):
        return d.get("resets_at", d.get("resetsAt"))

    print("5h %s%% used (resets %s) | weekly %s%% used (resets %s) [stale, from last session]"
          % (pct(p), when(rst(p)), pct(s), when(rst(s))))
    break
PY
)
fi

# --- claude: undocumented OAuth usage endpoint. 180s cache is mandatory (per-token rate limit). ---
cc="$cache/claude-usage.json"
age=$(( now - $(stat -f %m "$cc" 2>/dev/null || echo 0) ))
if [ ! -s "$cc" ] || [ "$age" -ge 180 ]; then
  token=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["claudeAiOauth"]["accessToken"])' 2>/dev/null || true)
  ver=$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  if [ -n "${token:-}" ]; then
    # Header on stdin (-H @-): keeps the OAuth token out of the process table.
    if printf 'Authorization: Bearer %s\n' "$token" \
      | curl -sf --max-time 10 "https://api.anthropic.com/api/oauth/usage" \
        -H @- \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "User-Agent: claude-code/${ver:-2.1.0}" -o "$cc.tmp" 2>/dev/null; then
      mv "$cc.tmp" "$cc"
    else
      rm -f "$cc.tmp"
    fi
  fi
fi

claude_line=$(python3 - "$cc" <<'PY' 2>/dev/null
import sys, json, datetime

def when(v):
    if v is None:
        return "?"
    try:
        t = datetime.datetime.fromtimestamp(int(float(v)))
    except (TypeError, ValueError):
        try:
            t = datetime.datetime.fromisoformat(str(v).replace("Z", "+00:00")).astimezone()
        except ValueError:
            return "?"
    d = (t.date() - datetime.date.today()).days
    return t.strftime("%H:%M") + (" (+%dd)" % d if d > 0 else "")

data = json.load(open(sys.argv[1]))
fh = data.get("five_hour") or {}
sd = data.get("seven_day") or {}
parts = ["5h %s%% used (resets %s)" % (fh.get("utilization", "?"), when(fh.get("resets_at"))),
         "7d %s%% used (resets %s)" % (sd.get("utilization", "?"), when(sd.get("resets_at")))]
op = data.get("seven_day_opus")
if op:
    parts.append("7d-opus %s%%" % op.get("utilization", "?"))
print(" | ".join(parts))
PY
)

# --- grok: no official quota API in grok-build 1.0.5. Best source: the local grok-usage tool
# (wraps the undocumented cli-chat-proxy.grok.com billing endpoint; may break on CLI updates). ---
gu="$cache/grok-usage.json"
grok_line=""
if command -v grok-usage >/dev/null 2>&1; then
  age=$(( now - $(stat -f %m "$gu" 2>/dev/null || echo 0) ))
  if [ ! -s "$gu" ] || [ "$age" -ge 180 ]; then
    grok-usage --json </dev/null > "$gu.tmp" 2>/dev/null && mv "$gu.tmp" "$gu" || rm -f "$gu.tmp"
  fi
  grok_line=$(python3 - "$gu" <<'PY' 2>/dev/null
import sys, json, datetime
cfg = (json.load(open(sys.argv[1])).get("billing") or {}).get("config") or {}
pct = cfg.get("creditUsagePercent", "?")
end = (cfg.get("currentPeriod") or {}).get("end")
try:
    t = datetime.datetime.fromisoformat(str(end)).astimezone()
    d = (t.date() - datetime.date.today()).days
    reset = t.strftime("%H:%M") + (" (+%dd)" % d if d > 0 else "")
except (TypeError, ValueError):
    reset = "?"
print("weekly %s%% used (resets %s) [unofficial endpoint]" % (pct, reset))
PY
)
fi
if [ -z "${grok_line:-}" ]; then
  grok_line="no quota API — assume OK (authoritative: Grok app Settings → Usage)"
fi
codex_line="${codex_line:-unknown (probe failed)}"
claude_line="${claude_line:-unknown (no data — endpoint unreachable or token missing)}"

# Cooldowns written by consult.sh and agent-worktree.sh on a rate-limit reply.
for p in codex grok; do
  cdf="$cache/$p-cooldown"
  [ -f "$cdf" ] || continue
  t=$(cat "$cdf" 2>/dev/null || echo 0)
  case "$t" in *[!0-9]* | "") t=0 ;; esac
  if [ $(( now - t )) -lt 1800 ]; then
    note=" | rate-limited — cooling down $(( (1800 - now + t) / 60 )) more min"
    if [ "$p" = codex ]; then codex_line="$codex_line$note"; else grok_line="$grok_line$note"; fi
  else
    rm -f "$cdf"
  fi
done

printf 'codex   %s\n' "$codex_line"
printf 'claude  %s\n' "$claude_line"
printf 'grok    %s\n' "$grok_line"
