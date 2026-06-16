
# a0-install

CLI installation scripts for Agent Zero.

These scripts install and manage **Agent Zero** as a **Docker** container (`agent0ai/agent-zero`) and can create multiple named instances on the same machine.

Use this repository when the **A0 Launcher** GUI is unavailable, undesirable, or too heavy for the environment: SSH sessions, servers, recovery shells, scripted setup, and power-user terminals.

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

## Noninteractive install

For headless or scripted environments, Quick Start can run without menus:

### macOS / Linux

```bash
bash ./install.sh --quick-start --name agent-zero --port 5080
```

### Windows PowerShell

```powershell
pwsh -File .\install.ps1 -QuickStart -Name agent-zero -Port 5080
```

Useful flags:

- `--quick-start` / `-QuickStart`: create one instance with defaults and exit.
- `--non-interactive` / `-NonInteractive`: same as Quick Start; never open menus.
- `--yes` / `-Yes`: alias for noninteractive Quick Start.
- `--name` / `-Name`: container and instance name.
- `--tag` / `-Tag`: Agent Zero image tag.
- `--port` / `-Port`: Web UI host port.
- `--data-dir` / `-DataDir`: host data directory mounted to `/a0/usr`.
- `--auth-login` / `-AuthLogin`: enable Web UI basic auth.
- `--auth-password` / `-AuthPassword`: auth password; defaults to `12345678` when a login is set.
- `--skip-runtime-setup` / `-SkipRuntimeSetup`: require an already-working Docker runtime and avoid installer-managed runtime setup.

## Prerequisites

- **Docker Engine / Docker Desktop** with a running daemon, or the platform tools needed for the installer to set one up or reuse an existing local runtime.

Notes:

- On **macOS**, the script can open Docker Desktop when it is installed. If Docker is missing, it can set up a Colima runtime with a dedicated `a0` profile and installer-owned Colima, Lima, and Docker CLI binaries. Homebrew is not required.
- On **Linux**, `install.sh` can install Docker Engine through the detected package manager. Debian/Ubuntu use `apt-get install docker.io`.
- On Linux families where the script detects `yast`, raw `rpm`, or no supported package manager, it will not guess a Docker installation path. Install Docker packages manually, then rerun the installer.
- On **Windows client editions**, `install.ps1` can reuse Docker Desktop when its Docker daemon is reachable, reuse/start Docker Engine inside an existing WSL2 distro, or guide an interactive user through setting up the local Agent Zero runtime with WSL2, Ubuntu, and Docker Engine. Windows may request UAC approval and may require a restart before setup continues; when that happens, the installer registers a one-time resume after the next Windows sign-in. When the installer uses WSL Docker Engine, it starts a lightweight WSL keepalive so Windows does not idle-stop the distro while Agent Zero containers are running. On Windows Server, where Docker Desktop is not supported, it reports the need for an existing Docker endpoint or a WSL2-backed Linux Docker Engine with nested virtualization.

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

- **Version tag** (Quick Start prefers the newest stable GitHub Release tag, including current `vX.Y` releases; manual mode also shows Docker Hub tags)
- **Instance/container name** (default: `agent-zero`, or `agent-zero-2`, ...)
- **Data directory** (default: `~/agent-zero/<instance>/usr`)
- **Web UI port** (default: first free port starting at `5080`)
- Optional **basic auth** (username; password defaults to `12345678`)

Then it:

- Pulls the image
- Starts the container directly with Docker
- Waits for the UI to respond (tries `http://localhost:<port>`)

### Where files are stored

The installer creates a per-instance directory:

- `~/agent-zero/<instance>/usr`

And mounts your data directory into the container:

- Host: `~/agent-zero/<instance>/usr` (by default)
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
rm -rf ~/agent-zero
```

## Validation

The installer keeps shared defaults and runtime assumptions in `runtime-contract.json`.

Run the lightweight validation harness before changing installer behavior:

```bash
bash ./scripts/validate.sh
```

It checks Bash syntax, PowerShell syntax when `pwsh` is available, the help surface, and the contract constants used by both scripts.

## Security note about one-liners

The one-liners (`curl ... | bash` and `irm ... | iex`) execute remote code.

If you prefer to inspect first:

- Download this repository and run `bash ./install.sh` or `pwsh -File .\install.ps1`.

## Related projects

- Agent Zero: https://github.com/agent0ai/agent-zero
