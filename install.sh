#!/usr/bin/env bash

# Agent Zero Install Script v1
# Simplified Docker-based installation
# https://github.com/agent0ai/agent-zero

set -e

# Ensure we are running under bash (not dash, sh, etc.)
if [ -z "$BASH_VERSION" ]; then
    echo "[ERROR] This script requires bash. Please run it with: bash install.sh" >&2
    exit 1
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

print_banner() {
    printf "%b" "${BLUE}"
    cat <<'EOF'
 █████╗   ██████╗ ███████╗███╗   ██╗████████╗   ███████╗███████╗██████╗  ██████╗ 
██╔══██╗ ██╔════╝ ██╔════╝████╗  ██║╚══██╔══╝   ╚══███╔╝██╔════╝██╔══██╗██╔═══██╗
███████║ ██║  ███╗█████╗  ██╔██╗ ██║   ██║        ███╔╝ █████╗  ██████╔╝██║   ██║
██╔══██║ ██║   ██║██╔══╝  ██║╚██╗██║   ██║       ███╔╝  ██╔══╝  ██╔══██╗██║   ██║
██║  ██║ ╚██████╔╝███████╗██║ ╚████║   ██║      ███████╗███████╗██║  ██║╚██████╔╝
╚═╝  ╚═╝  ╚═════╝ ╚══════╝╚═╝  ╚═══╝   ╚═╝      ╚══════╝╚══════╝╚═╝  ╚═╝ ╚═════╝ 
EOF
    printf "%b\n" "${NC}"
}

print_ok()    { printf "  ${GREEN}✔${NC} %s\n" "$1"; }
print_info()  { printf "${GREEN}[INFO]${NC} %s\n" "$1"; }
print_warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
print_error() { printf "${RED}[ERROR]${NC} %s\n" "$1"; }

A0_CLI_NON_INTERACTIVE=0
A0_CLI_SKIP_RUNTIME_SETUP=0
A0_CLI_NAME=""
A0_CLI_TAG=""
A0_CLI_PORT=""
A0_CLI_DATA_DIR=""
A0_CLI_AUTH_LOGIN=""
A0_CLI_AUTH_PASSWORD=""
A0_CLI_AUTH_LOGIN_SET=0
A0_CLI_AUTH_PASSWORD_SET=0
A0_RUNTIME_ENDPOINT_SELECTION_POLICY="reuse-before-setup"

usage() {
    cat <<'EOF'
Agent Zero CLI installer

Usage:
  bash install.sh [options]

Options:
  --quick-start             Create an instance without menus, using defaults.
  --non-interactive         Same as --quick-start; never open installer menus.
  -y, --yes                 Alias for --non-interactive.
  --name NAME               Container/instance name.
  --tag TAG                 Agent Zero image tag, for example v1.20.
  --port PORT               Web UI host port.
  --data-dir PATH           Host data directory mounted to /a0/usr.
  --auth-login USER         Enable Web UI basic auth with this username.
  --auth-password PASSWORD  Auth password. Defaults to 12345678 when login is set.
  --skip-runtime-setup      Require an already-working Docker runtime.
  -h, --help                Show this help.
EOF
}

require_arg_value() {
    if [ $# -lt 2 ] || [ -z "$2" ]; then
        print_error "$1 requires a value."
        exit 2
    fi
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            --quick-start)
                A0_CLI_NON_INTERACTIVE=1
                ;;
            --non-interactive|-y|--yes)
                A0_CLI_NON_INTERACTIVE=1
                ;;
            --skip-runtime-setup)
                A0_CLI_SKIP_RUNTIME_SETUP=1
                ;;
            --name=*)
                A0_CLI_NAME="${1#*=}"
                A0_CLI_NON_INTERACTIVE=1
                ;;
            --name)
                require_arg_value "$1" "${2-}"
                A0_CLI_NAME="$2"
                A0_CLI_NON_INTERACTIVE=1
                shift
                ;;
            --tag=*|--version=*)
                A0_CLI_TAG="${1#*=}"
                A0_CLI_NON_INTERACTIVE=1
                ;;
            --tag|--version)
                require_arg_value "$1" "${2-}"
                A0_CLI_TAG="$2"
                A0_CLI_NON_INTERACTIVE=1
                shift
                ;;
            --port=*)
                A0_CLI_PORT="${1#*=}"
                A0_CLI_NON_INTERACTIVE=1
                ;;
            --port)
                require_arg_value "$1" "${2-}"
                A0_CLI_PORT="$2"
                A0_CLI_NON_INTERACTIVE=1
                shift
                ;;
            --data-dir=*)
                A0_CLI_DATA_DIR="${1#*=}"
                A0_CLI_NON_INTERACTIVE=1
                ;;
            --data-dir)
                require_arg_value "$1" "${2-}"
                A0_CLI_DATA_DIR="$2"
                A0_CLI_NON_INTERACTIVE=1
                shift
                ;;
            --auth-login=*)
                A0_CLI_AUTH_LOGIN="${1#*=}"
                A0_CLI_AUTH_LOGIN_SET=1
                A0_CLI_NON_INTERACTIVE=1
                ;;
            --auth-login)
                require_arg_value "$1" "${2-}"
                A0_CLI_AUTH_LOGIN="$2"
                A0_CLI_AUTH_LOGIN_SET=1
                A0_CLI_NON_INTERACTIVE=1
                shift
                ;;
            --auth-password=*)
                A0_CLI_AUTH_PASSWORD="${1#*=}"
                A0_CLI_AUTH_PASSWORD_SET=1
                A0_CLI_NON_INTERACTIVE=1
                ;;
            --auth-password)
                require_arg_value "$1" "${2-}"
                A0_CLI_AUTH_PASSWORD="$2"
                A0_CLI_AUTH_PASSWORD_SET=1
                A0_CLI_NON_INTERACTIVE=1
                shift
                ;;
            *)
                print_error "Unknown option: $1"
                usage
                exit 2
                ;;
        esac
        shift
    done
}

# Detect whether bash supports fractional read timeouts (bash 4+ does, bash 3.2 on macOS does not).
HAS_FRACTIONAL_TIMEOUT=0
if (IFS= read -r -n 1 -t 0.1 _probe <<< "x") 2>/dev/null; then
    HAS_FRACTIONAL_TIMEOUT=1
fi

# Save original tty settings and restore them on exit.
# This ensures the terminal is never left in a broken state (e.g. no echo)
# if the script is interrupted or exits while stty is modified.
_ORIGINAL_TTY_SETTINGS=""
if [ -e /dev/tty ]; then
    _ORIGINAL_TTY_SETTINGS="$(stty -g 2>/dev/null </dev/tty || true)"
fi
restore_tty() {
    if [ ! -e /dev/tty ]; then
        return 0
    fi
    if [ -n "$_ORIGINAL_TTY_SETTINGS" ]; then
        stty "$_ORIGINAL_TTY_SETTINGS" 2>/dev/null </dev/tty || true
    else
        stty sane 2>/dev/null </dev/tty || true
    fi
}
trap restore_tty EXIT
trap 'restore_tty; exit 130' INT
trap 'restore_tty; exit 143' TERM HUP

DOCKER=(docker)
DOCKER_HOST_ARGS=()
DOCKER_SUDO_NOTICE_SHOWN=0
A0_DOCKER_ENDPOINT_NOTICE_SHOWN=0
A0_DOCKER_ENDPOINT_SCAN_SEEN=""

A0_COLIMA_PROFILE="${A0_COLIMA_PROFILE:-a0}"
A0_MAC_RUNTIME_DIR="${A0_MAC_RUNTIME_DIR:-$HOME/Library/Application Support/a0-install/runtime}"
A0_MAC_BIN_DIR="$A0_MAC_RUNTIME_DIR/bin"

# Read a single byte from /dev/tty with a short (~0.1s) timeout.
# Used to disambiguate bare Escape from arrow-key escape sequences.
# Sets _TIMED_KEY to the byte read, or "" on timeout. Returns 0 on
# success, 1 on timeout.
_TIMED_KEY=""
read_byte_with_short_timeout() {
    _TIMED_KEY=""
    if [ "$HAS_FRACTIONAL_TIMEOUT" -eq 1 ]; then
        IFS= read -rsn1 -t 0.1 _TIMED_KEY </dev/tty 2>/dev/null || true
    else
        # Bash 3.2 (macOS) does not support fractional -t values.
        # Use stty to configure the tty driver for a non-canonical 0.1s timeout,
        # then use dd to read a single byte.
        local _saved_tty
        _saved_tty="$(stty -g </dev/tty 2>/dev/null)"
        if [ -z "$_saved_tty" ]; then
            # Cannot save tty state — skip stty manipulation, just return timeout
            return 1
        fi
        # -icanon: byte-at-a-time mode, min 0 time 1: return after 0.1s if no byte
        stty -icanon -echo min 0 time 1 </dev/tty 2>/dev/null
        _TIMED_KEY="$(dd bs=1 count=1 </dev/tty 2>/dev/null)" || true
        # Restore original tty settings
        stty "$_saved_tty" </dev/tty 2>/dev/null
    fi
    if [ -n "$_TIMED_KEY" ]; then
        return 0
    fi
    return 1
}

wait_for_keypress() {
    printf "\nPress any key to continue..."
    IFS= read -rsn1 _key </dev/tty
}

