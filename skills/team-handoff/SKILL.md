---
name: team-handoff
description: "Hand local work to team.openclaw.ai: start a Roboclaw worktree session as Peter in one Gateway request, seeded with a handoff, and get the pretty session URL back."
---

# Team Handoff

Use this when the job is any of:

- "open a session on Team / team.openclaw.ai for this"
- "hand this off to Roboclaw" / "pass this to the team server"
- "summarize this for a new agent and start it on Team"

One request. Identity is Peter's, via Cloudflare Access. No browser, no SSH, no polling.

Script: `scripts/team-handoff.sh`

## How it works

team.openclaw.ai is a Gateway behind Cloudflare Access with `gateway.auth.mode: "trusted-proxy"`.
Access decides who you are (`cf-access-authenticated-user-email`); the Gateway maps that email to
scopes. There is no bearer "operator token" to mint: the credential is a short-lived Access user
token that `cloudflared` caches after one browser login, and the CLI sends it on the WebSocket
upgrade through `gateway.remote.edgeAuth`.

The script runs the installed OpenClaw CLI against an isolated profile so the local Gateway
config is never touched:

- profile: `~/.openclaw/profiles/team/openclaw.json` (`OPENCLAW_CONFIG_PATH`), state dir
  `~/.openclaw/profiles/team` (`OPENCLAW_STATE_DIR`) — holds only `gateway.mode: "remote"`,
  `gateway.remote.url: "wss://team.openclaw.ai"`, and an `exec` secret provider that runs
  `cloudflared access token -app=https://team.openclaw.ai` for the `Cf-Access-Token` header.
  The provider `command` must be the real binary (symlinks are refused):
  `/opt/homebrew/Cellar/cloudflared/<version>/bin/cloudflared`; update it after `brew upgrade`.
- CLI: `~/.local/share/openclaw-clawstudio/run-current` (the clawstudio-managed install), override
  with `OPENCLAW_TEAM_CLI`. Do not use `pnpm openclaw` from a source worktree for this: its
  runtime-artifact publication guard fires against the local LaunchAgent Gateway.
- first connection pairs a `cli` device for Peter; trusted-proxy `deviceAutoApprove` grants
  `operator.read/write/approvals/questions`, which is what `sessions.create` needs.

## One-time prerequisite (Peter, in a browser)

```bash
cloudflared access login https://team.openclaw.ai
```

Agents cannot do this step. When the Access token lapses the script fails with
`Exec provider "cloudflare-access" exited with code 1` (or the Gateway answers HTTP 302):
ask Peter to run the login again; do not fall back to SSH silently.

## Quick start

```bash
# health probe (proves Access login + profile)
bash scripts/team-handoff.sh probe

# start a worktree session seeded with a handoff file
bash scripts/team-handoff.sh create \
  --label "Installed-package entry cap durable fix" \
  --name tree-cap-fix \
  --base origin/main \
  --message-file /path/to/handoff.md

# one status read (no polling)
bash scripts/team-handoff.sh status agent:roboclaw:dashboard:<uuid>
```

`create` prints the pretty URL in the form
`https://team.openclaw.ai/chat/<agent>/<label-slug>-<uuid-without-dashes>` (the UUID is the
session key's, not `sessionId`), plus the session key and run id. Give Peter that URL, never the
`/chat?session=` form.

Defaults: `--agent roboclaw`, `--project openclaw` (the Team project catalog id; `projects.list`
shows others), `--base origin/main`. `--name` becomes branch `openclaw/<name>`.

## Payload shape

- Put the work on a branch first. Push it, pass `--base <branch>`, and keep the long handoff in
  the branch (for example `.openclaw/handoff.md`). The message then needs three lines: what the
  branch is, what to do first, what not to do. Artifacts on the local Mac are unreachable from
  Team; commit them or summarize the numbers.
- When there is no branch, the whole handoff goes in `--message-file`. Start it with a one-line
  title (it becomes the session title and the URL slug), then goal, verified facts with numbers,
  owners/files, the plan with the agreed order, proof expectations, and what the agent must not do.
- State scope boundaries explicitly when a local session keeps part of the work, so two agents
  do not open duplicate PRs.

## Known failure modes

- `managed worktree allocation lease core:managed-worktrees:create/capacity was lost`: Team's
  worktree preparation lost its ~60 s capacity lease during a slow project refetch/repack
  (recurring; fix tracked in openclaw/openclaw, branch `steipete/worktree-capacity-lease-custody`).
  Retrying in the same session fails with `branch already exists: openclaw/<name>` because the
  failed attempt leaks its branch. Create a new session with a different `--name`; archive the
  dead one with `sessions.patch` (`key`, `expectedSessionId`, `archived: true`).
- `chat.send` requires `idempotencyKey`.
- Session creation returns before the worktree is prepared; the agent's first turn starts after
  binding. A `status` read showing `running` with `worktree: null` right after create is normal.

## Fallback: SSH as the Gateway operator

Only when Access login is impossible and Peter says so. `--via ssh` runs the same
`sessions.create` on `team-metal` as the `openclaw` user (`sudo -u openclaw -H
/usr/local/bin/openclaw gateway call …`). The session is then owned by the Gateway operator
identity, not Peter. Never change Team config or restart anything from this path; Team updates
belong to Night Watch (`$team-server-updater`).

## Don'ts

- Do not open team.openclaw.ai in the agent browser or sign in to OpenClaw ID.
- Do not point the local `~/.openclaw/openclaw.json` at Team; the profile exists so that never happens.
- Do not poll `chat.history` in a loop; read once and hand Peter the URL.
