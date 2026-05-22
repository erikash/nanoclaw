---
name: moneyman
description: Trigger moneyman financial scrapers via SSH and report results
allowed-tools: Bash
---

# Moneyman Financial Scraper

Triggers financial scraping jobs on the moneyman server via SSH.

## Usage

```bash
# All targets
bash /app/skills/moneyman/scrape.sh

# Specific target(s)
bash /app/skills/moneyman/scrape.sh household.isracard.erik
bash /app/skills/moneyman/scrape.sh freelancing household
```

## Targets

| Target | Description | Reliable? |
|--------|-------------|-----------|
| `freelancing` | Freelancing accounts | Yes |
| `household` | Household accounts (non-isracard) | Yes |
| `household.isracard.erik` | Erik's Isracard | Flaky — retries automatically |
| `household.isracard.sonya` | Sonya's Isracard | Flaky — retries automatically |

`household` excludes isracard. The isracard targets are separated so they can be retried individually.

## Output Format

The script outputs a `---MONEYMAN_RESULTS---` marker followed by JSON with per-target status and output, then `ALL_OK` or `SOME_FAILED`.

## Reporting

After running the script, send a WhatsApp message summarizing:
- Which scrapers succeeded
- Which failed (include retry count and error snippet)
- Keep it concise — one line per target

## Schedule

Runs daily at 6 AM Israel time via cron (`0 6 * * *`).

## Architecture

### SSH Access

Containers don't have SSH keys. Instead, the host runs a dedicated SSH agent (`nanoclaw-ssh-agent.service`, systemd user service) with the `~/.ssh/moneyman-trigger` key loaded. The agent socket at `/run/user/1000/nanoclaw-ssh-agent.sock` is mounted into the container via `additionalMounts` in `container.json` and is available at `/workspace/extra/ssh-agent.sock`.

The private key never enters the container — the container's `ssh` command talks to the host agent for signing.

### Files

| File | Purpose |
|------|---------|
| `scrape.sh` | Main script — runs all 4 targets, retries isracard 3x with exponential backoff (30s, 60s, 120s) |
| `ssh_config` | Minimal SSH config mapping `moneyman-trigger` to `erikash@10.22.10.31` |
| `known_hosts` | Pre-scanned host keys for 10.22.10.31 |
| `SKILL.md` | This file |

### Host-Side Dependencies

| Component | Location |
|-----------|----------|
| SSH agent service | `~/.config/systemd/user/nanoclaw-ssh-agent.service` |
| SSH key | `~/.ssh/moneyman-trigger` |
| Agent socket | `/run/user/1000/nanoclaw-ssh-agent.sock` |
| Moneyman host | `10.22.10.31` (internal network) |

### Code Changes (NanoClaw core)

- `src/types.ts` — `ContainerConfig.sshAgentForward?: boolean`
- `src/container-runner.ts` — mounts agent socket + sets `SSH_AUTH_SOCK` when flag is true
- `container/Dockerfile` — `openssh-client` in apt-get install

### Retry Logic

Isracard targets (`household.isracard.erik`, `household.isracard.sonya`) are blocked by anti-automation measures intermittently. `scrape.sh` retries these up to 3 times with exponential backoff: 30s → 60s → 120s. Other targets run once. Worst case total runtime is ~7 minutes.