# Check whether a TCP port is in use on localhost.
# Uses a fallback chain: lsof → nc → /dev/tcp (for broad OS compatibility).
# Also checks Docker container port mappings directly.
# Returns 0 if in use, 1 if free.
is_port_in_use() {
    CHECK_PORT="$1"

    # Check Docker-published ports (covers stopped containers with port reservations too)
    DOCKER_PORTS="$("${DOCKER[@]}" ps -a --format '{{.Ports}}' 2>/dev/null || true)"
    if printf "%s\n" "$DOCKER_PORTS" | grep -qE ":${CHECK_PORT}->" 2>/dev/null; then
        return 0
    fi

    # System-level check via lsof (macOS + Linux)
    if command -v lsof >/dev/null 2>&1; then
        if lsof -i ":${CHECK_PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
            return 0
        fi
        return 1
    fi

    # Fallback: nc (netcat)
    if command -v nc >/dev/null 2>&1; then
        if nc -z localhost "$CHECK_PORT" >/dev/null 2>&1; then
            return 0
        fi
        return 1
    fi

    # Last resort: assume free
    return 1
}

# Find the first free port starting from a given base.
find_free_port() {
    BASE_PORT="${1:-5080}"
    CANDIDATE_PORT="$BASE_PORT"
    MAX_ATTEMPTS=100

    ATTEMPT=0
    while [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]; do
        if ! is_port_in_use "$CANDIDATE_PORT"; then
            printf "%d\n" "$CANDIDATE_PORT"
            return 0
        fi
        CANDIDATE_PORT=$((CANDIDATE_PORT + 1))
        ATTEMPT=$((ATTEMPT + 1))
    done

    # If we exhausted attempts, return the base port and let Docker report the conflict
    printf "%d\n" "$BASE_PORT"
}

expand_user_path() {
    case "$1" in
        "~/"*) printf "%s\n" "$HOME/${1#\~/}" ;;
        "~") printf "%s\n" "$HOME" ;;
        *) printf "%s\n" "$1" ;;
    esac
}

validate_port() {
    local _port="$1"
    case "$_port" in
        ''|*[!0-9]*)
            return 1
            ;;
    esac

    if [ "$_port" -lt 1 ] 2>/dev/null || [ "$_port" -gt 65535 ] 2>/dev/null; then
        return 1
    fi

    return 0
}

# Character-by-character text input with pre-filled default and Escape to go back.
# Supports: backspace, delete, left/right arrows, Home/End, Enter, Escape.
#   $1 (optional) — default value to pre-fill in the input buffer.
#   - Enter to submit (result stored in INPUT_VALUE, returns 0)
#   - Escape to abort / go back (returns 1)
# Ctrl-C retains its default behavior (exit the installer).
# Usage: read_input "default" || { handle_go_back; }
#        then use $INPUT_VALUE
INPUT_VALUE=""
read_input() {
    INPUT_VALUE=""
    local _buf="${1-}"
    local _cur=${#_buf}       # cursor position (index into _buf)

    # Flush any stale bytes from /dev/tty before reading.
    while IFS= read -rsn1 -t 0.01 _junk </dev/tty 2>/dev/null; do :; done

    # Helper: redraw the current line. Moves to column 0, clears the line,
    # prints the buffer, then repositions the cursor.
    _ri_redraw() {
        # \r          — move to column 0
        # \033[0K     — clear from cursor to end of line
        printf "\r\033[0K%s" "$_buf" >/dev/tty
        # Move cursor to the correct position within the buffer
        local _tail_len=$(( ${#_buf} - _cur ))
        if [ "$_tail_len" -gt 0 ]; then
            printf "\033[%dD" "$_tail_len" >/dev/tty
        fi
    }

    # Print initial buffer contents
    _ri_redraw

    while :; do
        IFS= read -rsn1 _ch </dev/tty

        # Enter (empty read or literal newline) — submit
        if [ -z "$_ch" ] || [ "$_ch" = $'\n' ]; then
            printf "\n" >/dev/tty
            INPUT_VALUE="$_buf"
            return 0
        fi

        # Escape — go back (disambiguate from arrow key sequences)
        if [ "$_ch" = $'\x1b' ]; then
            read_byte_with_short_timeout; _ch2="$_TIMED_KEY"
            if [ "$_ch2" = "[" ]; then
                IFS= read -rsn1 _ch3 </dev/tty
                case "$_ch3" in
                    A|B) ;;  # Up/Down — ignore for text input
                    C)  # Right arrow
                        if [ "$_cur" -lt "${#_buf}" ]; then
                            _cur=$((_cur + 1))
                            printf "\033[C" >/dev/tty
                        fi
                        ;;
                    D)  # Left arrow
                        if [ "$_cur" -gt 0 ]; then
                            _cur=$((_cur - 1))
                            printf "\033[D" >/dev/tty
                        fi
                        ;;
                    H)  # Home
                        _cur=0
                        _ri_redraw
                        ;;
                    F)  # End
                        _cur=${#_buf}
                        _ri_redraw
                        ;;
                    3)  # Delete key (sends \x1b[3~)
                        IFS= read -rsn1 _ch4 </dev/tty 2>/dev/null || _ch4=""
                        if [ "$_ch4" = "~" ] && [ "$_cur" -lt "${#_buf}" ]; then
                            _buf="${_buf:0:_cur}${_buf:_cur+1}"
                            _ri_redraw
                        fi
                        ;;
                esac
            elif [ -z "$_ch2" ]; then
                # Bare Escape — go back
                printf "\n" >/dev/tty
                return 1
            fi
            continue
        fi

        # Backspace (0x7f or 0x08)
        if [ "$_ch" = $'\x7f' ] || [ "$_ch" = $'\x08' ]; then
            if [ "$_cur" -gt 0 ]; then
                _buf="${_buf:0:_cur-1}${_buf:_cur}"
                _cur=$((_cur - 1))
                _ri_redraw
            fi
            continue
        fi

        # Ctrl-D — also go back (familiar shortcut)
        if [ "$_ch" = $'\x04' ]; then
            printf "\n" >/dev/tty
            return 1
        fi

        # Ctrl-A — Home
        if [ "$_ch" = $'\x01' ]; then
            _cur=0
            _ri_redraw
            continue
        fi

        # Ctrl-E — End
        if [ "$_ch" = $'\x05' ]; then
            _cur=${#_buf}
            _ri_redraw
            continue
        fi

        # Ctrl-U — clear line
        if [ "$_ch" = $'\x15' ]; then
            _buf=""
            _cur=0
            _ri_redraw
            continue
        fi

        # Ctrl-K — kill from cursor to end
        if [ "$_ch" = $'\x0b' ]; then
            _buf="${_buf:0:_cur}"
            _ri_redraw
            continue
        fi

        # Ctrl-C — exit the installer
        if [ "$_ch" = $'\x03' ]; then
            printf "\n" >/dev/tty
            exit 130
        fi

        # Ignore other control characters
        case "$_ch" in
            $'\x00'|$'\x02'|$'\x06'|$'\x07'|$'\x09'|$'\x0c'|$'\x0e'|$'\x0f'|$'\x10'|$'\x11'|$'\x12'|$'\x13'|$'\x14'|$'\x16'|$'\x17'|$'\x18'|$'\x19'|$'\x1a'|$'\x1c'|$'\x1d'|$'\x1e'|$'\x1f')
                continue
                ;;
        esac

        # Regular printable character — insert at cursor position
        _buf="${_buf:0:_cur}${_ch}${_buf:_cur}"
        _cur=$((_cur + 1))
        _ri_redraw
    done
}

select_from_menu() {
    # Check for header parameter (starts with --header=)
    MENU_HEADER=""
    if [ $# -gt 0 ] && [ "${1#--header=}" != "$1" ]; then
        MENU_HEADER="${1#--header=}"
        shift
    fi

    # Validate at least one option provided
    if [ $# -eq 0 ]; then
        print_error "select_from_menu requires at least one menu option"
        exit 1
    fi

    ITEM_COUNT=$#
    SELECTED_INDEX=0

    # Flush any buffered stdin so stale keypresses don't auto-select an option.
    # On bash 3.2 where fractional timeouts fail, `read` returns non-zero
    # immediately, which exits the loop instantly.  That's fine.
    while IFS= read -rsn1 -t 0.01 _junk </dev/tty 2>/dev/null; do :; done

    while :; do
        # Clear screen
        clear >/dev/tty 2>&1 || true
        print_banner >/dev/tty

        # Display header if provided
        if [ -n "$MENU_HEADER" ]; then
            echo "$MENU_HEADER" >/dev/tty
            echo "" >/dev/tty
        fi

        # Render menu items
        CURRENT_INDEX=0
        for item in "$@"; do
            if [ "$CURRENT_INDEX" -eq "$SELECTED_INDEX" ]; then
                printf "  ${GREEN}> %s${NC}\n" "$item" >/dev/tty
            else
                printf "    %s\n" "$item" >/dev/tty
            fi
            CURRENT_INDEX=$((CURRENT_INDEX + 1))
        done

        # Show help text
        echo "" >/dev/tty
        printf "Use ↑/↓ to navigate, Enter to select, Esc to go back, Ctrl+C to exit\n" >/dev/tty

        # Read single character from terminal
        IFS= read -rsn1 key </dev/tty

        # Handle Enter key (empty read or newline)
        if [ -z "$key" ] || [ "$key" = $'\n' ]; then
            printf "%d\n" "$SELECTED_INDEX"
            return 0
        fi

        # Handle Ctrl-C — exit the installer
        if [ "$key" = $'\x03' ]; then
            printf "\n" >/dev/tty
            exit 130
        fi

        # Handle Backspace key (go back)
        if [ "$key" = $'\x7f' ] || [ "$key" = $'\x08' ]; then
            printf "%s\n" "-1"
            return 1
        fi

        # Handle escape sequences (arrow keys) and bare Escape (go back)
        if [ "$key" = $'\x1b' ]; then
            read_byte_with_short_timeout; key2="$_TIMED_KEY"
            if [ "$key2" = "[" ]; then
                # Read arrow key identifier
                IFS= read -rsn1 key3 </dev/tty
                case "$key3" in
                    A) # Up arrow
                        SELECTED_INDEX=$((SELECTED_INDEX - 1))
                        if [ "$SELECTED_INDEX" -lt 0 ]; then
                            SELECTED_INDEX=$((ITEM_COUNT - 1))
                        fi
                        ;;
                    B) # Down arrow
                        SELECTED_INDEX=$((SELECTED_INDEX + 1))
                        if [ "$SELECTED_INDEX" -ge "$ITEM_COUNT" ]; then
                            SELECTED_INDEX=0
                        fi
                        ;;
                esac
            else
                # Bare Escape (timeout or unknown sequence) — go back
                printf "%s\n" "-1"
                return 1
            fi
        fi
    done
}

