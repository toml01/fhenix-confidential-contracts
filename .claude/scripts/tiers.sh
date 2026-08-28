#!/usr/bin/env bash
# Shared tier map. Source this file; do not run it.
# tier_map <codex|grok> <scout|work|deep> sets $model and $effort.
# Codex must always get an explicit -m/-c: the user config pins sol@xhigh globally.
tier_map() {
  case "$1:$2" in
    codex:scout) model=gpt-5.6-luna  effort=low   ;;
    codex:work)  model=gpt-5.6-terra effort=high  ;;
    codex:deep)  model=gpt-5.6-sol   effort=xhigh ;;
    grok:scout)  model=grok-4.5      effort=low   ;;
    grok:work)   model=grok-4.6      effort=high  ;;
    grok:deep)   model=grok-4.6      effort=xhigh ;;
    *) echo "unknown provider:tier '$1:$2'" >&2; return 2 ;;
  esac
}
