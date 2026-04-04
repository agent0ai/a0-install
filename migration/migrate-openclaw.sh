#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# migrate-openclaw.sh — Migrate an OpenClaw installation to Agent Zero
# ──────────────────────────────────────────────────────────────────────
#
# Usage:
#   ./migrate-openclaw.sh [--include-auth-profiles] [OPENCLAW_DIR] [A0_USR_DIR]
#
# Defaults:
#   OPENCLAW_DIR = ~/.openclaw
#   A0_USR_DIR   = /a0/usr
#
# What it migrates:
#   1. API keys (.env, config env refs, optional auth-profiles scan)
#   2. Agent Zero profiles generated from OpenClaw agents
#   3. Promptinclude files into a real Agent Zero workdir tree
#   4. Telegram bot config in the current Agent Zero plugin schema
#   5. Memory files into searchable knowledge roots
#   6. Skills with agent/global scope preserved
#
# Notes:
#   - Agent Zero profiles are not equivalent to OpenClaw isolated agents.
#   - Promptinclude files are written to usr/workdir/openclaw-migration/<agent-id>/.
#     To load them automatically, point Agent Zero workdir or project there.
#
# Requirements:
#   - Python 3.8+
#   - Optional JSON5 parser: python `json5` module or node `json5` package
#
# ──────────────────────────────────────────────────────────────────────
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}ℹ${NC}  $*"; }
success() { echo -e "${GREEN}✓${NC}  $*"; }
warn()    { echo -e "${YELLOW}⚠${NC}  $*"; }
error()   { echo -e "${RED}✗${NC}  $*"; }
header()  { echo -e "\n${BOLD}═══ $* ═══${NC}"; }

usage() {
    cat <<'EOF'
Usage:
  ./migrate-openclaw.sh [--include-auth-profiles] [OPENCLAW_DIR] [A0_USR_DIR]

Options:
  --include-auth-profiles   Attempt to extract API-key-style secrets from auth-profiles.json
  -h, --help                Show this help text
EOF
}

MIGRATED=0
SKIPPED=0
WARNINGS=0
REPORT_INITIALIZED=0

report_line() {
    if [[ "${REPORT_INITIALIZED}" == "1" ]]; then
        printf '%s\n' "$*" >> "${MIGRATION_REPORT}"
    fi
}

log_migrated() {
    MIGRATED=$((MIGRATED + 1))
    success "$*"
    report_line "- Migrated: $*"
}

log_skipped() {
    SKIPPED=$((SKIPPED + 1))
    info "Skipped: $*"
    report_line "- Skipped: $*"
}

log_warning() {
    WARNINGS=$((WARNINGS + 1))
    warn "$*"
    report_line "- Warning: $*"
}

INCLUDE_AUTH_PROFILES=0
POSITIONAL_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --include-auth-profiles)
            INCLUDE_AUTH_PROFILES=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            POSITIONAL_ARGS+=("$1")
            shift
            ;;
    esac
done

OPENCLAW_DIR="${POSITIONAL_ARGS[0]:-$HOME/.openclaw}"
A0_USR_DIR="${POSITIONAL_ARGS[1]:-/a0/usr}"

OPENCLAW_DIR="${OPENCLAW_DIR/#\~/$HOME}"
A0_USR_DIR="${A0_USR_DIR/#\~/$HOME}"

OPENCLAW_CONFIG="${OPENCLAW_DIR}/openclaw.json"
OPENCLAW_ENV="${OPENCLAW_DIR}/.env"
OPENCLAW_AUTH_PROFILES="${OPENCLAW_DIR}/auth-profiles.json"
A0_ENV="${A0_USR_DIR}/.env"
MIGRATION_LOG="${A0_USR_DIR}/openclaw-migration.log"
MIGRATION_REPORT="${A0_USR_DIR}/openclaw-migration-report.md"
MIGRATION_WORKDIR_ROOT="${A0_USR_DIR}/workdir/openclaw-migration"
KNOWLEDGE_DIR="${A0_USR_DIR}/knowledge/custom/openclaw"
MEMORY_KNOWLEDGE_DIR="${A0_USR_DIR}/knowledge/custom/openclaw-memory"

KNOWN_ENV_KEYS=(
    "OPENAI_API_KEY"
    "ANTHROPIC_API_KEY"
    "GEMINI_API_KEY"
    "GOOGLE_API_KEY"
    "OPENROUTER_API_KEY"
    "GROQ_API_KEY"
    "MISTRAL_API_KEY"
    "DEEPSEEK_API_KEY"
    "TOGETHER_API_KEY"
    "PERPLEXITY_API_KEY"
    "XAI_API_KEY"
    "CEREBRAS_API_KEY"
    "SAMBANOVA_API_KEY"
)