DOCKER_INFO_STATUS=""
DOCKER_INFO_OUTPUT=""

probe_docker_info() {
    DOCKER_INFO_STATUS="error"
    DOCKER_INFO_OUTPUT="$("$@" info 2>&1 >/dev/null)" && {
        DOCKER_INFO_STATUS="ok"
        return 0
    }

    case "$DOCKER_INFO_OUTPUT" in
        *"permission denied"*|*"Permission denied"*|*"Got permission denied"*)
            DOCKER_INFO_STATUS="permission"
            ;;
        *"Cannot connect to the Docker daemon"*|*"Is the docker daemon running"*|*"failed to connect to the docker API"*|*"connection refused"*|*"Connection refused"*|*"connect: no such file or directory"*)
            DOCKER_INFO_STATUS="daemon"
            ;;
        *"command not found"*|*"No such file or directory"*)
            DOCKER_INFO_STATUS="missing"
            ;;
        *)
            DOCKER_INFO_STATUS="error"
            ;;
    esac
    return 1
}

normalize_docker_host_candidate() {
    local _host="$1"
    case "$_host" in
        "")
            return 1
            ;;
        unix://*|tcp://*|http://*|https://*|ssh://*)
            printf "%s\n" "$_host"
            ;;
        /*)
            printf "unix://%s\n" "$_host"
            ;;
        *)
            return 1
            ;;
    esac
}

is_local_docker_host_candidate() {
    case "$1" in
        unix://*|tcp://localhost:*|tcp://127.*|tcp://[[]::1[]]:*|http://localhost:*|https://localhost:*)
            return 0
            ;;
    esac
    return 1
}

docker_host_socket_exists() {
    local _host="$1"
    local _socket
    case "$_host" in
        unix://*)
            _socket="${_host#unix://}"
            [ -e "$_socket" ]
            ;;
        *)
            return 0
            ;;
    esac
}

try_docker_endpoint_candidate() {
    local _label="$1"
    local _candidate="$2"
    local _host

    _host="$(normalize_docker_host_candidate "$_candidate")" || return 1
    is_local_docker_host_candidate "$_host" || return 1
    docker_host_socket_exists "$_host" || return 1

    case "$A0_DOCKER_ENDPOINT_SCAN_SEEN" in
        *"|${_host}|"*)
            return 1
            ;;
    esac
    A0_DOCKER_ENDPOINT_SCAN_SEEN="${A0_DOCKER_ENDPOINT_SCAN_SEEN}|${_host}|"

    if probe_docker_info docker -H "$_host"; then
        DOCKER_HOST_ARGS=(-H "$_host")
        DOCKER=(docker "${DOCKER_HOST_ARGS[@]}")
        if [ "$A0_DOCKER_ENDPOINT_NOTICE_SHOWN" -eq 0 ]; then
            print_ok "Using Docker runtime: ${_label}"
            A0_DOCKER_ENDPOINT_NOTICE_SHOWN=1
        fi
        return 0
    fi

    return 1
}

try_docker_host_env_endpoint() {
    if [ -z "${DOCKER_HOST:-}" ]; then
        return 1
    fi
    try_docker_endpoint_candidate "DOCKER_HOST" "$DOCKER_HOST"
}

try_docker_context_endpoint() {
    local _context="$1"
    local _host

    if [ -z "$_context" ]; then
        return 1
    fi

    _host="$(docker context inspect "$_context" --format '{{ (index .Endpoints "docker").Host }}' 2>/dev/null || true)"
    if [ -z "$_host" ] || [ "$_host" = "<no value>" ]; then
        return 1
    fi

    try_docker_endpoint_candidate "Docker context '${_context}'" "$_host"
}

try_docker_context_endpoints() {
    local _current_context
    local _contexts
    local _context

    if ! command -v docker >/dev/null 2>&1; then
        return 1
    fi

    _current_context="$(docker context show 2>/dev/null || true)"
    if [ -n "$_current_context" ] && try_docker_context_endpoint "$_current_context"; then
        return 0
    fi

    _contexts="$(docker context ls --format '{{.Name}}' 2>/dev/null || true)"
    while IFS= read -r _context; do
        [ -n "$_context" ] || continue
        [ "$_context" != "$_current_context" ] || continue
        if try_docker_context_endpoint "$_context"; then
            return 0
        fi
    done <<EOF
$_contexts
EOF

    return 1
}

try_known_docker_socket_candidate() {
    local _label="$1"
    local _socket="$2"
    [ -n "$_socket" ] || return 1
    [ -e "$_socket" ] || return 1
    try_docker_endpoint_candidate "$_label" "unix://${_socket}"
}

try_known_docker_socket_candidates() {
    local _uid=""
    _uid="$(id -u 2>/dev/null || true)"

    try_known_docker_socket_candidate "Docker Engine" "/var/run/docker.sock" && return 0
    try_known_docker_socket_candidate "Docker Desktop" "$HOME/.docker/run/docker.sock" && return 0
    try_known_docker_socket_candidate "Docker Desktop" "$HOME/.docker/desktop/docker.sock" && return 0
    try_known_docker_socket_candidate "OrbStack" "$HOME/.orbstack/run/docker.sock" && return 0
    try_known_docker_socket_candidate "Rancher Desktop" "$HOME/.rd/docker.sock" && return 0
    try_known_docker_socket_candidate "Colima ${A0_COLIMA_PROFILE}" "$HOME/.colima/${A0_COLIMA_PROFILE}/docker.sock" && return 0
    if [ "$A0_COLIMA_PROFILE" != "default" ]; then
        try_known_docker_socket_candidate "Colima default" "$HOME/.colima/default/docker.sock" && return 0
    fi

    if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
        try_known_docker_socket_candidate "Rootless Docker" "$XDG_RUNTIME_DIR/docker.sock" && return 0
        try_known_docker_socket_candidate "Podman" "$XDG_RUNTIME_DIR/podman/podman.sock" && return 0
    fi
    if [ -n "$_uid" ]; then
        try_known_docker_socket_candidate "Rootless Docker" "/run/user/${_uid}/docker.sock" && return 0
        try_known_docker_socket_candidate "Podman" "/run/user/${_uid}/podman/podman.sock" && return 0
    fi
    try_known_docker_socket_candidate "Podman" "$HOME/.local/share/containers/podman/machine/podman.sock" && return 0

    return 1
}

try_existing_docker_runtime_endpoints() {
    A0_DOCKER_ENDPOINT_SCAN_SEEN=""

    try_docker_host_env_endpoint && return 0
    try_docker_context_endpoints && return 0
    try_known_docker_socket_candidates && return 0

    return 1
}

configure_docker_access() {
    if probe_docker_info docker "${DOCKER_HOST_ARGS[@]}"; then
        DOCKER=(docker "${DOCKER_HOST_ARGS[@]}")
        return 0
    fi

    local _plain_docker_status="$DOCKER_INFO_STATUS"
    if [ "${#DOCKER_HOST_ARGS[@]}" -eq 0 ] && try_existing_docker_runtime_endpoints; then
        return 0
    fi

    if [ "$_plain_docker_status" = "permission" ] && [ "$(id -u 2>/dev/null)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
        if probe_docker_info sudo docker "${DOCKER_HOST_ARGS[@]}"; then
            DOCKER=(sudo docker "${DOCKER_HOST_ARGS[@]}")
            if [ "$DOCKER_SUDO_NOTICE_SHOWN" -eq 0 ]; then
                print_warn "Using sudo for Docker commands in this run. Log out and back in later to use Docker without sudo."
                DOCKER_SUDO_NOTICE_SHOWN=1
            fi
            return 0
        fi
    fi

    case "$_plain_docker_status" in
        permission)
            return 2
            ;;
        daemon|missing)
            return 1
            ;;
        *)
            return 1
            ;;
    esac
}

check_docker_daemon_running() {
    configure_docker_access
}

start_docker_daemon() {
    OS_NAME="$(uname -s 2>/dev/null || true)"

    case "$OS_NAME" in
        Darwin)
            print_info "Starting Docker runtime..."
            if command -v open >/dev/null 2>&1 && open -a Docker >/dev/null 2>&1; then
                return 0
            fi
            print_info "Docker Desktop was not found or could not be opened. Setting up Colima runtime..."
            ensure_macos_colima_runtime
            ;;
        Linux)
            print_info "Starting Docker daemon..."
            # Try systemctl first
            if command -v systemctl >/dev/null 2>&1; then
                if run_as_root systemctl start docker >/dev/null 2>&1; then
                    return 0
                fi
            fi
            # Fallback to service command
            if command -v service >/dev/null 2>&1; then
                if run_as_root service docker start >/dev/null 2>&1; then
                    return 0
                fi
            fi
            print_error "Could not start Docker daemon."
            return 1
            ;;
        *)
            print_error "Automatic Docker daemon start not supported on this OS."
            return 1
            ;;
    esac
}

wait_for_docker_daemon() {
    MAX_WAIT=90
    WAITED=0

    print_info "Waiting for Docker daemon to be ready..."
    while [ $WAITED -lt $MAX_WAIT ]; do
        _docker_ready_rc=0
        configure_docker_access || _docker_ready_rc=$?
        if [ "$_docker_ready_rc" -eq 0 ]; then
            print_ok "Docker daemon is ready"
            return 0
        fi
        if [ "$_docker_ready_rc" -eq 2 ]; then
            print_error "Docker is running, but your user cannot access it yet."
            print_warn "Log out and back in once so your docker group membership is applied, then rerun this installer."
            return 1
        fi
        sleep 1
        WAITED=$((WAITED + 1))
        printf "."
    done
    echo ""
    print_error "Docker daemon did not become ready within ${MAX_WAIT} seconds."
    return 1
}

run_as_root() {
    if [ "$(id -u 2>/dev/null)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

run_root_script() {
    if [ "$(id -u 2>/dev/null)" -eq 0 ]; then
        sh -c "$1"
    else
        sudo sh -c "$1"
    fi
}

safe_install_user() {
    INSTALL_USER=""
    if [ "$(id -u 2>/dev/null)" -eq 0 ]; then
        INSTALL_USER="${SUDO_USER:-}"
    fi
    if [ -z "$INSTALL_USER" ] && command -v id >/dev/null 2>&1; then
        INSTALL_USER="$(id -un 2>/dev/null || true)"
    fi
    if [ -z "$INSTALL_USER" ]; then
        INSTALL_USER="${USER:-}"
    fi
    case "$INSTALL_USER" in
        ""|*[!A-Za-z0-9_.-]*)
            return 1
            ;;
        *)
            printf "%s\n" "$INSTALL_USER"
            return 0
            ;;
    esac
}

detect_linux_package_manager() {
    for PM in apt-get dnf pacman zypper yast rpm; do
        if command -v "$PM" >/dev/null 2>&1; then
            printf "%s\n" "$PM"
            return 0
        fi
    done
    return 1
}

install_docker_on_linux() {
    if ! command -v sudo >/dev/null 2>&1 && [ "$(id -u 2>/dev/null)" -ne 0 ]; then
        print_error "sudo is required to install Docker Engine automatically."
        return 1
    fi

    PM="$(detect_linux_package_manager || true)"
    case "$PM" in
        apt-get)
            INSTALL_SCRIPT='apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io'
            ;;
        dnf)
            INSTALL_SCRIPT='dnf install -y moby-engine || dnf install -y docker'
            ;;
        pacman)
            INSTALL_SCRIPT='pacman -Sy --noconfirm docker'
            ;;
        zypper)
            INSTALL_SCRIPT='zypper --non-interactive install docker'
            ;;
        yast|rpm)
            print_error "Automatic Docker dependency resolution is not available for ${PM}."
            print_info "Install these packages, then rerun this installer: docker containerd runc iptables docker-cli"
            return 1
            ;;
        *)
            print_error "No supported Linux package manager was found."
            print_info "Install Docker Engine manually, then rerun this installer."
            return 1
            ;;
    esac

    print_info "Installing Docker Engine with ${PM}..."
    run_root_script "$INSTALL_SCRIPT"

    print_info "Starting Docker daemon..."
    if command -v systemctl >/dev/null 2>&1 && run_as_root systemctl enable --now docker >/dev/null 2>&1; then
        :
    elif command -v service >/dev/null 2>&1 && run_as_root service docker start >/dev/null 2>&1; then
        :
    else
        print_warn "Docker Engine was installed, but the daemon did not start automatically."
    fi

    INSTALL_USER="$(safe_install_user || true)"
    if [ -n "$INSTALL_USER" ] && [ "$(id -u 2>/dev/null)" -ne 0 ]; then
        print_info "Adding ${INSTALL_USER} to the docker group..."
        run_root_script "if getent group docker >/dev/null 2>&1; then usermod -aG docker '${INSTALL_USER}'; fi"
        print_warn "Your next login session will use Docker without sudo."
    fi
}

macos_runtime_arch() {
    case "$(uname -m 2>/dev/null || true)" in
        arm64) printf "arm64\n" ;;
        x86_64) printf "x86_64\n" ;;
        *)
            print_error "Unsupported macOS architecture: $(uname -m 2>/dev/null || true)"
            return 1
            ;;
    esac
}

macos_docker_static_arch() {
    case "$(uname -m 2>/dev/null || true)" in
        arm64) printf "aarch64\n" ;;
        x86_64) printf "x86_64\n" ;;
        *)
            print_error "Unsupported macOS architecture: $(uname -m 2>/dev/null || true)"
            return 1
            ;;
    esac
}

require_macos_runtime_tools() {
    local _missing=""
    local _tool
    for _tool in curl tar shasum python3; do
        if ! command -v "$_tool" >/dev/null 2>&1; then
            _missing="${_missing:+${_missing} }${_tool}"
        fi
    done

    if [ -n "$_missing" ]; then
        print_error "macOS runtime setup needs these tools: ${_missing}"
        print_info "Install Apple's Command Line Tools with: xcode-select --install"
        return 1
    fi
}

set_colima_docker_host() {
    local _socket="$HOME/.colima/${A0_COLIMA_PROFILE}/docker.sock"
    DOCKER_HOST_ARGS=(-H "unix://${_socket}")
    DOCKER=(docker "${DOCKER_HOST_ARGS[@]}")
}

github_latest_asset() {
    local _api_url="$1"
    local _pattern="$2"

    python3 - "$_api_url" "$_pattern" <<'PY'
import json
import re
import sys
import urllib.request

api_url = sys.argv[1]
pattern = re.compile(sys.argv[2])
request = urllib.request.Request(
    api_url,
    headers={"Accept": "application/vnd.github+json", "User-Agent": "A0-Install"},
)
with urllib.request.urlopen(request, timeout=45) as response:
    payload = json.load(response)
for asset in payload.get("assets", []):
    name = asset.get("name") or ""
    url = asset.get("browser_download_url") or ""
    if pattern.match(name) and url:
        print(f"{name}|{url}")
        raise SystemExit(0)
raise SystemExit(1)
PY
}

docker_static_cli_asset() {
    local _arch="$1"
    local _index_url="https://download.docker.com/mac/static/stable/${_arch}/"

    python3 - "$_index_url" <<'PY'
import re
import sys
import urllib.request

index_url = sys.argv[1]
request = urllib.request.Request(index_url, headers={"User-Agent": "A0-Install"})
with urllib.request.urlopen(request, timeout=45) as response:
    html = response.read().decode("utf-8", "replace")

assets = []
for name, version in re.findall(r'href="(docker-([0-9]+(?:\.[0-9]+){2}(?:-[0-9]+)?)\.tgz)"', html):
    key = tuple(int(part) for part in re.split(r"[.-]", version))
    assets.append((key, name))

if not assets:
    raise SystemExit(1)

name = sorted(assets)[-1][1]
print(f"{name}|{index_url}{name}")
PY
}

checksum_from_url() {
    local _url="$1"
    local _asset_name="$2"

    curl -fsSL "$_url" | awk -v wanted="$_asset_name" '
        NF == 1 {
            print $1
            found = 1
            exit
        }
        NF >= 2 {
            file = $NF
            sub(/^\*/, "", file)
            n = split(file, parts, "/")
            if (parts[n] == wanted) {
                print $1
                found = 1
                exit
            }
        }
        END { if (!found) exit 1 }
    '
}

