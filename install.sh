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

print_banner

print_ok()    { printf "  ${GREEN}✔${NC} %s\n" "$1"; }
print_info()  { printf "${GREEN}[INFO]${NC} %s\n" "$1"; }
print_warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
print_error() { printf "${RED}[ERROR]${NC} %s\n" "$1"; }

# Detect whether bash supports fractional read timeouts (bash 4+ does, bash 3.2 on macOS does not).
HAS_FRACTIONAL_TIMEOUT=0
if (IFS= read -r -n 1 -t 0.1 _probe <<< "x") 2>/dev/null; then
    HAS_FRACTIONAL_TIMEOUT=1
fi

# Save original tty settings and restore them on exit.
# This ensures the terminal is never left in a broken state (e.g. no echo)
# if the script is interrupted or exits while stty is modified.
_ORIGINAL_TTY_SETTINGS="$(stty -g </dev/tty 2>/dev/null || true)"
restore_tty() {
    if [ -n "$_ORIGINAL_TTY_SETTINGS" ]; then
        stty "$_ORIGINAL_TTY_SETTINGS" </dev/tty 2>/dev/null || true
    else
        stty sane </dev/tty 2>/dev/null || true
    fi
}
trap restore_tty EXIT
trap 'restore_tty; exit 130' INT
trap 'restore_tty; exit 143' TERM HUP

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
    DOCKER_PORTS="$(docker ps -a --format '{{.Ports}}' 2>/dev/null || true)"
    if [ -n "$DOCKER_PORTS" ]; then
        if printf "%s\n" "$DOCKER_PORTS" | grep -qE "(^|[ ,])0\.0\.0\.0:${CHECK_PORT}->" 2>/dev/null; then
            return 0
        fi
        if printf "%s\n" "$DOCKER_PORTS" | grep -qE "(^|[ ,]):::${CHECK_PORT}->" 2>/dev/null; then
            return 0
        fi
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
        clear >/dev/tty 2>&1
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

check_docker_daemon_running() {
    if docker info >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

start_docker_daemon() {
    OS_NAME="$(uname -s 2>/dev/null || true)"

    case "$OS_NAME" in
        Darwin)
            print_info "Starting Docker Desktop..."
            if command -v open >/dev/null 2>&1; then
                open -a Docker
                return 0
            else
                print_error "Cannot start Docker Desktop automatically."
                return 1
            fi
            ;;
        Linux)
            print_info "Starting Docker daemon..."
            # Try systemctl first
            if command -v systemctl >/dev/null 2>&1; then
                if sudo systemctl start docker >/dev/null 2>&1; then
                    return 0
                fi
            fi
            # Fallback to service command
            if command -v service >/dev/null 2>&1; then
                if sudo service docker start >/dev/null 2>&1; then
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
    MAX_WAIT=30
    WAITED=0

    print_info "Waiting for Docker daemon to be ready..."
    while [ $WAITED -lt $MAX_WAIT ]; do
        if docker info >/dev/null 2>&1; then
            print_ok "Docker daemon is ready"
            return 0
        fi
        sleep 1
        WAITED=$((WAITED + 1))
        printf "."
    done
    echo ""
    print_error "Docker daemon did not become ready within ${MAX_WAIT} seconds."
    return 1
}

check_docker() {
    # -----------------------------------------------------------
    # 1. Ensure Docker is installed
    # -----------------------------------------------------------
    if command -v docker > /dev/null 2>&1; then
        print_ok "Docker already installed"
    else
        print_warn "Docker not found. Installing via https://get.docker.com ..."
        curl -fsSL https://get.docker.com | sh

        if [ "$(uname -s 2>/dev/null)" = "Linux" ] && [ "$(id -u 2>/dev/null)" -ne 0 ]; then
            print_info "Adding current user to the docker group..."
            sudo usermod -aG docker "$USER"
            print_warn "You may need to log out and back in for group changes to take effect."
        fi
    fi

    # -----------------------------------------------------------
    # 2. Ensure Docker daemon is running
    # -----------------------------------------------------------
    if ! check_docker_daemon_running; then
        print_warn "Docker daemon is not running"
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
    MAX_WAIT=60
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
    _labeled="$(docker ps -a --filter "label=ai.agent0.managed=true" \
        --format '{{.Names}}' 2>/dev/null || true)"

    local _name _cfg_image _status
    if [ -n "$_labeled" ]; then
        while IFS= read -r _name; do
            [ -z "$_name" ] && continue
            _cfg_image="$(docker inspect --format '{{.Config.Image}}' "$_name" 2>/dev/null || true)"
            _status="$(docker ps -a --filter "name=^/${_name}$" --format '{{.Status}}' 2>/dev/null | head -n 1)"
            printf '%s|%s|%s\n' "$_name" "$_cfg_image" "$_status"
            _seen="${_seen}${_name}|"
        done <<< "$_labeled"
    fi

    # --- Pass 2: unlabeled containers whose Config.Image matches (legacy) ---
    local _all_names
    _all_names="$(docker ps -a --format '{{.Names}}' 2>/dev/null || true)"
    if [ -n "$_all_names" ]; then
        while IFS= read -r _name; do
            [ -z "$_name" ] && continue
            # Skip if already found in pass 1
            case "$_seen" in *"${_name}|"*) continue ;; esac
            _cfg_image="$(docker inspect --format '{{.Config.Image}}' "$_name" 2>/dev/null || true)"
            case "$_cfg_image" in
                agent0ai/agent-zero*) ;;
                *) continue ;;
            esac
            _status="$(docker ps -a --filter "name=^/${_name}$" --format '{{.Status}}' 2>/dev/null | head -n 1)"
            printf '%s|%s|%s\n' "$_name" "$_cfg_image" "$_status"
        done <<< "$_all_names"
    fi
}