sanitize_agent_id() {
    local value="$1"
    value="$(printf '%s' "${value}" | tr -cs 'A-Za-z0-9._-' '-')"
    value="${value#-}"
    value="${value%-}"
    if [[ -z "${value}" ]]; then
        value="agent"
    fi
    printf '%s' "${value}"
}

map_env_key() {
    case "$1" in
        OPENAI_API_KEY) printf '%s' "API_KEY_OPENAI" ;;
        ANTHROPIC_API_KEY) printf '%s' "API_KEY_ANTHROPIC" ;;
        GEMINI_API_KEY|GOOGLE_API_KEY) printf '%s' "API_KEY_GOOGLE" ;;
        OPENROUTER_API_KEY) printf '%s' "API_KEY_OPENROUTER" ;;
        GROQ_API_KEY) printf '%s' "API_KEY_GROQ" ;;
        MISTRAL_API_KEY) printf '%s' "API_KEY_MISTRAL" ;;
        DEEPSEEK_API_KEY) printf '%s' "API_KEY_DEEPSEEK" ;;
        TOGETHER_API_KEY) printf '%s' "API_KEY_TOGETHER" ;;
        PERPLEXITY_API_KEY) printf '%s' "API_KEY_PERPLEXITYAI" ;;
        XAI_API_KEY) printf '%s' "API_KEY_XAI" ;;
        CEREBRAS_API_KEY) printf '%s' "API_KEY_CEREBRAS" ;;
        SAMBANOVA_API_KEY) printf '%s' "API_KEY_SAMBANOVA" ;;
        *) return 1 ;;
    esac
}

known_env_keys_csv() {
    local IFS=","
    printf '%s' "${KNOWN_ENV_KEYS[*]}"
}

array_contains() {
    local needle="$1"
    shift
    local item
    for item in "$@"; do
        [[ "${item}" == "${needle}" ]] && return 0
    done
    return 1
}

write_json_file() {
    local path="$1"
    local payload="$2"
    PAYLOAD_JSON="${payload}" python3 - "${path}" <<'PY'
import json
import os
import pathlib
import sys

target = pathlib.Path(sys.argv[1])
target.parent.mkdir(parents=True, exist_ok=True)
payload = json.loads(os.environ.get("PAYLOAD_JSON", "{}"))
target.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
}

write_agent_manifest() {
    local path="$1"
    local title="$2"
    local description="$3"
    python3 - "${path}" "${title}" "${description}" <<'PY'
import json
import pathlib
import sys

target = pathlib.Path(sys.argv[1])
target.parent.mkdir(parents=True, exist_ok=True)
payload = {
    "title": sys.argv[2],
    "description": sys.argv[3],
}
target.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
}

first_meaningful_line() {
    local file="$1"
    python3 - "${file}" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
if not path.is_file():
    sys.exit(0)
for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
    stripped = re.sub(r"^#+\s*", "", line).strip()
    if stripped:
        print(stripped)
        break
PY
}

ensure_env_key() {
    local source_key="$1"
    local value="$2"
    local source_label="$3"
    local target_key=""

    if ! target_key="$(map_env_key "${source_key}" 2>/dev/null)"; then
        return 0
    fi

    if [[ -z "${target_key}" || -z "${value}" ]]; then
        return 0
    fi

    if grep -q "^${target_key}=" "${A0_ENV}" 2>/dev/null; then
        log_skipped "${target_key} already set in ${A0_ENV}"
        return 0
    fi

    printf '%s=%s\n' "${target_key}" "${value}" >> "${A0_ENV}"
    log_migrated "${source_key} → ${target_key} (${source_label})"
}

extract_known_env_keys_from_json() {
    local json_file="$1"
    python3 - "${json_file}" "$(known_env_keys_csv)" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
candidates = {item for item in sys.argv[2].split(",") if item}
if not path.is_file():
    sys.exit(0)

data = json.loads(path.read_text(encoding="utf-8"))
seen = set()

def walk(node):
    if isinstance(node, dict):
        for key, value in node.items():
            if key in candidates and isinstance(value, str) and value:
                pair = (key, value)
                if pair not in seen:
                    seen.add(pair)
                    print(f"{key}\t{value}")
            walk(value)
    elif isinstance(node, list):
        for item in node:
            walk(item)

walk(data)
PY
}

parse_config_strict() {
    python3 - "${OPENCLAW_CONFIG}" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
json.dump(data, sys.stdout)
PY
}

parse_config_python_json5() {
    python3 - "${OPENCLAW_CONFIG}" <<'PY'
import json
import pathlib
import sys

import json5  # type: ignore

path = pathlib.Path(sys.argv[1])
data = json5.loads(path.read_text(encoding="utf-8"))
json.dump(data, sys.stdout)
PY
}

parse_config_node_json5() {
    node - "${OPENCLAW_CONFIG}" <<'NODE'
const fs = require("fs");
const JSON5 = require("json5");

const filePath = process.argv[2];
const raw = fs.readFileSync(filePath, "utf8");
const parsed = JSON5.parse(raw);
process.stdout.write(JSON.stringify(parsed));
NODE
}