download_verified() {
    local _url="$1"
    local _dest="$2"
    local _expected_sha="${3:-}"
    local _tmp="${_dest}.tmp.$$"
    local _actual_sha

    mkdir -p "$(dirname "$_dest")"
    rm -f "$_tmp"
    if ! curl -fsSL --retry 3 --connect-timeout 20 --output "$_tmp" "$_url"; then
        rm -f "$_tmp"
        return 1
    fi

    if [ -n "$_expected_sha" ]; then
        _actual_sha="$(shasum -a 256 "$_tmp" | awk '{print $1}')"
        if [ "$_actual_sha" != "$_expected_sha" ]; then
            rm -f "$_tmp"
            print_error "Checksum verification failed for $(basename "$_dest")."
            return 1
        fi
    fi

    mv "$_tmp" "$_dest"
}

install_macos_docker_client() {
    if command -v docker >/dev/null 2>&1; then
        print_ok "Docker client already installed"
        return 0
    fi

    local _docker_arch
    _docker_arch="$(macos_docker_static_arch)" || return 1

    local _asset _asset_name _asset_url _tar_path _extract_dir
    _asset="$(docker_static_cli_asset "$_docker_arch")" || {
        print_error "Could not find Docker's macOS static client."
        return 1
    }
    _asset_name="${_asset%%|*}"
    _asset_url="${_asset#*|}"
    _tar_path="$A0_MAC_RUNTIME_DIR/${_asset_name}"
    _extract_dir="$(mktemp -d "${TMPDIR:-/tmp}/a0-docker-cli.XXXXXX")"

    print_info "Downloading Docker client..."
    # Docker's macOS static index does not publish checksum sidecars.
    if ! download_verified "$_asset_url" "$_tar_path" ""; then
        rm -rf "$_extract_dir"
        print_error "Could not download Docker client."
        return 1
    fi

    print_info "Installing Docker client..."
    if ! tar -xzf "$_tar_path" -C "$_extract_dir" docker/docker; then
        rm -rf "$_extract_dir" "$_tar_path"
        print_error "Could not extract Docker client."
        return 1
    fi
    cp "$_extract_dir/docker/docker" "$A0_MAC_BIN_DIR/docker"
    chmod 755 "$A0_MAC_BIN_DIR/docker"
    rm -rf "$_extract_dir" "$_tar_path"
}

