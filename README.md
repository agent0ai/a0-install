
# a0-install

Installation scripts for Agent Zero.

These scripts install and manage **Agent Zero** as a **Docker** container (`agent0ai/agent-zero`) and can create multiple named instances on the same machine.

## Quick install (single command)

### macOS / Linux

```bash
curl -fsSL https://bash.agent-zero.ai | bash
```

### Windows (PowerShell)

```powershell
irm https://ps.agent-zero.ai | iex
```

### Docker (manual, single instance)

If you just want a single instance on port `80`:

```bash
docker run -p 80:80 agent0ai/agent-zero
```

## Run from this repository (local)

### macOS / Linux

```bash
bash ./install.sh
```

### Windows

Run in PowerShell:

```powershell
pwsh -File .\install.ps1
```

## Prerequisites

- **Docker Engine / Docker Desktop**
- **Docker Compose plugin** (`docker compose`)

Notes:

- On **macOS**, the script can open Docker Desktop for you, but you still need it installed.
- On **Linux**, `install.sh` will attempt to install Docker via `https://get.docker.com` if `docker` is not found.
- On **Windows**, `install.ps1` will not install Docker automatically; it will direct you to install Docker Desktop.

## What the installer does

Both `install.sh` and `install.ps1` implement the same flow:

- Detect existing Agent Zero containers (`agent0ai/agent-zero`).
- If none exist, start the **create instance** flow.
- If instances exist, show a menu:
  - Install new instance
  - Manage existing instances
  - Exit

### Instance creation

When you create a new instance, the installer will prompt you for:

- **Version tag** (from Docker Hub tags, defaults to `latest`)
- **Instance/container name** (default: `agent-zero`, or `agent-zero-2`, ...)
- **Data directory** (default: `~/.agentzero/<instance>/usr`)
- **Web UI port** (default: first free port starting at `5080`)
- Optional **basic auth** (username; password defaults to `12345678`)

Then it:

- Writes a per-instance `docker-compose.yml`
- Pulls the image
- Starts the container via `docker compose up -d`
- Waits for the UI to respond (tries `http://localhost:<port>`)

### Where files are stored

The installer creates a per-instance directory:

- `~/.agentzero/<instance>/docker-compose.yml`

And mounts your data directory into the container:

- Host: `~/.agentzero/<instance>/usr` (by default)
- Container: `/a0/usr`

## Managing instances

If you re-run the installer and existing instances are detected, you can manage them from the menu.

Per instance actions:

- Open in browser
- Start / Stop / Restart
- Delete (removes the Docker container)

## Uninstall

Uninstall is essentially:

1. Delete the container(s)
2. Remove the data directory (optional)

You can delete containers either through the installer menu or directly:

```bash
docker ps -a --filter "ancestor=agent0ai/agent-zero"
docker rm -f <container_name>
```

Then optionally remove the local files:

```bash
rm -rf ~/.agentzero
```

## Security note about one-liners

The one-liners (`curl ... | bash` and `irm ... | iex`) execute remote code.

If you prefer to inspect first:

- Download this repository and run `bash ./install.sh` or `pwsh -File .\install.ps1`.

## Related projects

- Agent Zero: https://github.com/agent0ai/agent-zero
