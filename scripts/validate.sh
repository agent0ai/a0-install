#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "Checking Bash syntax..."
bash -n install.sh

echo "Checking Bash help surface..."
bash install.sh --help | grep -q -- "--quick-start"
bash install.sh --help | grep -q -- "--skip-runtime-setup"

echo "Checking Bash path expansion..."
grep -Fq '${1#\~/}' install.sh
bash -c '
    input="~/agent-zero/test"
    test "$HOME/${input#\~/}" = "$HOME/agent-zero/test"
'

echo "Checking Bash menu clear handling..."
UNGUARDED_CLEAR="$(
    grep -nE '^[[:space:]]*clear([[:space:]]*(>|$))' install.sh | grep -vF '|| true' || true
)"
if [ -n "$UNGUARDED_CLEAR" ]; then
    printf '%s\n' "$UNGUARDED_CLEAR" >&2
    exit 1
fi

if command -v pwsh >/dev/null 2>&1; then
    echo "Checking PowerShell syntax..."
    pwsh -NoProfile -Command '
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            (Resolve-Path ./install.ps1),
            [ref]$tokens,
            [ref]$errors
        ) | Out-Null
        if ($errors) {
            $errors | Format-List *
            exit 1
        }
    '
elif [ "${CI:-}" = "true" ]; then
    echo "PowerShell parser check requires pwsh in CI." >&2
    exit 1
else
    echo "Skipping PowerShell parser check because pwsh is not installed."
fi

echo "Checking runtime contract..."
python3 - <<'PY'
import json
from pathlib import Path

root = Path.cwd()
contract = json.loads((root / "runtime-contract.json").read_text(encoding="utf-8"))
bash_script = (root / "install.sh").read_text(encoding="utf-8")
ps_script = (root / "install.ps1").read_text(encoding="utf-8")
readme = (root / "README.md").read_text(encoding="utf-8")

checks = [
    ("backend.imageRepository", contract["backend"]["imageRepository"], bash_script, ps_script),
    ("backend.releaseRepository", "repos/" + contract["backend"]["releaseRepository"] + "/releases", bash_script, ps_script),
    ("backend.defaultTagFallback", contract["backend"]["defaultTagFallback"], bash_script, ps_script),
    ("instance.defaultName", contract["instance"]["defaultName"], bash_script, ps_script),
    ("instance.defaultPort", str(contract["instance"]["defaultPort"]), bash_script, ps_script),
    ("instance.dataMount", contract["instance"]["dataMount"], bash_script, ps_script),
    ("instance.managedLabel", contract["instance"]["managedLabel"], bash_script, ps_script),
    ("runtime.linuxDockerPackage", contract["runtime"]["linuxDockerPackage"], bash_script, None),
    ("runtime.macosColimaProfile", contract["runtime"]["macosColimaProfile"], bash_script, None),
    ("runtime.windowsDefaultWslDistro", contract["runtime"]["windowsDefaultWslDistro"], None, ps_script),
    ("runtime.windowsWslDockerMode", "wsl.exe @wslArgs", None, ps_script),
    ("runtime.endpointSelectionPolicy", contract["runtime"]["endpointSelectionPolicy"], bash_script, ps_script, readme),
    ("runtime.endpointSources.DOCKER_HOST", "DOCKER_HOST", bash_script, ps_script, readme),
    ("runtime.endpointSources.contexts", "docker context", bash_script, ps_script, readme),
    ("runtime.endpointSources.knownLocal.bash", "try_known_docker_socket_candidates", bash_script, None, None),
    ("runtime.endpointSources.knownLocal.ps", "Use-KnownDockerEndpointCandidates", None, ps_script, None),
    ("runtime.endpointSources.knownLocal.docs", "known local", None, None, readme),
]

missing = []
for label, needle, *haystacks in checks:
    for index, haystack in enumerate(haystacks):
        if haystack is None:
            continue
        if needle not in haystack:
            target = ("install.sh", "install.ps1", "README.md")[index]
            missing.append(f"{label}: {needle!r} not found in {target}")

for needle, target, text in [
    ("--quick-start", "install.sh", bash_script),
    ("--skip-runtime-setup", "install.sh", bash_script),
    ("$QuickStart", "install.ps1", ps_script),
    ("$SkipRuntimeSetup", "install.ps1", ps_script),
]:
    if needle not in text:
        missing.append(f"flag surface: {needle!r} not found in {target}")

if missing:
    raise SystemExit("\n".join(missing))
PY

echo "Installer validation passed."