install_macos_colima_tools() {
    if command -v colima >/dev/null 2>&1 && command -v limactl >/dev/null 2>&1; then
        print_ok "Colima runtime tools already installed"
        return 0
    fi

    local _arch
    _arch="$(macos_runtime_arch)" || return 1

    local _colima_release_api="https://api.github.com/repos/abiosoft/colima/releases/latest"
    local _lima_release_api="https://api.github.com/repos/lima-vm/lima/releases/latest"
    local _colima_asset _colima_sha_asset _lima_asset _lima_guest_asset _lima_sha_asset
    _colima_asset="$(github_latest_asset "$_colima_release_api" "^colima-Darwin-${_arch}$")" || {
        print_error "Could not find a Colima release for macOS ${_arch}."
        return 1
    }
    _colima_sha_asset="$(github_latest_asset "$_colima_release_api" "^colima-Darwin-${_arch}[.]sha256sum$")" || {
        print_error "Could not find Colima checksum metadata."
        return 1
    }
    _lima_asset="$(github_latest_asset "$_lima_release_api" "^lima-[0-9].*-Darwin-${_arch}[.]tar[.]gz$")" || {
        print_error "Could not find a Lima release for macOS ${_arch}."
        return 1
    }
    _lima_guest_asset="$(github_latest_asset "$_lima_release_api" "^lima-additional-guestagents-.*-Darwin-${_arch}[.]tar[.]gz$")" || {
        print_error "Could not find Lima guest agent metadata."
        return 1
    }
    _lima_sha_asset="$(github_latest_asset "$_lima_release_api" "^SHA256SUMS$")" || {
        print_error "Could not find Lima checksum metadata."
        return 1
    }

    local _colima_name="${_colima_asset%%|*}" _colima_url="${_colima_asset#*|}"
    local _colima_sha_url="${_colima_sha_asset#*|}"
    local _lima_name="${_lima_asset%%|*}" _lima_url="${_lima_asset#*|}"
    local _lima_guest_name="${_lima_guest_asset%%|*}" _lima_guest_url="${_lima_guest_asset#*|}"
    local _lima_sha_url="${_lima_sha_asset#*|}"

    local _colima_sha _lima_sha _lima_guest_sha
    _colima_sha="$(checksum_from_url "$_colima_sha_url" "$_colima_name")" || {
        print_error "Could not verify Colima checksum metadata."
        return 1
    }
    _lima_sha="$(checksum_from_url "$_lima_sha_url" "$_lima_name")" || {
        print_error "Could not verify Lima checksum metadata."
        return 1
    }
    _lima_guest_sha="$(checksum_from_url "$_lima_sha_url" "$_lima_guest_name")" || {
        print_error "Could not verify Lima guest agent checksum metadata."
        return 1
    }

    local _colima_path="$A0_MAC_BIN_DIR/colima"
    local _lima_tar="$A0_MAC_RUNTIME_DIR/${_lima_name}"
    local _lima_guest_tar="$A0_MAC_RUNTIME_DIR/${_lima_guest_name}"

    print_info "Downloading Colima and Lima..."
    download_verified "$_colima_url" "$_colima_path" "$_colima_sha" || return 1
    chmod 755 "$_colima_path"
    download_verified "$_lima_url" "$_lima_tar" "$_lima_sha" || return 1
    download_verified "$_lima_guest_url" "$_lima_guest_tar" "$_lima_guest_sha" || return 1

    print_info "Installing Colima and Lima..."
    tar -xzf "$_lima_tar" -C "$A0_MAC_RUNTIME_DIR" || return 1
    tar -xzf "$_lima_guest_tar" -C "$A0_MAC_RUNTIME_DIR" || return 1
    rm -f "$_lima_tar" "$_lima_guest_tar"
}

wait_for_colima_docker() {
    local _max_wait=90
    local _waited=0

    print_info "Waiting for Colima Docker runtime..."
    while [ "$_waited" -lt "$_max_wait" ]; do
        if probe_docker_info docker "${DOCKER_HOST_ARGS[@]}"; then
            DOCKER=(docker "${DOCKER_HOST_ARGS[@]}")
            print_ok "Docker daemon is ready"
            return 0
        fi
        sleep 1
        _waited=$((_waited + 1))
        printf "."
    done
    printf "\n"
    print_error "Colima Docker runtime did not become ready within ${_max_wait} seconds."
    return 1
}

ensure_macos_colima_runtime() {
    require_macos_runtime_tools || return 1
    mkdir -p "$A0_MAC_BIN_DIR"
    case ":$PATH:" in
        *":$A0_MAC_BIN_DIR:"*) ;;
        *) export PATH="$A0_MAC_BIN_DIR:$PATH" ;;
    esac

    install_macos_docker_client || return 1
    install_macos_colima_tools || return 1
    set_colima_docker_host

    if probe_docker_info docker "${DOCKER_HOST_ARGS[@]}"; then
        DOCKER=(docker "${DOCKER_HOST_ARGS[@]}")
        print_ok "Docker daemon is running"
        return 0
    fi

    local _previous_context=""
    _previous_context="$(docker context show 2>/dev/null || true)"

    print_info "Starting Colima profile '${A0_COLIMA_PROFILE}'..."
    if ! colima start "$A0_COLIMA_PROFILE" --runtime docker; then
        print_error "Could not start Colima runtime."
        return 1
    fi

    if [ -n "$_previous_context" ] && [ "$_previous_context" != "colima-${A0_COLIMA_PROFILE}" ]; then
        docker context use "$_previous_context" >/dev/null 2>&1 || true
    fi

    wait_for_colima_docker
}

check_docker() {
    # -----------------------------------------------------------
    # 1. Ensure Docker is installed
    # -----------------------------------------------------------
    if command -v docker > /dev/null 2>&1; then
        print_ok "Docker already installed"
    else
        OS_NAME="$(uname -s 2>/dev/null || true)"
        case "$OS_NAME" in
            Linux)
                if [ "$A0_CLI_SKIP_RUNTIME_SETUP" -eq 1 ]; then
                    print_error "Docker is not installed or not on PATH, and runtime setup was skipped."
                    exit 1
                fi
                print_warn "Docker not found. Installing Docker Engine..."
                install_docker_on_linux || exit 1
                ;;
            Darwin)
                if [ "$A0_CLI_SKIP_RUNTIME_SETUP" -eq 1 ]; then
                    print_error "Docker is not installed or not on PATH, and runtime setup was skipped."
                    exit 1
                fi
                print_warn "Docker CLI not found. Installing the Agent Zero Docker client..."
                require_macos_runtime_tools || exit 1
                mkdir -p "$A0_MAC_BIN_DIR"
                case ":$PATH:" in
                    *":$A0_MAC_BIN_DIR:"*) ;;
                    *) export PATH="$A0_MAC_BIN_DIR:$PATH" ;;
                esac
                install_macos_docker_client || exit 1
                if ! try_existing_docker_runtime_endpoints; then
                    print_warn "No existing Docker-compatible runtime was reachable. Setting up Colima runtime..."
                    ensure_macos_colima_runtime || exit 1
                fi
                ;;
            *)
                print_error "Docker is not installed. Install Docker Engine or Docker Desktop, then rerun this installer."
                exit 1
                ;;
        esac
    fi

    # -----------------------------------------------------------
    # 2. Ensure Docker daemon is running
    # -----------------------------------------------------------
    DOCKER_READY_RC=0
    check_docker_daemon_running || DOCKER_READY_RC=$?
    if [ "$DOCKER_READY_RC" -eq 2 ]; then
        print_error "Docker is installed, but your user cannot access it yet."
        print_warn "Log out and back in once so your docker group membership is applied, then rerun this installer."
        exit 1
    fi

    if [ "$DOCKER_READY_RC" -ne 0 ]; then
        print_warn "Docker daemon is not running"
        if [ "$A0_CLI_SKIP_RUNTIME_SETUP" -eq 1 ]; then
            print_error "Docker daemon is not reachable, and runtime setup was skipped."
            exit 1
        fi
        if start_docker_daemon; then
            if ! wait_for_docker_daemon; then
                print_error "Failed to start Docker daemon. Please start Docker manually and try again."
                exit 1
            fi
        else
            print_error "Please start Docker manually and try again."
            exit 1
        fi
    else
        print_ok "Docker daemon is running"
    fi
}

wait_for_ready() {
    URL="$1"
    MAX_WAIT=300
    WAITED=0

    printf "${GREEN}[INFO]${NC} Launching Agent Zero..."
    while [ "$WAITED" -lt "$MAX_WAIT" ]; do
        HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' "$URL" 2>/dev/null || true)"
        if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 400 ]; then
            printf "\n"
            print_ok "Agent Zero is ready at $URL"
            return 0
        fi
        sleep 1
        WAITED=$((WAITED + 1))
        printf "."
    done
    printf "\n"
    print_warn "Agent Zero did not respond within ${MAX_WAIT} seconds. It may still be starting up."
    return 1
}

# Discover Agent Zero containers using a hybrid approach:
#   1. Containers with the "ai.agent0.managed=true" label (new installs)
#   2. Containers whose Config.Image matches agent0ai/agent-zero (legacy / pre-label)
# Outputs one line per container: Name|Image|Status
# "Image" is the friendly image reference (resolved via Config.Image when docker ps
# shows a raw hash due to the tag having moved to a newer image).
list_agent_zero_containers() {
    local _seen=""

    # --- Pass 1: labeled containers (fast, single docker command) ---
    local _labeled
    _labeled="$("${DOCKER[@]}" ps -a --filter "label=ai.agent0.managed=true" \
        --format '{{.Names}}' 2>/dev/null || true)"

    local _name _cfg_image _status
    if [ -n "$_labeled" ]; then
        while IFS= read -r _name; do
            [ -z "$_name" ] && continue
            _cfg_image="$("${DOCKER[@]}" inspect --format '{{.Config.Image}}' "$_name" 2>/dev/null || true)"
            _status="$("${DOCKER[@]}" ps -a --filter "name=^/${_name}$" --format '{{.Status}}' 2>/dev/null | head -n 1)"
            printf '%s|%s|%s\n' "$_name" "$_cfg_image" "$_status"
            _seen="${_seen}${_name}|"
        done <<< "$_labeled"
    fi

    # --- Pass 2: unlabeled containers whose Config.Image matches (legacy) ---
    local _all_names
    _all_names="$("${DOCKER[@]}" ps -a --format '{{.Names}}' 2>/dev/null || true)"
    if [ -n "$_all_names" ]; then
        while IFS= read -r _name; do
            [ -z "$_name" ] && continue
            # Skip if already found in pass 1
            case "$_seen" in *"${_name}|"*) continue ;; esac
            _cfg_image="$("${DOCKER[@]}" inspect --format '{{.Config.Image}}' "$_name" 2>/dev/null || true)"
            case "$_cfg_image" in
                agent0ai/agent-zero*) ;;
                *) continue ;;
            esac
            _status="$("${DOCKER[@]}" ps -a --filter "name=^/${_name}$" --format '{{.Status}}' 2>/dev/null | head -n 1)"
            printf '%s|%s|%s\n' "$_name" "$_cfg_image" "$_status"
        done <<< "$_all_names"
    fi
}

