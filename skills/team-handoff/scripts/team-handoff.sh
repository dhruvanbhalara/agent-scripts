#!/usr/bin/env bash
# Start or inspect Roboclaw worktree sessions on team.openclaw.ai as Peter.
# Identity comes from Cloudflare Access (cloudflared access login) through an isolated
# OpenClaw CLI profile; see SKILL.md.
set -euo pipefail

PROFILE_DIR="${OPENCLAW_TEAM_PROFILE_DIR:-$HOME/.openclaw/profiles/team}"
CLI="${OPENCLAW_TEAM_CLI:-$HOME/.local/share/openclaw-clawstudio/run-current}"
TEAM_URL="${OPENCLAW_TEAM_URL:-https://team.openclaw.ai}"
SSH_HOST="${OPENCLAW_TEAM_SSH_HOST:-team-metal}"
REMOTE_CLI="${OPENCLAW_TEAM_REMOTE_CLI:-/usr/local/bin/openclaw}"

usage() {
  cat <<'EOF'
Usage:
  team-handoff.sh probe [--via profile|ssh]
  team-handoff.sh create --label <text> --message-file <path> [--name <worktree>] [--base <ref>]
                         [--agent roboclaw] [--project openclaw] [--via profile|ssh] [--dry-run]
  team-handoff.sh status <sessionKey> [--via profile|ssh]
  team-handoff.sh archive <sessionKey> <sessionId> [--via profile|ssh]

Env: OPENCLAW_TEAM_CLI, OPENCLAW_TEAM_PROFILE_DIR, OPENCLAW_TEAM_URL, OPENCLAW_TEAM_SSH_HOST
EOF
}

gateway_call() {
  # gateway_call <via> <method> <params-json>
  local via="$1" method="$2" params="$3"
  case "$via" in
    profile)
      [ -f "$PROFILE_DIR/openclaw.json" ] || { echo "missing profile $PROFILE_DIR/openclaw.json (see SKILL.md)" >&2; return 2; }
      [ -x "$CLI" ] || { echo "missing OpenClaw CLI at $CLI (set OPENCLAW_TEAM_CLI)" >&2; return 2; }
      OPENCLAW_STATE_DIR="$PROFILE_DIR" OPENCLAW_CONFIG_PATH="$PROFILE_DIR/openclaw.json" \
        "$CLI" gateway call "$method" --json --timeout 120000 --params "$params" 2>&1
      ;;
    ssh)
      local remote_tmp
      remote_tmp="/tmp/team-handoff-$$-$RANDOM.json"
      printf '%s' "$params" | ssh -o BatchMode=yes "$SSH_HOST" "cat > $remote_tmp && chmod a+r $remote_tmp && sudo -u openclaw -H $REMOTE_CLI gateway call $method --json --timeout 120000 --params \"\$(cat $remote_tmp)\" 2>&1; rc=\$?; rm -f $remote_tmp; exit \$rc"
      ;;
    *) echo "unknown --via $via" >&2; return 2 ;;
  esac
}

pretty_url() {
  # pretty_url <agent> <label> <sessionKey>
  python3 - "$1" "$2" "$3" "$TEAM_URL" <<'PY'
import re, sys
agent, label, key, base = sys.argv[1:5]
uuid = key.rsplit(":", 1)[-1].replace("-", "")
slug = re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", label.lower())).strip("-")
print(f"{base}/chat/{agent}/{slug}-{uuid}")
PY
}

cmd="${1:-}"; shift || true
via=profile; label=""; name=""; base="origin/main"; message_file=""; agent=roboclaw; project=openclaw; dry=0
positional=()
while [ $# -gt 0 ]; do
  case "$1" in
    --via) via="$2"; shift 2 ;;
    --label) label="$2"; shift 2 ;;
    --name) name="$2"; shift 2 ;;
    --base) base="$2"; shift 2 ;;
    --message-file) message_file="$2"; shift 2 ;;
    --agent) agent="$2"; shift 2 ;;
    --project) project="$2"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) positional+=("$1"); shift ;;
  esac
done

case "$cmd" in
  probe)
    gateway_call "$via" health '{}' | python3 -c 'import sys,json; d=json.load(sys.stdin); print("ok" if d.get("ok", True) and not d.get("error") else json.dumps(d.get("error")))'
    ;;
  create)
    [ -n "$label" ] && [ -n "$message_file" ] || { usage; exit 2; }
    [ -f "$message_file" ] || { echo "no such message file: $message_file" >&2; exit 2; }
    params="$(python3 - "$agent" "$project" "$label" "$name" "$base" "$message_file" <<'PY'
import json, sys
agent, project, label, name, base, path = sys.argv[1:7]
p = {"agentId": agent, "label": label, "message": open(path).read(), "projectId": project,
     "worktree": True, "worktreeBaseRef": base}
if name:
    p["worktreeName"] = name
print(json.dumps(p))
PY
)"
    if [ "$dry" = 1 ]; then printf '%s\n' "$params" | python3 -c 'import sys,json; d=json.load(sys.stdin); d["message"]=d["message"][:80]+"…"; print(json.dumps(d,indent=2))'; exit 0; fi
    out="$(gateway_call "$via" sessions.create "$params")" || { printf '%s\n' "$out" >&2; exit 1; }
    key="$(printf '%s' "$out" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("key","") if d.get("ok") else "")' 2>/dev/null || true)"
    if [ -z "$key" ]; then printf '%s\n' "$out" >&2; exit 1; fi
    printf 'url: %s\nkey: %s\n' "$(pretty_url "$agent" "$label" "$key")" "$key"
    printf '%s' "$out" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("runId:", d.get("runId"), "| status:", d.get("status"), "| identity:", "operator (ssh fallback)" if "'"$via"'"=="ssh" else "Peter via Access")'
    ;;
  status)
    key="${positional[0]:-}"; [ -n "$key" ] || { usage; exit 2; }
    gateway_call "$via" chat.history "$(printf '{"sessionKey":"%s","limit":3}' "$key")" | python3 -c '
import sys, json
d = json.load(sys.stdin)
if not d.get("ok", True) or d.get("error"):
    print(json.dumps(d.get("error"))); sys.exit(1)
si = d.get("sessionInfo", {})
print("status:", si.get("status"), "| worktree:", json.dumps(si.get("worktree")), "| messages:", len(d.get("messages", [])))
for m in d.get("messages", [])[-2:]:
    c = m.get("content")
    if isinstance(c, list):
        c = " ".join(x.get("text", "") for x in c if isinstance(x, dict))
    print("-", m.get("role"), ":", str(c)[:200].replace("\n", " "))'
    ;;
  archive)
    key="${positional[0]:-}"; sid="${positional[1]:-}"; [ -n "$key" ] && [ -n "$sid" ] || { usage; exit 2; }
    gateway_call "$via" sessions.patch "$(printf '{"key":"%s","expectedSessionId":"%s","archived":true}' "$key" "$sid")" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("archived" if d.get("ok") else json.dumps(d.get("error")))'
    ;;
  *) usage; exit 2 ;;
esac
