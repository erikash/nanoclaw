# NanoClaw Migration Guide

Generated: 2026-04-25
Base (merge-base with upstream/main at extract time): 22d7856
HEAD at generation: 3e06910
Upstream HEAD at generation: 8d85222 (v2.0.13)
Applied: 2026-04-25 — HEAD now 4a8423a (v2.0.13 + customizations)

This fork is migrating from v1.x → v2.x. The architecture changed
significantly upstream (modules system, channel registry, separate
`origin/channels` branch for channel adapters, no WhatsApp in trunk).
Strategy: clean checkout of upstream/main, then reapply the small set
of customizations below. WhatsApp is reinstalled fresh via the v2
`/add-whatsapp` skill, not by re-merging the v1 `whatsapp/main` remote.

## Migration Plan

Order of operations during upgrade:

1. Worktree at `upstream/main`.
2. Reapply core customizations (only diagnostics opt-out + persona).
3. SSH agent forwarding: configure via `groups/<folder>/container.json`
   plus a host-side `mount-allowlist.json` entry. **No source code
   changes** — uses v2's first-class `additionalMounts` and
   `packages.apt` config fields.
4. Run `/add-whatsapp` on the v2 base to install WhatsApp via the v2
   architecture (fetches `origin/channels`, no parallel-fork remote).
5. Validate, swap, restart.

Customizations explicitly dropped during this migration (per user
decision):
- Group-local skills feature (commit `42faad4`) — not reapplied.
- WhatsApp on-top tweaks (baileysLogger refactor, LID/JID fixes,
  `--dedicated-number` doc, senderPn fallback). These were either
  upstreamed (PR #82 fixes are in `whatsapp/main`) or no longer relevant
  on v2. Start clean on v2.
- `.env.example` seed values for `ASSISTANT_HAS_OWN_NUMBER` and
  `TELEGRAM_BOT_TOKEN` — regenerate as needed.

## Applied Skills

The v1 install merged WhatsApp from a separate fork (`whatsapp` remote).
On v2, channels live on a `channels` branch in the same repo and are
applied via instruction-only skills.

- **`add-whatsapp`** — run after upgrade to install the v2 native
  Baileys adapter. The skill fetches `origin/channels`, copies
  `src/channels/whatsapp.ts`, `setup/whatsapp-auth.ts`, `setup/groups.ts`,
  appends the self-registration import, and pins
  `@whiskeysockets/baileys@6.17.16 qrcode@1.5.4 pino@9.6.0`.

No other skill installations carry over (the user's installed skills in
`.claude/skills/` are part of the upstream baseline — instruction-only
skills, not source-modifying merges).

## Customizations

### 1. Persona "Max"

**Intent:** Assistant is named "Max", not the default "Andy".

**Files:** `groups/main/CLAUDE.md`, `groups/global/CLAUDE.md`

**How to apply:** Files under `groups/` are user data and survive the
upgrade automatically (the swap copies them through). No action needed
unless the worktree is built fresh — in which case copy these two files
from the pre-upgrade tree.

Verify after swap: `head -1 groups/main/CLAUDE.md` should print `# Max`.

### 2. Diagnostics opt-out

**Intent:** Don't send PostHog telemetry for setup or update flows.

**Files:**
- `.claude/skills/setup/diagnostics.md`
- `.claude/skills/update-nanoclaw/diagnostics.md`
- `.claude/skills/setup/SKILL.md`
- `.claude/skills/update-nanoclaw/SKILL.md`

**How to apply:**

1. Replace the entire contents of each `diagnostics.md` with a single
   line:
   ```
   # Diagnostics — opted out
   ```

2. In `.claude/skills/setup/SKILL.md`, remove the trailing
   `## 9. Diagnostics` section and the two lines under it that reference
   reading and following `diagnostics.md`.

3. In `.claude/skills/update-nanoclaw/SKILL.md`, remove the trailing
   `## Diagnostics` section and the two lines under it that reference
   reading and following `diagnostics.md`.

The exact removed blocks (for reference):

```
## 9. Diagnostics

1. Use the Read tool to read `.claude/skills/setup/diagnostics.md`.
2. Follow every step in that file before completing setup.
```

```
## Diagnostics

1. Use the Read tool to read `.claude/skills/update-nanoclaw/diagnostics.md`.
2. Follow every step in that file before finishing.
```

### 3. SSH agent forwarding (config-only — no source code change)

**Intent:** Container agents can use the host's SSH agent for git+ssh
operations without exposing private keys to the container.

**Why config-only:** v2 exposes `additionalMounts` and `packages.apt` as
first-class `container.json` fields, and the mount-security module
allowlists arbitrary host paths. The v1 source patches to
`container-runner.ts`, `types.ts`, and `Dockerfile` are no longer
needed — everything is data.

**Prerequisite (host side):** the host runs an SSH agent socket at
`/run/user/1000/nanoclaw-ssh-agent.sock` (forwarded by the existing
launchd/systemd unit on this machine). If the path differs, substitute
it in steps below.

**Files:**
- `~/.config/nanoclaw/mount-allowlist.json` (host config, outside repo)
- `~/.config/nanoclaw/agent-gitconfig` (host config, outside repo)
- `groups/<folder>/container.json` (per group that needs SSH)

**How to apply:**

1. Create the mount allowlist at `~/.config/nanoclaw/mount-allowlist.json`
   (merge with existing if present):
   ```json
   {
     "allowedRoots": [
       { "path": "/run/user/1000", "allowReadWrite": false,
         "description": "SSH agent socket forwarding" },
       { "path": "~/.config/nanoclaw", "allowReadWrite": false,
         "description": "NanoClaw host config (gitconfig, etc.)" }
     ],
     "blockedPatterns": []
   }
   ```
   Note: the module merges your `blockedPatterns` with its defaults
   (which already block `.ssh`, `id_rsa`, etc.) — leave the array empty.

2. Create the host-side gitconfig at `~/.config/nanoclaw/agent-gitconfig`
   (no `.ssh` substring in the path, so mount-security accepts it):
   ```
   [core]
       sshCommand = ssh -o IdentityAgent=/run/ssh-agent.sock -o StrictHostKeyChecking=accept-new
   ```

3. For each group that needs SSH (typically `groups/main/container.json`
   and `groups/global/container.json`), add to the JSON:
   ```json
   {
     "additionalMounts": [
       { "hostPath": "/run/user/1000/nanoclaw-ssh-agent.sock",
         "containerPath": "/run/ssh-agent.sock", "readonly": true },
       { "hostPath": "/home/erikash/.config/nanoclaw/agent-gitconfig",
         "containerPath": "/home/node/.gitconfig", "readonly": true }
     ],
     "packages": { "apt": ["openssh-client"], "npm": [] }
   }
   ```
   Use absolute host paths (mount-security resolves `~` but the runner
   stores the literal value).

4. Bake `openssh-client` into the per-group derived image. v2's
   `packages.apt` does NOT install at runtime per spawn — it triggers a
   one-time `buildAgentGroupImage()` that produces a layered image
   tagged `<base>:<agentGroupId>`. Every subsequent spawn for that group
   uses the cached layered image, so there's no per-spawn slowdown.
   The base image uses `--no-install-recommends`, so `openssh-client`
   is not pulled in transitively by `git`.

   Two ways to trigger the layered build for `openssh-client`:

   a) **Via the agent (preferred, idiomatic v2):** ask the agent inside
      a session to call `install_packages({ apt: ["openssh-client"],
      reason: "SSH agent forwarding for git+ssh" })`. Admin approves
      from the channel; the host rebuilds the image and restarts the
      container automatically. Note: this is mildly circular — the
      first run inside the container won't have ssh yet, but the
      install_packages flow only needs the agent to call the MCP tool,
      which doesn't require ssh.

   b) **One-off script after group registration:** add the package to
      `container.json` as shown in step 3, then run:
      ```bash
      bun -e "import { buildAgentGroupImage } from './src/container-runner.js'; \
        await buildAgentGroupImage('<agent-group-id>');"
      ```
      `<agent-group-id>` is in `groups/<folder>/container.json` under
      `agentGroupId`, or queryable via the SQLite store.

   Either path produces the same outcome: a derived image with
   `openssh-client` baked in, used for every future spawn of that
   group. No core Dockerfile change required.