count_existing_agent_zero_containers() {
    list_agent_zero_containers | awk 'NF {count++} END {print count+0}'
}

instance_name_taken() {
    NAME_TO_CHECK="$1"

    if "${DOCKER[@]}" ps -a --format '{{.Names}}' 2>/dev/null | awk -v target="$NAME_TO_CHECK" '$0 == target {found=1} END {exit found ? 0 : 1}'; then
        return 0
    fi

    return 1
}

suggest_next_instance_name() {
    BASE_NAME="${1:-agent-zero}"
    CANDIDATE_NAME="$BASE_NAME"
    INDEX=2

    while instance_name_taken "$CANDIDATE_NAME"; do
        CANDIDATE_NAME="${BASE_NAME}-${INDEX}"
        INDEX=$((INDEX + 1))
    done

    printf "%s\n" "$CANDIDATE_NAME"
}

open_browser() {
    URL="$1"
    OS_NAME="$(uname -s 2>/dev/null || true)"

    case "$OS_NAME" in
        Darwin)
            if command -v open >/dev/null 2>&1; then
                if open "$URL" >/dev/null 2>&1; then
                    print_ok "Opened browser: $URL"
                else
                    print_warn "Could not open browser automatically. Open this URL manually: $URL"
                fi
            else
                print_warn "open command not found. Open this URL manually: $URL"
            fi
            ;;
        Linux)
            if command -v xdg-open >/dev/null 2>&1; then
                if xdg-open "$URL" >/dev/null 2>&1; then
                    print_ok "Opened browser: $URL"
                else
                    print_warn "Could not open browser automatically. Open this URL manually: $URL"
                fi
            else
                print_warn "xdg-open not found. Open this URL manually: $URL"
            fi
            ;;
        *)
            print_warn "Automatic browser open is not supported on this OS. Open this URL manually: $URL"
            ;;
    esac
}

fetch_available_tags() {
    TAGS_URL="https://registry.hub.docker.com/v2/repositories/agent0ai/agent-zero/tags/?page_size=20&ordering=last_updated"
    RAW_TAGS_JSON="$(curl -fsSL "$TAGS_URL" 2>/dev/null || true)"
    PARSED_TAGS=""

    if [ -z "$RAW_TAGS_JSON" ]; then
        return 1
    fi

    if command -v python3 >/dev/null 2>&1; then
        PARSED_TAGS="$(printf "%s" "$RAW_TAGS_JSON" | python3 -c 'import json,sys
try:
    payload=json.load(sys.stdin)
except Exception:
    sys.exit(1)
seen=set()
for item in payload.get("results", []):
    name=item.get("name")
    if not name or name in seen:
        continue
    seen.add(name)
    print(name)
' 2>/dev/null || true)"
    fi

    if [ -z "$PARSED_TAGS" ]; then
        PARSED_TAGS="$(printf "%s\n" "$RAW_TAGS_JSON" | tr ',' '\n' | sed -n 's/^[[:space:]]*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    fi

    PARSED_TAGS="$(printf "%s\n" "$PARSED_TAGS" | awk 'NF && !seen[$0]++')"

    if [ -z "$PARSED_TAGS" ]; then
        return 1
    fi

    printf "%s\n" "$PARSED_TAGS"
}

fetch_latest_release_tag() {
    RELEASES_URL="https://api.github.com/repos/agent0ai/agent-zero/releases?per_page=100"
    RAW_RELEASES_JSON="$(curl -fsSL "$RELEASES_URL" 2>/dev/null || true)"

    if [ -z "$RAW_RELEASES_JSON" ]; then
        return 1
    fi

    if command -v python3 >/dev/null 2>&1; then
        printf "%s" "$RAW_RELEASES_JSON" | python3 -c 'import json,re,sys
try:
    payload=json.load(sys.stdin)
except Exception:
    sys.exit(1)
for item in payload:
    tag=item.get("tag_name") or ""
    if item.get("draft") or item.get("prerelease"):
        continue
    if re.fullmatch(r"v[0-9]+\.[0-9]+(\.[0-9]+)?", tag):
        print(tag)
        sys.exit(0)
sys.exit(1)
' 2>/dev/null && return 0
    fi

    printf "%s\n" "$RAW_RELEASES_JSON" \
        | tr ',' '\n' \
        | sed -n 's/^[[:space:]]*"tag_name"[[:space:]]*:[[:space:]]*"\(v[0-9][0-9]*\.[0-9][0-9]*\(\.[0-9][0-9]*\)\{0,1\}\)".*/\1/p' \
        | head -n 1
}

default_image_tag() {
    DEFAULT_IMAGE_TAG="$(fetch_latest_release_tag || true)"
    if [ -n "$DEFAULT_IMAGE_TAG" ]; then
        printf "%s\n" "$DEFAULT_IMAGE_TAG"
    else
        printf "latest\n"
    fi
}

select_image_tag() {
    SELECTED_TAG="$(default_image_tag)"
    ALL_TAGS="$(fetch_available_tags || true)"

    if [ -z "$ALL_TAGS" ]; then
        echo "Select version:"
        print_warn "No additional tags found. Using $SELECTED_TAG."
        print_info "Selected version: $SELECTED_TAG"
        echo ""
        return 0
    fi

    # Build ordered tag list:
    #   1. Pinned tags (latest, testing, development) — only if they exist
    #   2. Up to 5 additional tags from newest, excluding pinned ones
    PINNED_TAGS=""
    for PIN_TAG in latest testing development; do
        if printf "%s\n" "$ALL_TAGS" | awk -v tag="$PIN_TAG" '$0 == tag {found=1; exit} END {exit found ? 0 : 1}'; then
            PINNED_TAGS="${PINNED_TAGS:+${PINNED_TAGS}
}${PIN_TAG}"
        fi
    done

    # Get remaining tags (exclude pinned), take first 5 (already sorted newest-first from API)
    OTHER_TAGS="$(printf "%s\n" "$ALL_TAGS" | awk '
        $0 == "latest" || $0 == "testing" || $0 == "development" { next }
        count < 5 { print; count++ }
    ')"

    # Combine pinned + other into final menu list
    MENU_TAGS=""
    if [ -n "$PINNED_TAGS" ]; then
        MENU_TAGS="$PINNED_TAGS"
    fi
    if [ -n "$OTHER_TAGS" ]; then
        MENU_TAGS="${MENU_TAGS:+${MENU_TAGS}
}${OTHER_TAGS}"
    fi

    if [ -z "$MENU_TAGS" ]; then
        echo "Select version:"
        print_warn "No tags found. Using $SELECTED_TAG."
        print_info "Selected version: $SELECTED_TAG"
        echo ""
        return 0
    fi

    if [ -n "$SELECTED_TAG" ] && ! printf "%s\n" "$MENU_TAGS" | awk -v tag="$SELECTED_TAG" '$0 == tag {found=1; exit} END {exit found ? 0 : 1}'; then
        MENU_TAGS="${SELECTED_TAG}
${MENU_TAGS}"
    fi

    # Build menu from the tag list
    # shellcheck disable=SC2086
    _rc=0; SELECTED_INDEX=$(select_from_menu "--header=Select version:" $MENU_TAGS) || _rc=$?
    [ "$_rc" -eq 130 ] && exit 130

    # Handle go-back
    if [ "$SELECTED_INDEX" = "-1" ]; then
        return 1
    fi

    # Extract the selected tag (0-indexed)
    SELECTED_TAG="$(printf "%s\n" "$MENU_TAGS" | awk -v n="$((SELECTED_INDEX + 1))" 'NR == n {print; exit}')"

    if [ -z "$SELECTED_TAG" ]; then
        SELECTED_TAG="latest"
    fi

    print_info "Selected version: $SELECTED_TAG"
    echo ""
}

