#!/usr/bin/env bash
# helpers.sh — Queue ops, locking, option reading, OS detection

HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=variables.sh
source "${HELPERS_DIR}/variables.sh"

# --- Path accessors (derive from QUEUE_DIR so tests can override it) ---

_queue_file()  { echo "${QUEUE_DIR}/queue"; }
_lock_file()   { echo "${QUEUE_DIR}/lock"; }
_active_file() { echo "${QUEUE_DIR}/active"; }
_pid_file()    { echo "${QUEUE_DIR}/popup-pid"; }
_debug_log()   { echo "${QUEUE_DIR}/debug.log"; }

# --- OS Detection ---

get_os() {
    case "$(uname -s)" in
        Linux*)  echo "linux" ;;
        Darwin*) echo "macos" ;;
        *)       echo "unknown" ;;
    esac
}

is_wsl() {
    [[ -f /proc/version ]] && grep -qi microsoft /proc/version
}

# --- Option Reading ---

get_option() {
    local option="$1"
    local default="$2"
    local value
    value=$(tmux show-option -gqv "$option" 2>/dev/null)
    if [[ -n "$value" ]]; then
        echo "$value"
    else
        echo "$default"
    fi
}

set_default_option() {
    local option="$1"
    local default="$2"
    local current
    current=$(tmux show-option -gqv "$option" 2>/dev/null)
    if [[ -z "$current" ]]; then
        tmux set-option -g "$option" "$default"
    fi
}

is_enabled() {
    local val
    val=$(get_option "$OPTION_ENABLED" "$DEFAULT_ENABLED")
    [[ "$val" == "on" ]]
}

# --- Debug Logging ---

log_debug() {
    local debug_on
    debug_on=$(get_option "$OPTION_DEBUG" "$DEFAULT_DEBUG")
    if [[ "$debug_on" == "on" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$(_debug_log)"
    fi
}

# --- Locking (portable) ---

_supports_flock() {
    command -v flock &>/dev/null
}

acquire_lock() {
    local lock_path="${1:-$(_lock_file)}"
    if _supports_flock; then
        exec 9>"$lock_path"
        flock -x 9
    else
        # mkdir-based lock for macOS
        local max_wait=50  # 5 seconds max
        local i=0
        while ! mkdir "$lock_path.d" 2>/dev/null; do
            ((i++))
            if ((i >= max_wait)); then
                rm -rf "$lock_path.d"
                mkdir "$lock_path.d" 2>/dev/null || return 1
                break
            fi
            sleep 0.1
        done
    fi
}

release_lock() {
    local lock_path="${1:-$(_lock_file)}"
    if _supports_flock; then
        exec 9>&-
    else
        rm -rf "$lock_path.d"
    fi
}

# --- Queue Directory ---

ensure_queue_dir() {
    if [[ ! -d "$QUEUE_DIR" ]]; then
        mkdir -p "$QUEUE_DIR"
        chmod 700 "$QUEUE_DIR"
    fi
}

# --- Queue Operations ---
# Format: timestamp|pane_id|event_type|session_id|message

queue_push() {
    local pane_id="$1"
    local event_type="$2"
    local session_id="$3"
    local message="$4"
    local timestamp
    timestamp=$(date +%s)

    ensure_queue_dir
    acquire_lock
    echo "${timestamp}|${pane_id}|${event_type}|${session_id}|${message}" >> "$(_queue_file)"
    release_lock
    log_debug "queue_push: pane=$pane_id type=$event_type session=$session_id"
}

queue_pop() {
    local qf
    qf="$(_queue_file)"
    ensure_queue_dir
    acquire_lock

    if [[ ! -f "$qf" ]] || [[ ! -s "$qf" ]]; then
        release_lock
        return 1
    fi

    local first_line
    first_line=$(head -1 "$qf")
    local tmp="${qf}.tmp"
    tail -n +2 "$qf" > "$tmp"
    mv "$tmp" "$qf"

    release_lock
    echo "$first_line"
}

queue_peek() {
    local qf
    qf="$(_queue_file)"
    ensure_queue_dir
    acquire_lock

    if [[ ! -f "$qf" ]] || [[ ! -s "$qf" ]]; then
        release_lock
        return 1
    fi

    head -1 "$qf"
    release_lock
}

queue_is_empty() {
    local qf
    qf="$(_queue_file)"
    ensure_queue_dir
    acquire_lock

    if [[ ! -f "$qf" ]] || [[ ! -s "$qf" ]]; then
        release_lock
        return 0  # empty
    fi

    release_lock
    return 1  # not empty
}

queue_count() {
    local qf
    qf="$(_queue_file)"
    ensure_queue_dir
    acquire_lock

    if [[ ! -f "$qf" ]] || [[ ! -s "$qf" ]]; then
        release_lock
        echo "0"
        return
    fi

    wc -l < "$qf" | tr -d ' '
    release_lock
}

clean_stale_entries() {
    local qf
    qf="$(_queue_file)"
    ensure_queue_dir
    acquire_lock

    if [[ ! -f "$qf" ]] || [[ ! -s "$qf" ]]; then
        release_lock
        return
    fi

    local stale_ttl
    stale_ttl=$(get_option "$OPTION_STALE_TTL" "$DEFAULT_STALE_TTL")
    local now
    now=$(date +%s)
    local tmp="${qf}.tmp"

    while IFS= read -r line; do
        local ts pane_id
        ts=$(echo "$line" | cut -d'|' -f1)
        pane_id=$(echo "$line" | cut -d'|' -f2)

        # Skip if expired
        if (( now - ts > stale_ttl )); then
            log_debug "clean_stale: expired entry ts=$ts pane=$pane_id"
            continue
        fi

        # Skip if pane is dead
        if ! tmux has-session -t "$pane_id" 2>/dev/null && \
           ! tmux display-message -t "$pane_id" -p '#{pane_id}' 2>/dev/null >/dev/null; then
            log_debug "clean_stale: dead pane $pane_id"
            continue
        fi

        echo "$line"
    done < "$qf" > "$tmp"

    mv "$tmp" "$qf"
    release_lock
}

# --- Active Popup Tracking ---

set_active_pane() {
    local pane_id="$1"
    ensure_queue_dir
    echo "$pane_id" > "$(_active_file)"
}

get_active_pane() {
    local af
    af="$(_active_file)"
    if [[ -f "$af" ]]; then
        cat "$af"
    fi
}

clear_active_pane() {
    > "$(_active_file)" 2>/dev/null
}

# --- Popup Manager PID ---

is_popup_manager_running() {
    local pf
    pf="$(_pid_file)"
    if [[ -f "$pf" ]]; then
        local pid
        pid=$(cat "$pf")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        else
            rm -f "$pf"
            return 1
        fi
    fi
    return 1
}

set_popup_manager_pid() {
    echo "$1" > "$(_pid_file)"
}

clear_popup_manager_pid() {
    rm -f "$(_pid_file)"
}

# --- Queue Field Parsing ---

parse_field() {
    local line="$1"
    local field="$2"  # 1-based
    echo "$line" | cut -d'|' -f"$field"
}

parse_timestamp() { parse_field "$1" 1; }
parse_pane_id()   { parse_field "$1" 2; }
parse_event_type(){ parse_field "$1" 3; }
parse_session_id(){ parse_field "$1" 4; }
parse_message()   { parse_field "$1" 5; }