**Coverage:**
- **git over ssh** works automatically — git reads `core.sshCommand`
  from the mounted `~/.gitconfig`.
- **raw `ssh` invocations** (e.g. health checks) require passing the
  IdentityAgent flag explicitly, because v2 has no hook for setting
  `SSH_AUTH_SOCK` in the container without a source change. Use:
  ```bash
  ssh -o IdentityAgent=/run/ssh-agent.sock target echo ok
  ```
  Bake this into health-check scripts / runbooks. Optionally wrap as
  an alias in a per-group CLAUDE.md fragment so the agent picks the
  flag up by convention.

If full `SSH_AUTH_SOCK` coverage (no per-invocation flag) becomes
necessary later, the v2-spirit fix is to add a
`registerContainerContribution()` hook upstream (provider-agnostic
mirror of the existing provider container registry) and ship SSH
forwarding as a real module. Out of scope for this migration.

## Skill Interactions

None. The customizations don't share files with each other.

## Verification

After the upgrade:

1. `npm run build` exits 0.
2. `head -1 groups/main/CLAUDE.md` prints `# Max`.
3. `cat .claude/skills/setup/diagnostics.md` prints
   `# Diagnostics — opted out`.
4. WhatsApp connects after running `/add-whatsapp` and authenticating.
5. From inside a container: `ssh -T git@github.com` authenticates via
   the forwarded agent (or `git fetch` against an SSH remote works).