create_instance() {
    # -----------------------------------------------------------
    # 2. Gather configuration from user (step-based wizard)
    #    Escape (or Ctrl-D) on any step goes back to the previous step.
    #    Escape on the first step aborts create_instance (returns 1).
    # -----------------------------------------------------------
    INSTALL_ROOT="$HOME/agent-zero"

    # Variables populated across wizard steps
    SELECTED_TAG=""
    CONTAINER_NAME=""
    DATA_DIR=""
    PORT=""
    AUTH_LOGIN=""
    AUTH_PASSWORD=""

    # Compute defaults once up front
    DEFAULT_PORT="$(find_free_port 5080)"
    DEFAULT_NAME="$(suggest_next_instance_name "agent-zero")"
    DEFAULT_TAG="$(default_image_tag)"
    QUICK_START=0

    if [ "$A0_CLI_NON_INTERACTIVE" -eq 1 ]; then
        QUICK_START=1
        SELECTED_TAG="${A0_CLI_TAG:-$DEFAULT_TAG}"
        CONTAINER_NAME="${A0_CLI_NAME:-$DEFAULT_NAME}"
        INSTANCE_DIR="$INSTALL_ROOT/$CONTAINER_NAME"
        DATA_DIR="${A0_CLI_DATA_DIR:-$INSTANCE_DIR/usr}"
        DATA_DIR="$(expand_user_path "$DATA_DIR")"
        PORT="${A0_CLI_PORT:-$DEFAULT_PORT}"
        AUTH_LOGIN=""
        AUTH_PASSWORD=""

        if ! validate_port "$PORT"; then
            print_error "Invalid port: $PORT"
            return 1
        fi

        if [ -n "$A0_CLI_NAME" ] && instance_name_taken "$CONTAINER_NAME"; then
            print_error "Instance name '$CONTAINER_NAME' is already taken."
            return 1
        fi

        if [ "$A0_CLI_AUTH_LOGIN_SET" -eq 1 ]; then
            AUTH_LOGIN="$A0_CLI_AUTH_LOGIN"
        fi
        if [ "$A0_CLI_AUTH_PASSWORD_SET" -eq 1 ]; then
            if [ -z "$AUTH_LOGIN" ]; then
                print_error "--auth-password requires --auth-login."
                return 1
            fi
            AUTH_PASSWORD="$A0_CLI_AUTH_PASSWORD"
        elif [ -n "$AUTH_LOGIN" ]; then
            AUTH_PASSWORD="12345678"
        fi

        mkdir -p "$DATA_DIR"
        print_info "Quick Start selected. Using:"
        print_ok "Version:   $SELECTED_TAG"
        print_ok "Instance:  $CONTAINER_NAME"
        print_ok "Port:      $PORT"
        print_ok "Data dir:  $DATA_DIR"
    else
    WIZARD_STEP=0
    while [ "$WIZARD_STEP" -ge 0 ] && [ "$WIZARD_STEP" -le 6 ]; do
        case "$WIZARD_STEP" in
            0)  # Quick Start vs Manual mode selection
                _rc=0
                SELECTED_INDEX=$(select_from_menu \
                    "--header=How would you like to install Agent Zero?" \
                    "Quick Start" \
                    "Manual (Advanced Configuration)") || _rc=$?
                [ "$_rc" -eq 130 ] && exit 130
                if [ "$SELECTED_INDEX" = "-1" ]; then
                    return 1  # Esc on first step — abort
                fi
                if [ "$SELECTED_INDEX" = "0" ]; then
                    # Quick Start: use all defaults, skip to auth
                    QUICK_START=1
                    SELECTED_TAG="$DEFAULT_TAG"
                    CONTAINER_NAME="$DEFAULT_NAME"
                    INSTANCE_DIR="$INSTALL_ROOT/$CONTAINER_NAME"
                    DATA_DIR="$INSTANCE_DIR/usr"
                    PORT="$DEFAULT_PORT"
                    mkdir -p "$DATA_DIR"
                    WIZARD_STEP=5
                else
                    WIZARD_STEP=1
                fi
                ;;

            1)  # Tag / version selection (uses its own full-screen menu)
                if select_image_tag; then
                    WIZARD_STEP=2
                else
                    WIZARD_STEP=0; continue  # Esc — back to mode selection
                fi
                ;;

            2)  # Container / instance name
                clear >/dev/tty 2>&1 || true
                print_banner
                echo ""
                printf "${BOLD}What should this instance be called?${NC} (Esc to go back)\n"
                read_input "$DEFAULT_NAME" || { WIZARD_STEP=1; continue; }
                CONTAINER_NAME="${INPUT_VALUE:-$DEFAULT_NAME}"

                if instance_name_taken "$CONTAINER_NAME"; then
                    SUGGESTED_NAME="$(suggest_next_instance_name "$CONTAINER_NAME")"
                    print_warn "Instance name '$CONTAINER_NAME' is already taken. Using '$SUGGESTED_NAME'."
                    CONTAINER_NAME="$SUGGESTED_NAME"
                fi
                print_info "Instance name: $CONTAINER_NAME"
                WIZARD_STEP=3
                ;;

            3)  # Data directory
                INSTANCE_DIR="$INSTALL_ROOT/$CONTAINER_NAME"
                DEFAULT_DATA_DIR="$INSTANCE_DIR/usr"

                clear >/dev/tty 2>&1 || true
                print_banner
                echo ""
                printf "${BOLD}Where should Agent Zero store user data?${NC} (Esc to go back)\n"
                read_input "$DEFAULT_DATA_DIR" || { WIZARD_STEP=2; continue; }
                DATA_DIR="${INPUT_VALUE:-$DEFAULT_DATA_DIR}"
                DATA_DIR="$(expand_user_path "$DATA_DIR")"
                mkdir -p "$DATA_DIR"
                print_info "Data directory: $DATA_DIR"
                WIZARD_STEP=4
                ;;

            4)  # Port
                clear >/dev/tty 2>&1 || true
                print_banner
                echo ""
                printf "${BOLD}What port should Agent Zero Web UI run on?${NC} (Esc to go back)\n"
                read_input "$DEFAULT_PORT" || { WIZARD_STEP=3; continue; }
                PORT="${INPUT_VALUE:-$DEFAULT_PORT}"
                if ! validate_port "$PORT"; then
                    print_error "Invalid port. Falling back to ${DEFAULT_PORT}."
                    PORT="$DEFAULT_PORT"
                fi
                print_info "Web UI port: $PORT"
                WIZARD_STEP=5
                ;;

            5)  # Auth username
                clear >/dev/tty 2>&1 || true
                print_banner
                echo ""
                if [ "$QUICK_START" = "1" ]; then
                    print_info "Quick Start selected. Using defaults:"
                    print_ok "Version:   $SELECTED_TAG"
                    print_ok "Instance:  $CONTAINER_NAME"
                    print_ok "Port:      $PORT"
                    print_ok "Data dir:  $DATA_DIR"
                    echo ""
                fi
                printf "${BOLD}What login username should be used for the Web UI?${NC} (Esc to go back)\n"
                printf "Leave empty for no authentication:\n"
                read_input "" || { [ "$QUICK_START" = "1" ] && WIZARD_STEP=0 || WIZARD_STEP=4; continue; }
                AUTH_LOGIN="$INPUT_VALUE"
                AUTH_PASSWORD=""
                if [ -n "$AUTH_LOGIN" ]; then
                    WIZARD_STEP=6
                else
                    print_warn "No authentication will be configured."
                    WIZARD_STEP=7  # Done gathering input
                fi
                ;;

            6)  # Auth password (only reached if username was provided)
                clear >/dev/tty 2>&1 || true
                print_banner
                echo ""
                printf "${BOLD}What password should be used?${NC} (Esc to go back)\n"
                read_input "12345678" || { WIZARD_STEP=5; continue; }
                AUTH_PASSWORD="${INPUT_VALUE:-12345678}"
                print_info "Auth configured for user: $AUTH_LOGIN"
                WIZARD_STEP=7  # Done gathering input
                ;;
        esac
    done
    fi

    echo ""
    print_info "Configuration complete. Setting up Agent Zero..."
    echo ""

    # -----------------------------------------------------------
    # 3. Pull image & start container
    # -----------------------------------------------------------
    mkdir -p "$INSTANCE_DIR"

    local IMAGE="agent0ai/agent-zero:$SELECTED_TAG"

    print_info "Pulling Agent Zero image (this may take a moment)..."
    "${DOCKER[@]}" pull --quiet "$IMAGE"

    print_info "Starting Agent Zero..."
    local DOCKER_RUN_ARGS=(
        --name "$CONTAINER_NAME"
        --label "ai.agent0.managed=true"
        --restart unless-stopped
        -p "${PORT}:80"
        -v "${DATA_DIR}:/a0/usr"
        -d
    )
    if [ -n "$AUTH_LOGIN" ]; then
        DOCKER_RUN_ARGS+=(-e "AUTH_LOGIN=${AUTH_LOGIN}" -e "AUTH_PASSWORD=${AUTH_PASSWORD}")
    fi
    "${DOCKER[@]}" run "${DOCKER_RUN_ARGS[@]}" "$IMAGE"

    # -----------------------------------------------------------
    # 4. Wait for the service to become ready
    # -----------------------------------------------------------
    wait_for_ready "http://localhost:$PORT"

    # Store the created container name for the caller
    CREATED_CONTAINER_NAME="$CONTAINER_NAME"
}