config_env_refs() {
    python3 - "${OPENCLAW_CONFIG}" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
if not path.is_file():
    sys.exit(0)

raw = path.read_text(encoding="utf-8", errors="replace")
for name in sorted(set(re.findall(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", raw))):
    print(name)
PY
}

jval() {
    local path="$1"
    local default="${2:-}"
    CONFIG_JSON_INPUT="${CONFIG_JSON}" python3 - "${path}" "${default}" <<'PY'
import json
import os
import sys

path = sys.argv[1].strip(".")
default = sys.argv[2]
raw = os.environ.get("CONFIG_JSON_INPUT", "{}").strip() or "{}"
config = json.loads(raw)
value = config

for key in [part for part in path.split(".") if part]:
    if isinstance(value, dict):
        value = value.get(key)
    elif isinstance(value, list) and key.isdigit():
        index = int(key)
        value = value[index] if index < len(value) else None
    else:
        value = None
    if value is None:
        break

if value is None:
    sys.stdout.write(default)
elif isinstance(value, (dict, list)):
    json.dump(value, sys.stdout)
else:
    sys.stdout.write(str(value))
PY
}

copy_dir_with_collision_handling() {
    local source_dir="$1"
    local target_dir="$2"
    local label="$3"

    if [[ ! -d "${target_dir}" ]]; then
        mkdir -p "$(dirname "${target_dir}")"
        cp -R "${source_dir}" "${target_dir}"
        log_migrated "${label}"
        return 0
    fi

    if diff -qr "${source_dir}" "${target_dir}" >/dev/null 2>&1; then
        log_skipped "${label} already exists with identical contents"
    else
        log_warning "${label} already exists with different contents: ${target_dir}"
    fi
}

build_telegram_payload() {
    CONFIG_JSON_INPUT="${CONFIG_JSON}" python3 - "${OPENCLAW_ENV}" <<'PY'
import json
import os
import pathlib
import sys

env_path = pathlib.Path(sys.argv[1])
config = json.loads(os.environ.get("CONFIG_JSON_INPUT", "{}") or "{}")
telegram = (((config.get("channels") or {}).get("telegram")) or {})

env_values = {}
if env_path.is_file():
    for raw_line in env_path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        env_values[key.strip()] = value.strip().strip('"').strip("'")

def normalize_allowed_users(raw):
    if not isinstance(raw, list):
        return []
    result = []
    for item in raw:
        value = str(item).replace("telegram:", "").replace("tg:", "").strip()
        if value and value != "*" and value not in result:
            result.append(value)
    return result

def normalize_group_mode(raw_groups):
    if raw_groups is False:
        return "off"
    if not isinstance(raw_groups, dict) or not raw_groups:
        return "mention"
    for key in ["*", *raw_groups.keys()]:
        value = raw_groups.get(key)
        if not isinstance(value, dict):
            continue
        if value.get("enabled") is False:
            return "off"
        if value.get("requireMention") is False:
            return "all"
        if value.get("requireMention") is True:
            return "mention"
    return "mention"

def webhook_fields(raw):
    if not isinstance(raw, dict):
        return ("polling", "", "")
    enabled = raw.get("enabled")
    if enabled is False:
        return ("polling", "", "")
    url = raw.get("url") or raw.get("webhookUrl") or raw.get("baseUrl") or ""
    secret = raw.get("secret") or raw.get("webhookSecret") or ""
    if url:
        return ("webhook", str(url), str(secret))
    return ("polling", "", "")

def build_bot(name, source):
    if not isinstance(source, dict):
        return None, [f"telegram account '{name}' is not an object; skipped"]
    token = source.get("botToken") or telegram.get("botToken") or env_values.get("TELEGRAM_BOT_TOKEN", "")
    warnings = []
    if not token or "${" in str(token):
        warnings.append(f"telegram account '{name}' has no concrete bot token; skipped")
        return None, warnings
    mode, webhook_url, webhook_secret = webhook_fields(source.get("webhook") or telegram.get("webhook"))
    bot = {
        "name": name,
        "enabled": True,
        "token": str(token),
        "mode": mode,
        "webhook_url": webhook_url,
        "webhook_secret": webhook_secret,
        "allowed_users": normalize_allowed_users(source.get("allowFrom", telegram.get("allowFrom", []))),
        "group_mode": normalize_group_mode(source.get("groups", telegram.get("groups", {}))),
    }
    return bot, warnings

bots = []
warnings = []
notes = []

accounts = telegram.get("accounts")
if isinstance(accounts, dict) and accounts:
    for account_name, account_cfg in accounts.items():
        bot, bot_warnings = build_bot(str(account_name), account_cfg)
        warnings.extend(bot_warnings)
        if bot:
            bots.append(bot)
else:
    bot, bot_warnings = build_bot("default", telegram if isinstance(telegram, dict) else {})
    warnings.extend(bot_warnings)
    if bot:
        bots.append(bot)

dm_policy = telegram.get("dmPolicy")
if dm_policy:
    notes.append(f"OpenClaw dmPolicy was '{dm_policy}' and was not mapped directly.")

if telegram.get("bindings"):
    notes.append("OpenClaw Telegram bindings were not migrated; review channel routing manually.")

if telegram.get("pairing"):
    notes.append("OpenClaw Telegram pairing behavior was not migrated.")

payload = {
    "bots": bots,
    "warnings": warnings,
    "notes": notes,
}
json.dump(payload, sys.stdout)
PY
}

header "OpenClaw → Agent Zero Migration"
echo
info "OpenClaw dir : ${OPENCLAW_DIR}"
info "Agent Zero   : ${A0_USR_DIR}"
echo

if [[ ! -d "${OPENCLAW_DIR}" ]]; then
    error "OpenClaw directory not found: ${OPENCLAW_DIR}"
    error "Usage: $0 [--include-auth-profiles] [OPENCLAW_DIR] [A0_USR_DIR]"
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    error "Python 3 is required but not found."
    exit 1
fi

mkdir -p "${A0_USR_DIR}"
touch "${A0_ENV}"

cat > "${MIGRATION_REPORT}" <<EOF
# OpenClaw → Agent Zero Migration Report

- Date: $(date -Iseconds)
- Source: ${OPENCLAW_DIR}
- Target: ${A0_USR_DIR}
- Promptinclude workdir root: ${MIGRATION_WORKDIR_ROOT}

## Notes

- Agent Zero profiles are generated from OpenClaw agents, but they do not preserve OpenClaw's full auth/session/channel isolation model.
- Promptinclude files are written to a generated workdir tree. Agent Zero loads them only when the active workdir or project points there.

## Actions

EOF
REPORT_INITIALIZED=1

CONFIG_JSON="{}"
CONFIG_PARSE_MODE="not-used"

if [[ -f "${OPENCLAW_CONFIG}" ]]; then
    if CONFIG_JSON="$(parse_config_strict 2>/dev/null)"; then
        CONFIG_PARSE_MODE="python-json"
        success "Parsed openclaw.json with strict JSON parser"
        report_line "- Config parser: ${CONFIG_PARSE_MODE}"
    elif python3 -c "import json5" >/dev/null 2>&1; then
        CONFIG_JSON="$(parse_config_python_json5)"
        CONFIG_PARSE_MODE="python-json5"
        success "Parsed openclaw.json with Python json5 parser"
        report_line "- Config parser: ${CONFIG_PARSE_MODE}"
    elif command -v node >/dev/null 2>&1 && node -e "require('json5')" >/dev/null 2>&1; then
        CONFIG_JSON="$(parse_config_node_json5)"
        CONFIG_PARSE_MODE="node-json5"
        success "Parsed openclaw.json with Node json5 parser"
        report_line "- Config parser: ${CONFIG_PARSE_MODE}"
    else
        error "Could not parse ${OPENCLAW_CONFIG}."
        error "The file appears to require JSON5 support, but no JSON5-capable parser is available."
        error "Install python package 'json5' or a Node runtime with the 'json5' package, then rerun."
        exit 1
    fi
else
    warn "No openclaw.json found at ${OPENCLAW_CONFIG}"
    warn "Will still attempt to migrate workspace files and .env"
    report_line "- Config parser: config file missing"
fi

header "Step 1: API Keys"

if [[ -f "${OPENCLAW_ENV}" ]]; then
    info "Reading ${OPENCLAW_ENV}"
    while IFS='=' read -r key value || [[ -n "${key}" ]]; do
        [[ -z "${key}" || "${key}" =~ ^# ]] && continue
        value="${value%\"}"
        value="${value#\"}"
        value="${value%\'}"
        value="${value#\'}"
        ensure_env_key "${key}" "${value}" ".env"
    done < "${OPENCLAW_ENV}"
else
    log_skipped "No .env file found at ${OPENCLAW_ENV}"
fi

if [[ -f "${OPENCLAW_CONFIG}" ]]; then
    while IFS= read -r ref_name; do
        [[ -z "${ref_name}" ]] && continue
        target_key="$(map_env_key "${ref_name}" 2>/dev/null || true)"
        if [[ -n "${target_key}" ]]; then
            if [[ -n "${!ref_name-}" ]]; then
                ensure_env_key "${ref_name}" "${!ref_name}" "shell environment (referenced by openclaw.json)"
            elif grep -q "^${ref_name}=" "${OPENCLAW_ENV}" 2>/dev/null; then
                :
            else
                log_warning "Config references ${ref_name}; set ${target_key} manually if needed"
            fi
        fi
    done < <(config_env_refs)
fi

if [[ "${INCLUDE_AUTH_PROFILES}" == "1" ]]; then
    if [[ -f "${OPENCLAW_AUTH_PROFILES}" ]]; then
        while IFS=$'\t' read -r key value; do
            [[ -z "${key}" || -z "${value}" ]] && continue
            ensure_env_key "${key}" "${value}" "auth-profiles.json"
        done < <(extract_known_env_keys_from_json "${OPENCLAW_AUTH_PROFILES}")
    else
        log_skipped "No auth-profiles.json found at ${OPENCLAW_AUTH_PROFILES}"
    fi
else
    log_skipped "auth-profiles.json scan disabled (use --include-auth-profiles to enable)"
fi

header "Step 2: Discover Agents"

AGENTS_JSON="$(jval '.agents.list' '[]')"
DEFAULT_WORKSPACE="$(jval '.agents.defaults.workspace' "${OPENCLAW_DIR}/workspace")"
DEFAULT_WORKSPACE="${DEFAULT_WORKSPACE/#\~/$HOME}"

declare -a AGENT_IDS=()
declare -a AGENT_NAMES=()
declare -a AGENT_WORKSPACES=()
declare -a AGENT_PROFILE_IDS=()

if [[ "${AGENTS_JSON}" != "[]" && "${AGENTS_JSON}" != "" ]]; then
    while IFS=$'\t' read -r raw_id raw_name raw_ws; do
        [[ -z "${raw_id}" ]] && continue
        AGENT_IDS+=("${raw_id}")
        AGENT_NAMES+=("${raw_name}")
        AGENT_WORKSPACES+=("${raw_ws}")
    done < <(AGENTS_JSON_INPUT="${AGENTS_JSON}" python3 - <<'PY'
import json
import os
import sys

agents = json.loads(os.environ.get("AGENTS_JSON_INPUT", "[]") or "[]")
if not isinstance(agents, list):
    agents = []

for index, agent in enumerate(agents):
    if not isinstance(agent, dict):
        continue
    aid = str(agent.get("id") or f"agent{index}")
    name = str(agent.get("name") or aid)
    workspace = str(agent.get("workspace") or "")
    aid = aid.replace("\t", " ")
    name = name.replace("\t", " ")
    workspace = workspace.replace("\t", " ")
    print(f"{aid}\t{name}\t{workspace}")
PY
)
fi

if [[ ${#AGENT_IDS[@]} -eq 0 ]]; then
    AGENT_IDS=("main")
    AGENT_NAMES=("Main")
    AGENT_WORKSPACES=("")
fi

declare -a USED_PROFILE_IDS=()

for i in "${!AGENT_IDS[@]}"; do
    aid="${AGENT_IDS[$i]}"
    ws="${AGENT_WORKSPACES[$i]}"
    if [[ -z "${ws}" ]]; then
        if [[ -d "${OPENCLAW_DIR}/workspace-${aid}" ]]; then
            ws="${OPENCLAW_DIR}/workspace-${aid}"
        elif [[ -d "${DEFAULT_WORKSPACE}" ]]; then
            ws="${DEFAULT_WORKSPACE}"
        else
            ws="${OPENCLAW_DIR}/workspace"
        fi
    else
        ws="${ws/#\~/$HOME}"
    fi
    AGENT_WORKSPACES[$i]="${ws}"

    base_profile_id="$(sanitize_agent_id "${aid}")"
    profile_id="${base_profile_id}"
    suffix=2
    while array_contains "${profile_id}" "${USED_PROFILE_IDS[@]-}"; do
        profile_id="${base_profile_id}-${suffix}"
        suffix=$((suffix + 1))
    done
    USED_PROFILE_IDS+=("${profile_id}")
    AGENT_PROFILE_IDS[$i]="${profile_id}"
done

info "Found ${#AGENT_IDS[@]} agent(s):"
for i in "${!AGENT_IDS[@]}"; do
    aid="${AGENT_IDS[$i]}"
    ws="${AGENT_WORKSPACES[$i]}"
    profile_id="${AGENT_PROFILE_IDS[$i]}"
    name="${AGENT_NAMES[$i]}"
    if [[ -d "${ws}" ]]; then
        echo "   • ${aid} (${name}) → ${ws} [profile: ${profile_id}] ✓"
    else
        echo "   • ${aid} (${name}) → ${ws} [profile: ${profile_id}] ✗ (not found)"
    fi
done

header "Step 3: Agent Profiles and Prompt Content"

for i in "${!AGENT_IDS[@]}"; do
    aid="${AGENT_IDS[$i]}"
    ws="${AGENT_WORKSPACES[$i]}"
    name="${AGENT_NAMES[$i]}"
    profile_id="${AGENT_PROFILE_IDS[$i]}"

    if [[ ! -d "${ws}" ]]; then
        log_warning "Workspace not found for agent '${aid}': ${ws}"
        continue
    fi

    AGENT_DIR="${A0_USR_DIR}/agents/${profile_id}"
    PROMPTS_DIR="${AGENT_DIR}/prompts"
    AGENT_SKILLS_DIR="${AGENT_DIR}/skills"
    AGENT_WORKDIR="${MIGRATION_WORKDIR_ROOT}/${profile_id}"
    mkdir -p "${PROMPTS_DIR}" "${AGENT_SKILLS_DIR}" "${AGENT_WORKDIR}"

    info "Migrating OpenClaw agent '${aid}' into Agent Zero profile '${profile_id}'"

    desc="Generated from OpenClaw agent '${aid}'"
    if [[ -f "${ws}/IDENTITY.md" ]]; then
        first_line="$(first_meaningful_line "${ws}/IDENTITY.md" || true)"
        [[ -n "${first_line}" ]] && desc="${first_line}"
    fi

    if [[ ! -f "${AGENT_DIR}/agent.json" ]]; then
        write_agent_manifest "${AGENT_DIR}/agent.json" "${name}" "${desc}"
        log_migrated "agent.json for profile '${profile_id}'"
    else
        log_skipped "agent.json already exists for profile '${profile_id}'"
    fi

    role_target="${PROMPTS_DIR}/agent.system.main.role.md"
    if [[ -f "${ws}/SOUL.md" ]]; then
        if [[ ! -f "${role_target}" ]]; then
            {
                echo "# Agent Role"
                echo
                echo "> Migrated from OpenClaw SOUL.md."
                echo
                cat "${ws}/SOUL.md"
            } > "${role_target}"
            log_migrated "SOUL.md → agent.system.main.role.md (profile '${profile_id}')"
        else
            log_skipped "agent.system.main.role.md already exists for profile '${profile_id}'"
        fi
    fi

    promptinclude_created=0

    if [[ -f "${ws}/IDENTITY.md" ]]; then
        target="${AGENT_WORKDIR}/identity.promptinclude.md"
        if [[ ! -f "${target}" ]]; then
            {
                echo "# Agent Identity"
                echo
                echo "> Migrated from OpenClaw IDENTITY.md."
                echo
                cat "${ws}/IDENTITY.md"
            } > "${target}"
            log_migrated "IDENTITY.md → ${target}"
            promptinclude_created=1
        else
            log_skipped "identity.promptinclude.md already exists for profile '${profile_id}'"
        fi
    fi

    if [[ -f "${ws}/USER.md" ]]; then
        target="${AGENT_WORKDIR}/user.promptinclude.md"
        if [[ ! -f "${target}" ]]; then
            {
                echo "# User Profile"
                echo
                echo "> Migrated from OpenClaw USER.md."
                echo
                cat "${ws}/USER.md"
            } > "${target}"
            log_migrated "USER.md → ${target}"
            promptinclude_created=1
        else
            log_skipped "user.promptinclude.md already exists for profile '${profile_id}'"
        fi
    fi

    if [[ -f "${ws}/MEMORY.md" ]]; then
        target="${AGENT_WORKDIR}/memory.promptinclude.md"
        if [[ ! -f "${target}" ]]; then
            {
                echo "# Long-Term Memory"
                echo
                echo "> Migrated from OpenClaw MEMORY.md."
                echo "> Agent Zero will load this only when the active workdir or project points to this folder."
                echo
                cat "${ws}/MEMORY.md"
            } > "${target}"
            log_migrated "MEMORY.md → ${target}"
            promptinclude_created=1
        else
            log_skipped "memory.promptinclude.md already exists for profile '${profile_id}'"
        fi

        target="${MEMORY_KNOWLEDGE_DIR}/${profile_id}/MEMORY.md"
        if [[ ! -f "${target}" ]]; then
            mkdir -p "$(dirname "${target}")"
            cp "${ws}/MEMORY.md" "${target}"
            log_migrated "MEMORY.md → knowledge/custom/openclaw-memory/${profile_id}/MEMORY.md"
        else
            log_skipped "Memory knowledge file already exists for profile '${profile_id}'"
        fi
    fi

    readme_target="${AGENT_WORKDIR}/README.md"
    if [[ ! -f "${readme_target}" ]]; then
        {
            echo "# OpenClaw Promptinclude Migration"
            echo
            echo "This folder contains promptinclude files generated from OpenClaw workspace content for Agent Zero profile \`${profile_id}\`."
            echo
            echo "To have Agent Zero load these files with the \`_promptinclude\` plugin, set the active workdir or project to this folder."
            echo
            echo "- OpenClaw agent id: \`${aid}\`"
            echo "- Source workspace: \`${ws}\`"
        } > "${readme_target}"
        log_migrated "Promptinclude README for profile '${profile_id}'"
    else
        log_skipped "Promptinclude README already exists for profile '${profile_id}'"
    fi

    specifics_target="${PROMPTS_DIR}/agent.system.main.specifics.md"
    if [[ ! -f "${specifics_target}" ]]; then
        if [[ -f "${ws}/AGENTS.md" || -f "${ws}/TOOLS.md" || -f "${ws}/IDENTITY.md" || -f "${ws}/USER.md" || -f "${ws}/MEMORY.md" ]]; then
            {
                echo "# Agent Specifics"
                echo
                echo "> Generated from OpenClaw workspace \`${ws}\`."
                echo "> This Agent Zero profile preserves prompt content, but not OpenClaw auth/session/channel isolation."
                echo
                if [[ -f "${ws}/AGENTS.md" ]]; then
                    echo "## Operating Instructions"
                    echo
                    cat "${ws}/AGENTS.md"
                    echo
                fi
                if [[ -f "${ws}/TOOLS.md" ]]; then
                    echo "## Local Tool Notes"
                    echo
                    cat "${ws}/TOOLS.md"
                    echo
                fi
                echo "## Migration Notes"
                echo
                echo "- Promptinclude files were written to \`${AGENT_WORKDIR}\`."
                echo "- To load \`IDENTITY.md\`, \`USER.md\`, and \`MEMORY.md\` automatically, point Agent Zero workdir or project to that folder."
                echo "- \`memory/*.md\` files were copied into \`${KNOWLEDGE_DIR}/${profile_id}\` for searchability."
                if [[ -f "${ws}/MEMORY.md" ]]; then
                    echo "- \`MEMORY.md\` was also copied into \`${MEMORY_KNOWLEDGE_DIR}/${profile_id}/MEMORY.md\` for reference."
                fi
            } > "${specifics_target}"
            log_migrated "agent.system.main.specifics.md for profile '${profile_id}'"
        fi
    else
        log_skipped "agent.system.main.specifics.md already exists for profile '${profile_id}'"
    fi

    if [[ -d "${ws}/memory" ]]; then
        copied_count=0
        mkdir -p "${KNOWLEDGE_DIR}/${profile_id}"
        for md_file in "${ws}/memory/"*.md; do
            [[ ! -f "${md_file}" ]] && continue
            target="${KNOWLEDGE_DIR}/${profile_id}/$(basename "${md_file}")"
            if [[ ! -f "${target}" ]]; then
                cp "${md_file}" "${target}"
                copied_count=$((copied_count + 1))
            fi
        done
        if [[ ${copied_count} -gt 0 ]]; then
            log_migrated "${copied_count} memory/*.md files → knowledge/custom/openclaw/${profile_id}"
        else
            log_skipped "No new memory/*.md files for profile '${profile_id}'"
        fi
    fi
done

header "Step 4: Telegram"

TG_PLUGIN_DIR="${A0_USR_DIR}/plugins/_telegram_integration"
TG_CONFIG="${TG_PLUGIN_DIR}/config.json"
TG_NOTES="${TG_PLUGIN_DIR}/openclaw-migration-notes.md"
mkdir -p "${TG_PLUGIN_DIR}"

telegram_payload="$(build_telegram_payload)"
telegram_bot_count="$(TELEGRAM_PAYLOAD="${telegram_payload}" python3 - <<'PY'
import json
import os
import sys
payload = json.loads(os.environ.get("TELEGRAM_PAYLOAD", "{}") or "{}")
print(len(payload.get("bots") or []))
PY
)"

if [[ "${telegram_bot_count}" -gt 0 ]]; then
    if [[ ! -f "${TG_CONFIG}" ]]; then
        TELEGRAM_PAYLOAD="${telegram_payload}" python3 - "${TG_CONFIG}" <<'PY'
import json
import os
import pathlib
import sys

payload = json.loads(os.environ.get("TELEGRAM_PAYLOAD", "{}") or "{}")
target = pathlib.Path(sys.argv[1])
target.parent.mkdir(parents=True, exist_ok=True)
config = {"bots": payload.get("bots", [])}
target.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
PY
        log_migrated "Telegram config → ${TG_CONFIG}"
    else
        log_skipped "Telegram config already exists at ${TG_CONFIG}"
        log_warning "Review existing Telegram config manually: ${TG_CONFIG}"
    fi

    {
        echo "# OpenClaw Telegram Migration Notes"
        echo
        echo "- Generated from: \`${OPENCLAW_CONFIG}\`"
        echo "- Output config: \`${TG_CONFIG}\`"
        echo "- Bot count migrated: ${telegram_bot_count}"
        echo
        echo "## Manual Review Items"
        echo
        echo "- Per-group policies are mapped conservatively to Agent Zero \`group_mode\`."
        echo "- OpenClaw bindings, pairing, and DM policy do not map cleanly and require manual review."
        echo "- Session history and channel routing are not migrated."
        echo
        echo "## Payload Notes"
        echo
        TELEGRAM_PAYLOAD="${telegram_payload}" python3 - <<'PY'
import json
import os
import sys

payload = json.loads(os.environ.get("TELEGRAM_PAYLOAD", "{}") or "{}")
notes = payload.get("notes") or []
warnings = payload.get("warnings") or []

if not notes and not warnings:
    print("- No extra migration notes emitted.")
else:
    for item in notes:
        print(f"- {item}")
    for item in warnings:
        print(f"- WARNING: {item}")
PY
    } > "${TG_NOTES}"
    log_migrated "Telegram migration notes → ${TG_NOTES}"

    while IFS= read -r tg_warning; do
        [[ -z "${tg_warning}" ]] && continue
        log_warning "${tg_warning}"
    done < <(TELEGRAM_PAYLOAD="${telegram_payload}" python3 - <<'PY'
import json
import os
import sys

payload = json.loads(os.environ.get("TELEGRAM_PAYLOAD", "{}") or "{}")
for item in payload.get("warnings") or []:
    print(item)
PY
)
else
    log_skipped "No Telegram bot tokens found to migrate"
fi

header "Step 5: Skills"

for i in "${!AGENT_IDS[@]}"; do
    aid="${AGENT_IDS[$i]}"
    ws="${AGENT_WORKSPACES[$i]}"
    profile_id="${AGENT_PROFILE_IDS[$i]}"
    [[ ! -d "${ws}/skills" ]] && continue

    for skill_dir in "${ws}/skills/"*/; do
        [[ ! -d "${skill_dir}" ]] && continue
        skill_name="$(basename "${skill_dir}")"
        target="${A0_USR_DIR}/agents/${profile_id}/skills/${skill_name}"
        copy_dir_with_collision_handling "${skill_dir%/}" "${target}" "Workspace skill '${skill_name}' for profile '${profile_id}'"
    done
done

if [[ -d "${OPENCLAW_DIR}/skills" ]]; then
    for skill_dir in "${OPENCLAW_DIR}/skills/"*/; do
        [[ ! -d "${skill_dir}" ]] && continue
        skill_name="$(basename "${skill_dir}")"
        target="${A0_USR_DIR}/skills/${skill_name}"
        copy_dir_with_collision_handling "${skill_dir%/}" "${target}" "Global skill '${skill_name}'"
    done
fi

header "Migration Complete"
echo
echo -e "  ${GREEN}Migrated${NC} : ${MIGRATED} items"
echo -e "  ${BLUE}Skipped${NC}  : ${SKIPPED} items"
echo -e "  ${YELLOW}Warnings${NC} : ${WARNINGS}"
echo

{
    echo "# OpenClaw → Agent Zero Migration Log"
    echo "Date: $(date -Iseconds)"
    echo "Source: ${OPENCLAW_DIR}"
    echo "Target: ${A0_USR_DIR}"
    echo "Config parser: ${CONFIG_PARSE_MODE}"
    echo "Migrated: ${MIGRATED}"
    echo "Skipped: ${SKIPPED}"
    echo "Warnings: ${WARNINGS}"
} > "${MIGRATION_LOG}"

report_line
report_line "## Manual Follow-Up"
report_line
report_line "- Set Agent Zero workdir or project to one of the generated folders under \`${MIGRATION_WORKDIR_ROOT}\` if you want the migrated \`*.promptinclude.md\` files loaded automatically."
report_line "- Review Telegram routing, DM policy, bindings, and webhook details before enabling the plugin."
report_line "- OpenClaw OAuth profiles, session history, channel state, and agent isolation are not fully portable."
report_line "- Review migrated profiles under Settings → Agents and verify prompts, skills, and model settings."

info "Migration log: ${MIGRATION_LOG}"
info "Migration report: ${MIGRATION_REPORT}"
echo

if [[ ${MIGRATED} -gt 0 ]]; then
    echo -e "${BOLD}Next steps:${NC}"
    echo "  1. Review generated profiles under Settings → Agents"
    echo "  2. Point Agent Zero workdir/project to ${MIGRATION_WORKDIR_ROOT}/<profile-id> if you want promptinclude behavior"
    echo "  3. Review knowledge files under ${KNOWLEDGE_DIR} and ${MEMORY_KNOWLEDGE_DIR}"
    echo "  4. Review ${TG_CONFIG} and ${TG_NOTES} before enabling Telegram"
    echo
fi

if [[ ${WARNINGS} -gt 0 ]]; then
    echo -e "${BOLD}${YELLOW}Review warnings above for items needing manual attention.${NC}"
    echo
fi

echo -e "${BOLD}Not migrated automatically:${NC}"
echo "  • OpenClaw auth/session/channel isolation semantics"
echo "  • OAuth profiles beyond API-key-style secrets"
echo "  • Session history / transcripts"
echo "  • Channel bindings / agent routing"
echo "  • Heartbeat / cron schedules (use A0 Task Scheduler)"
echo "  • Model selection and per-project UI settings"
echo