count_existing_agent_zero_containers() {
    list_agent_zero_containers | awk 'NF {count++} END {print count+0}'
}

instance_name_taken() {
    NAME_TO_CHECK="$1"

    if docker ps -a --format '{{.Names}}' 2>/dev/null | awk -v target="$NAME_TO_CHECK" '$0 == target {found=1} END {exit found ? 0 : 1}'; then
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

select_image_tag() {
    SELECTED_TAG="latest"
    ALL_TAGS="$(fetch_available_tags || true)"

    if [ -z "$ALL_TAGS" ]; then
        echo "Select version:"
        print_warn "No additional tags found. Using latest."
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
        print_warn "No tags found. Using latest."
        print_info "Selected version: $SELECTED_TAG"
        echo ""
        return 0
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
    INSTALL_ROOT="$HOME/.agent-zero"

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

    WIZARD_STEP=1
    while [ "$WIZARD_STEP" -ge 1 ] && [ "$WIZARD_STEP" -le 6 ]; do
        case "$WIZARD_STEP" in
            1)  # Tag / version selection (uses its own full-screen menu)
                if select_image_tag; then
                    WIZARD_STEP=2
                else
                    return 1  # Esc on first step — abort
                fi
                ;;

            2)  # Container / instance name
                clear
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

                clear
                print_banner
                echo ""
                printf "${BOLD}Where should Agent Zero store user data?${NC} (Esc to go back)\n"
                read_input "$DEFAULT_DATA_DIR" || { WIZARD_STEP=2; continue; }
                DATA_DIR="${INPUT_VALUE:-$DEFAULT_DATA_DIR}"
                case "$DATA_DIR" in
                    ~/*) DATA_DIR="$HOME/${DATA_DIR#~/}" ;;
                    ~) DATA_DIR="$HOME" ;;
                esac
                mkdir -p "$DATA_DIR"
                print_info "Data directory: $DATA_DIR"
                WIZARD_STEP=4
                ;;

            4)  # Port
                clear
                print_banner
                echo ""
                printf "${BOLD}What port should Agent Zero Web UI run on?${NC} (Esc to go back)\n"
                read_input "$DEFAULT_PORT" || { WIZARD_STEP=3; continue; }
                PORT="${INPUT_VALUE:-$DEFAULT_PORT}"
                case "$PORT" in
                    ''|*[!0-9]*)
                    print_error "Invalid port. Falling back to ${DEFAULT_PORT}."
                    PORT="$DEFAULT_PORT"
                    ;;
                esac
                print_info "Web UI port: $PORT"
                WIZARD_STEP=5
                ;;

            5)  # Auth username
                clear
                print_banner
                echo ""
                printf "${BOLD}What login username should be used for the Web UI?${NC} (Esc to go back)\n"
                printf "Leave empty for no authentication:\n"
                read_input "" || { WIZARD_STEP=4; continue; }
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
                clear
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

    echo ""
    print_info "Configuration complete. Setting up Agent Zero..."
    echo ""

    # -----------------------------------------------------------
    # 3. Pull image & start container
    # -----------------------------------------------------------
    mkdir -p "$INSTANCE_DIR"

    local IMAGE="agent0ai/agent-zero:$SELECTED_TAG"

    print_info "Pulling Agent Zero image (this may take a moment)..."
    docker pull --quiet "$IMAGE"

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
    docker run "${DOCKER_RUN_ARGS[@]}" "$IMAGE"

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
            clear
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
                read_byte_with_short_timeout; key2="$_TIMED_KEY"
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
    SELECTED_IMAGE="$(docker inspect --format '{{.Config.Image}}' "$SELECTED_NAME" 2>/dev/null || true)"

    while :; do
        SELECTED_STATUS="$(docker ps -a --filter "name=^/${SELECTED_NAME}$" --format '{{.Status}}' 2>/dev/null | head -n 1)"

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
                PORT_OUTPUT="$(docker port "$SELECTED_NAME" 80/tcp 2>/dev/null || true)"
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
                START_OUTPUT="$(docker start "$SELECTED_NAME" 2>&1)" || true
                if docker ps --filter "name=^/${SELECTED_NAME}$" --filter "status=running" --format '{{.Names}}' 2>/dev/null | grep -q "^${SELECTED_NAME}$"; then
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
                if docker stop "$SELECTED_NAME" >/dev/null 2>&1; then
                    print_ok "Stopped '$SELECTED_NAME'."
                else
                    print_error "Failed to stop '$SELECTED_NAME'."
                fi
                wait_for_keypress
                ;;
            restart)
                print_info "Restarting '$SELECTED_NAME'..."
                RESTART_OUTPUT="$(docker restart "$SELECTED_NAME" 2>&1)" || true
                if docker ps --filter "name=^/${SELECTED_NAME}$" --filter "status=running" --format '{{.Names}}' 2>/dev/null | grep -q "^${SELECTED_NAME}$"; then
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
                    docker stop "$SELECTED_NAME" >/dev/null 2>&1 || true
                    if docker rm "$SELECTED_NAME" >/dev/null 2>&1; then
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

main "$@"