manage_instances() {
    while :; do
        CONTAINER_ROWS="$(list_agent_zero_containers)"

        if [ -z "$CONTAINER_ROWS" ]; then
            print_warn "No Agent Zero containers found to manage."
            return 0
        fi

        # Build menu by manually rendering and handling arrow keys inline
        ITEM_COUNT=$(printf "%s\n" "$CONTAINER_ROWS" | awk 'END {print NR}')
        SELECTED_INDEX=0

        while :; do
            # Clear screen
            clear >/dev/tty 2>&1 || true
            print_banner >/dev/tty

            # Display header
            echo "Select existing instance:" >/dev/tty
            echo "" >/dev/tty

            # Render menu items
            printf "%s\n" "$CONTAINER_ROWS" | awk -F'|' -v sel="$SELECTED_INDEX" '
            {
                tag=$2
                if (index($2, ":") > 0) {
                    sub(/^.*:/, "", tag)
                } else {
                    tag="latest"
                }
                option = sprintf("%s [tag: %s] [status: %s]", $1, tag, $3)
                if (NR - 1 == sel) {
                    printf "  \033[0;32m> %s\033[0m\n", option
                } else {
                    printf "    %s\n", option
                }
            }' >/dev/tty

            # Show help text
            echo "" >/dev/tty
            printf "Use ↑/↓ to navigate, Enter to select, Esc to go back, Ctrl+C to exit\n" >/dev/tty

            # Read single character from terminal
            IFS= read -rsn1 key </dev/tty

            # Handle Enter key
            if [ -z "$key" ] || [ "$key" = $'\n' ]; then
                break
            fi

            # Handle Backspace key (go back)
            if [ "$key" = $'\x7f' ] || [ "$key" = $'\x08' ]; then
                return 0
            fi

            # Handle escape sequences (arrow keys) and bare Escape (go back)
            if [ "$key" = $'\x1b' ]; then
                read_byte_with_short_timeout || true; key2="$_TIMED_KEY"
                if [ "$key2" = "[" ]; then
                    IFS= read -rsn1 key3 </dev/tty
                    case "$key3" in
                        A) # Up arrow
                            SELECTED_INDEX=$((SELECTED_INDEX - 1))
                            if [ "$SELECTED_INDEX" -lt 0 ]; then
                                SELECTED_INDEX=$((ITEM_COUNT - 1))
                            fi
                            ;;
                        B) # Down arrow
                            SELECTED_INDEX=$((SELECTED_INDEX + 1))
                            if [ "$SELECTED_INDEX" -ge "$ITEM_COUNT" ]; then
                                SELECTED_INDEX=0
                            fi
                            ;;
                    esac
                else
                    # Bare Escape pressed — go back to main menu
                    return 0
                fi
            fi
        done

        # Extract container details using selected index
        SELECTED_ROW="$(printf "%s\n" "$CONTAINER_ROWS" | awk -v n="$((SELECTED_INDEX + 1))" 'NR == n {print; exit}')"
        SELECTED_NAME="$(printf "%s\n" "$SELECTED_ROW" | cut -d'|' -f1)"
        SELECTED_IMAGE="$(printf "%s\n" "$SELECTED_ROW" | cut -d'|' -f2)"
        SELECTED_STATUS="$(printf "%s\n" "$SELECTED_ROW" | cut -d'|' -f3-)"

        manage_single_instance "$SELECTED_NAME"
    done
}

# Show the action menu for a single container (open, start, stop, restart, delete).
# Can be called from manage_instances or directly after create_instance.
manage_single_instance() {
    SELECTED_NAME="$1"

    # Look up the image for display (Config.Image preserves the original tag even when the image is untagged)
    SELECTED_IMAGE="$("${DOCKER[@]}" inspect --format '{{.Config.Image}}' "$SELECTED_NAME" 2>/dev/null || true)"

    while :; do
        SELECTED_STATUS="$("${DOCKER[@]}" ps -a --filter "name=^/${SELECTED_NAME}$" --format '{{.Status}}' 2>/dev/null | head -n 1)"

        # If container no longer exists (e.g. after delete), return
        if [ -z "$SELECTED_STATUS" ]; then
            break
        fi

        case "$SELECTED_STATUS" in
            Up*) IS_RUNNING=1 ;;
            *) IS_RUNNING=0 ;;
        esac

        INSTANCE_HEADER="Selected: $SELECTED_NAME ($SELECTED_IMAGE, $SELECTED_STATUS)"

        if [ "$IS_RUNNING" -eq 1 ]; then
            _rc=0; ACTION_INDEX=$(select_from_menu "--header=$INSTANCE_HEADER" "Open in browser" "Restart" "Stop" "Delete" "Back") || _rc=$?
            [ "$_rc" -eq 130 ] && exit 130
            case "$ACTION_INDEX" in
                -1) ACTION_KEY="back" ;;  # Escape/Backspace — go back
                0) ACTION_KEY="open" ;;
                1) ACTION_KEY="restart" ;;
                2) ACTION_KEY="stop" ;;
                3) ACTION_KEY="delete" ;;
                4) ACTION_KEY="back" ;;
                *) ACTION_KEY="invalid" ;;
            esac
        else
            _rc=0; ACTION_INDEX=$(select_from_menu "--header=$INSTANCE_HEADER" "Start" "Delete" "Back") || _rc=$?
            [ "$_rc" -eq 130 ] && exit 130
            case "$ACTION_INDEX" in
                -1) ACTION_KEY="back" ;;  # Escape/Backspace — go back
                0) ACTION_KEY="start" ;;
                1) ACTION_KEY="delete" ;;
                2) ACTION_KEY="back" ;;
                *) ACTION_KEY="invalid" ;;
            esac
        fi

        case "$ACTION_KEY" in
            open)
                PORT_OUTPUT="$("${DOCKER[@]}" port "$SELECTED_NAME" 80/tcp 2>/dev/null || true)"
                HOST_PORT="$(printf "%s\n" "$PORT_OUTPUT" | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p' | head -n 1)"

                if [ -z "$HOST_PORT" ]; then
                    print_warn "Could not resolve a host port for '$SELECTED_NAME' on 80/tcp. Ensure it is running with a published port."
                else
                    TARGET_URL="http://localhost:$HOST_PORT"
                    print_info "Opening $TARGET_URL"
                    open_browser "$TARGET_URL"
                fi
                wait_for_keypress
                ;;
            start)
                print_info "Starting '$SELECTED_NAME'..."
                START_OUTPUT="$("${DOCKER[@]}" start "$SELECTED_NAME" 2>&1)" || true
                if "${DOCKER[@]}" ps --filter "name=^/${SELECTED_NAME}$" --filter "status=running" --format '{{.Names}}' 2>/dev/null | grep -q "^${SELECTED_NAME}$"; then
                    print_ok "Started '$SELECTED_NAME'."
                else
                    print_error "Failed to start '$SELECTED_NAME'."
                    if [ -n "$START_OUTPUT" ]; then
                        printf "  %s\n" "$START_OUTPUT"
                    fi
                fi
                wait_for_keypress
                ;;
            stop)
                print_info "Stopping '$SELECTED_NAME'..."
                if "${DOCKER[@]}" stop "$SELECTED_NAME" >/dev/null 2>&1; then
                    print_ok "Stopped '$SELECTED_NAME'."
                else
                    print_error "Failed to stop '$SELECTED_NAME'."
                fi
                wait_for_keypress
                ;;
            restart)
                print_info "Restarting '$SELECTED_NAME'..."
                RESTART_OUTPUT="$("${DOCKER[@]}" restart "$SELECTED_NAME" 2>&1)" || true
                if "${DOCKER[@]}" ps --filter "name=^/${SELECTED_NAME}$" --filter "status=running" --format '{{.Names}}' 2>/dev/null | grep -q "^${SELECTED_NAME}$"; then
                    print_ok "Restarted '$SELECTED_NAME'."
                else
                    print_error "Failed to restart '$SELECTED_NAME'."
                    if [ -n "$RESTART_OUTPUT" ]; then
                        printf "  %s\n" "$RESTART_OUTPUT"
                    fi
                fi
                wait_for_keypress
                ;;
            delete)
                printf "Are you sure you want to delete '%s'? [y/N]: " "$SELECTED_NAME"
                IFS= read -rsn1 CONFIRM </dev/tty
                printf "\n"
                if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
                    # Stop first if running
                    "${DOCKER[@]}" stop "$SELECTED_NAME" >/dev/null 2>&1 || true
                    if "${DOCKER[@]}" rm "$SELECTED_NAME" >/dev/null 2>&1; then
                        print_ok "Deleted '$SELECTED_NAME'."
                    else
                        print_error "Failed to delete '$SELECTED_NAME'."
                    fi
                    wait_for_keypress
                    break  # Container no longer exists
                else
                    print_info "Delete cancelled."
                    wait_for_keypress
                fi
                ;;
            back)
                break
                ;;
            *)
                print_warn "Invalid action. Please try again."
                wait_for_keypress
                ;;
        esac
    done
}

main_menu_for_existing() {
    while :; do
        # Re-count containers each iteration (may change after delete/create)
        MENU_COUNT="$(count_existing_agent_zero_containers)"
        case "$MENU_COUNT" in
            ''|*[!0-9]*) MENU_COUNT="0" ;;
        esac

        if [ "$MENU_COUNT" -gt 0 ]; then
            HEADER="Detected ${MENU_COUNT} Agent Zero container(s). What would you like to do?"
            _rc=0; SELECTED_INDEX=$(select_from_menu "--header=$HEADER" "Install new instance" "Manage existing instances" "Exit") || _rc=$?
            [ "$_rc" -eq 130 ] && exit 130

            case "$SELECTED_INDEX" in
                -1) exit 0 ;;    # Escape/Backspace — exit
                0)
                    CREATED_CONTAINER_NAME=""
                    if create_instance; then
                        manage_single_instance "$CREATED_CONTAINER_NAME"
                    fi
                    # Escape pressed during create or back from detail — loop back to menu
                    ;;
                1) manage_instances ;;  # loops back to this menu after returning
                2) exit 0 ;;     # Exit option
                *) exit 0 ;;
            esac
        else
            # All containers were deleted — go straight to install
            CREATED_CONTAINER_NAME=""
            if ! create_instance; then
                exit 0
            fi
            manage_single_instance "$CREATED_CONTAINER_NAME"
        fi
    done
}

main() {
    check_docker
    echo ""

    if [ "$A0_CLI_NON_INTERACTIVE" -eq 1 ]; then
        CREATED_CONTAINER_NAME=""
        create_instance
        return
    fi

    EXISTING_COUNT="$(count_existing_agent_zero_containers)"
    case "$EXISTING_COUNT" in
        ''|*[!0-9]*) EXISTING_COUNT="0" ;;
    esac

    if [ "$EXISTING_COUNT" -gt 0 ]; then
        main_menu_for_existing
    else
        # No existing containers — go straight to install.
        # If Escape pressed during create, exit gracefully.
        CREATED_CONTAINER_NAME=""
        if ! create_instance; then
            exit 0
        fi
        manage_single_instance "$CREATED_CONTAINER_NAME"
        # After returning from manage (Esc/back), enter the main menu loop.
        # There is now at least 1 container so the user gets a proper menu
        # instead of the script silently exiting.
        main_menu_for_existing
    fi
}

parse_args "$@"
print_banner
main
