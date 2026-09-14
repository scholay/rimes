#!/bin/bash
# Install or remove the tiny login bootstrap that keeps RIMES's companion
# windows available when another input source is selected. The launchd job is
# not a resident helper: RunAtLoad invokes `open -g` once, then exits. The app's
# existing process owns the Carbon shortcuts and every UI surface.
set -u

MODE="${1:-}"
SYSTEM_LABEL="com.scholay.rimes.companion-start"
USER_LABEL="com.scholay.rimes.dev-companion-start"
SYSTEM_APP="/Library/Input Methods/RIMES.app"
USER_APP="$HOME/Library/Input Methods/RIMES.app"
SYSTEM_AGENT_DIR="/Library/LaunchAgents"
USER_AGENT_DIR="$HOME/Library/LaunchAgents"
TEST_ROOT="${RIMES_COMPANION_TEST_ROOT:-}"
SYSTEM_GUARD='if [ -e "$HOME/Library/Input Methods/RIMES.app" ] || [ -L "$HOME/Library/Input Methods/RIMES.app" ] || [ -e "$HOME/Library/LaunchAgents/com.scholay.rimes.dev-companion-start.plist" ] || [ -L "$HOME/Library/LaunchAgents/com.scholay.rimes.dev-companion-start.plist" ]; then exit 0; fi; exec /usr/bin/open -g "/Library/Input Methods/RIMES.app"'
temporary=""
backup=""
audit_list=""

cleanup() {
    [ -z "$temporary" ] || /bin/rm -f "$temporary"
    [ -z "$backup" ] || /bin/rm -f "$backup"
    [ -z "$audit_list" ] || /bin/rm -f "$audit_list"
}
trap cleanup EXIT

verify_agent() {
    local agent="$1"
    local label="$2"
    local app="$3"
    local owner_kind="$4"

    [ -f "$agent" ] && [ ! -L "$agent" ] \
        && /usr/bin/plutil -lint "$agent" >/dev/null \
        && [ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$agent" 2>/dev/null)" = "$label" ] \
        && [ "$(/usr/libexec/PlistBuddy -c 'Print :RunAtLoad' "$agent" 2>/dev/null)" = "true" ] \
        && [ "$(/usr/libexec/PlistBuddy -c 'Print :LimitLoadToSessionType' "$agent" 2>/dev/null)" = "Aqua" ] \
        && [ "$(/usr/libexec/PlistBuddy -c 'Print :ProcessType' "$agent" 2>/dev/null)" = "Background" ] \
        && [ "$(/usr/libexec/PlistBuddy -c 'Print :AssociatedBundleIdentifiers:0' "$agent" 2>/dev/null)" = "com.scholay.inputmethod.isaac" ] \
        && ! /usr/libexec/PlistBuddy -c 'Print :KeepAlive' "$agent" >/dev/null 2>&1 \
        || return 1

    if [ "$owner_kind" = "system" ]; then
        [ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$agent" 2>/dev/null)" = "/bin/sh" ] \
            && [ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "$agent" 2>/dev/null)" = "-c" ] \
            && [ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:2' "$agent" 2>/dev/null)" = "$SYSTEM_GUARD" ]
    else
        [ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$agent" 2>/dev/null)" = "/usr/bin/open" ] \
            && [ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "$agent" 2>/dev/null)" = "-g" ] \
            && [ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:2' "$agent" 2>/dev/null)" = "$app" ]
    fi
}

write_agent() {
    local agent_dir="$1"
    local agent="$2"
    local label="$3"
    local app="$4"
    local physical_app="$5"
    local owner_kind="$6"

    [ -d "$physical_app" ] && [ ! -L "$physical_app" ] \
        && [ -x "$physical_app/Contents/MacOS/RIMES" ] || {
        echo "RIMES companion: canonical app is unavailable: $physical_app" >&2
        return 1
    }
    if [ -L "$agent_dir" ] || [ -L "$agent" ]; then
        echo "RIMES companion: refusing a symlinked LaunchAgent path" >&2
        return 1
    fi
    /bin/mkdir -p "$agent_dir" || return 1
    [ -d "$agent_dir" ] && [ ! -L "$agent_dir" ] || return 1

    temporary="$(/usr/bin/mktemp "$agent_dir/.rimes-companion.XXXXXX")" \
        || return 1
    /usr/bin/plutil -create xml1 "$temporary" || return 1
    /usr/libexec/PlistBuddy -c "Add :Label string $label" "$temporary" \
        || return 1
    /usr/libexec/PlistBuddy -c 'Add :ProgramArguments array' "$temporary" \
        || return 1
    if [ "$owner_kind" = "system" ]; then
        /usr/libexec/PlistBuddy \
            -c 'Add :ProgramArguments:0 string /bin/sh' "$temporary" \
            || return 1
        /usr/libexec/PlistBuddy \
            -c 'Add :ProgramArguments:1 string -c' "$temporary" \
            || return 1
        # PlistBuddy strips quote characters from string values. plutil keeps
        # the fixed shell guard byte-for-byte, including the quotes protecting
        # HOME paths and the Input Methods space.
        /usr/bin/plutil -insert ProgramArguments.2 \
            -string "$SYSTEM_GUARD" "$temporary" \
            || return 1
    else
        /usr/libexec/PlistBuddy \
            -c 'Add :ProgramArguments:0 string /usr/bin/open' "$temporary" \
            || return 1
        /usr/libexec/PlistBuddy \
            -c 'Add :ProgramArguments:1 string -g' "$temporary" \
            || return 1
        /usr/libexec/PlistBuddy \
            -c "Add :ProgramArguments:2 string $app" "$temporary" \
            || return 1
    fi
    /usr/libexec/PlistBuddy -c 'Add :RunAtLoad bool true' "$temporary" \
        || return 1
    /usr/libexec/PlistBuddy \
        -c 'Add :LimitLoadToSessionType string Aqua' "$temporary" \
        || return 1
    /usr/libexec/PlistBuddy -c 'Add :ProcessType string Background' "$temporary" \
        || return 1
    /usr/libexec/PlistBuddy -c 'Add :AssociatedBundleIdentifiers array' "$temporary" \
        || return 1
    /usr/libexec/PlistBuddy \
        -c 'Add :AssociatedBundleIdentifiers:0 string com.scholay.inputmethod.isaac' \
        "$temporary" || return 1
    /bin/chmod 644 "$temporary" || return 1
    if [ "$owner_kind" = "system" ] && [ -z "$TEST_ROOT" ]; then
        /usr/sbin/chown root:wheel "$temporary" || return 1
    fi
    verify_agent "$temporary" "$label" "$app" "$owner_kind" || return 1

    # Keep the previous valid definition until the replacement has been fully
    # constructed and linted. A same-directory rename is atomic.
    if [ -e "$agent" ]; then
        [ -f "$agent" ] && [ ! -L "$agent" ] || return 1
        backup="$(/usr/bin/mktemp "$agent_dir/.rimes-companion-backup.XXXXXX")" \
            || return 1
        /bin/cp -p "$agent" "$backup" || return 1
    fi
    if ! /bin/mv -f "$temporary" "$agent"; then
        return 1
    fi
    temporary=""
    if ! verify_agent "$agent" "$label" "$app" "$owner_kind"; then
        /bin/rm -f "$agent"
        if [ -n "$backup" ]; then
            /bin/mv -f "$backup" "$agent" || true
            backup=""
        fi
        return 1
    fi
    [ -z "$backup" ] || /bin/rm -f "$backup"
    backup=""
}

remove_agent() {
    local agent="$1"
    local label="$2"
    local app="$3"
    local owner_kind="$4"

    [ -e "$agent" ] || [ -L "$agent" ] || return 0
    if [ -L "$agent" ] \
        || ! verify_agent "$agent" "$label" "$app" "$owner_kind"; then
        echo "RIMES companion: refusing to remove an unverified LaunchAgent" >&2
        return 1
    fi
    /bin/rm -f "$agent" && [ ! -e "$agent" ] && [ ! -L "$agent" ]
}

if [ -n "$TEST_ROOT" ]; then
    [ "${RIMES_COMPANION_TESTING:-}" = "1" ] || {
        echo "RIMES companion: test root requires RIMES_COMPANION_TESTING=1" >&2
        exit 2
    }
    [ "$(/usr/bin/id -u)" -ne 0 ] || {
        echo "RIMES companion: root may not redirect system installation" >&2
        exit 2
    }
    case "$TEST_ROOT" in
        /*) ;;
        *) echo "RIMES companion: test root must be absolute" >&2; exit 2 ;;
    esac
    SYSTEM_AGENT_DIR="$TEST_ROOT/Library/LaunchAgents"
fi

require_system_authority() {
    if [ -z "$TEST_ROOT" ] && [ "$(/usr/bin/id -u)" -ne 0 ]; then
        echo "RIMES companion: system LaunchAgent operation requires root" >&2
        return 1
    fi
}

system_transaction_paths() {
    SYSTEM_AGENT="$SYSTEM_AGENT_DIR/$SYSTEM_LABEL.plist"
    SYSTEM_ROLLBACK="$SYSTEM_AGENT_DIR/.com.scholay.rimes.companion-start.rollback"
    SYSTEM_ABSENT_MARKER="$SYSTEM_AGENT_DIR/.com.scholay.rimes.companion-start.absent"
}

verify_managed_system_file() {
    local path="$1"
    [ -f "$path" ] && [ ! -L "$path" ] \
        && /usr/bin/plutil -lint "$path" >/dev/null \
        && [ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$path" 2>/dev/null)" = "$SYSTEM_LABEL" ]
}

begin_system_transaction() {
    require_system_authority || return 1
    system_transaction_paths
    [ ! -L "$SYSTEM_AGENT_DIR" ] || return 1
    /bin/mkdir -p "$SYSTEM_AGENT_DIR" || return 1
    [ -d "$SYSTEM_AGENT_DIR" ] && [ ! -L "$SYSTEM_AGENT_DIR" ] || return 1
    [ ! -e "$SYSTEM_ROLLBACK" ] && [ ! -L "$SYSTEM_ROLLBACK" ] \
        && [ ! -e "$SYSTEM_ABSENT_MARKER" ] \
        && [ ! -L "$SYSTEM_ABSENT_MARKER" ] || {
        echo "RIMES companion: unfinished system transaction requires rollback" >&2
        return 1
    }
    if [ -e "$SYSTEM_AGENT" ] || [ -L "$SYSTEM_AGENT" ]; then
        verify_managed_system_file "$SYSTEM_AGENT" || {
            echo "RIMES companion: existing system LaunchAgent is not managed" >&2
            return 1
        }
        temporary="$(/usr/bin/mktemp "$SYSTEM_AGENT_DIR/.rimes-companion-snapshot.XXXXXX")" \
            || return 1
        /bin/cp -p "$SYSTEM_AGENT" "$temporary" \
            && /usr/bin/cmp -s "$SYSTEM_AGENT" "$temporary" \
            && /bin/mv -f "$temporary" "$SYSTEM_ROLLBACK" || return 1
        temporary=""
    else
        temporary="$(/usr/bin/mktemp "$SYSTEM_AGENT_DIR/.rimes-companion-absent.XXXXXX")" \
            || return 1
        printf 'absent\n' >"$temporary" || return 1
        /bin/chmod 600 "$temporary" || return 1
        if [ -z "$TEST_ROOT" ]; then
            /usr/sbin/chown root:wheel "$temporary" || return 1
        fi
        /bin/mv -f "$temporary" "$SYSTEM_ABSENT_MARKER" || return 1
        temporary=""
    fi
}

rollback_system_transaction() {
    require_system_authority || return 1
    system_transaction_paths
    if [ -e "$SYSTEM_ROLLBACK" ] || [ -L "$SYSTEM_ROLLBACK" ]; then
        verify_managed_system_file "$SYSTEM_ROLLBACK" || return 1
        [ ! -e "$SYSTEM_ABSENT_MARKER" ] \
            && [ ! -L "$SYSTEM_ABSENT_MARKER" ] || return 1
        temporary="$(/usr/bin/mktemp "$SYSTEM_AGENT_DIR/.rimes-companion-restore.XXXXXX")" \
            || return 1
        /bin/cp -p "$SYSTEM_ROLLBACK" "$temporary" || return 1
        if [ -z "$TEST_ROOT" ]; then
            /usr/sbin/chown root:wheel "$temporary" || return 1
        fi
        /usr/bin/cmp -s "$SYSTEM_ROLLBACK" "$temporary" || return 1
        /bin/mv -f "$temporary" "$SYSTEM_AGENT" || return 1
        temporary=""
        /usr/bin/cmp -s "$SYSTEM_ROLLBACK" "$SYSTEM_AGENT" || return 1
        /bin/rm -f "$SYSTEM_ROLLBACK" || return 1
        return 0
    fi
    if [ -e "$SYSTEM_ABSENT_MARKER" ] \
        || [ -L "$SYSTEM_ABSENT_MARKER" ]; then
        [ -f "$SYSTEM_ABSENT_MARKER" ] \
            && [ ! -L "$SYSTEM_ABSENT_MARKER" ] \
            && [ "$(/bin/cat "$SYSTEM_ABSENT_MARKER" 2>/dev/null)" = "absent" ] \
            || return 1
        if [ -e "$SYSTEM_AGENT" ] || [ -L "$SYSTEM_AGENT" ]; then
            verify_managed_system_file "$SYSTEM_AGENT" || return 1
            /bin/rm -f "$SYSTEM_AGENT" || return 1
        fi
        [ ! -e "$SYSTEM_AGENT" ] && [ ! -L "$SYSTEM_AGENT" ] || return 1
        /bin/rm -f "$SYSTEM_ABSENT_MARKER" || return 1
    fi
}

commit_system_transaction() {
    require_system_authority || return 1
    system_transaction_paths
    if [ -f "$SYSTEM_ROLLBACK" ] && [ ! -L "$SYSTEM_ROLLBACK" ]; then
        /bin/rm -f "$SYSTEM_ROLLBACK"
    elif [ -f "$SYSTEM_ABSENT_MARKER" ] \
        && [ ! -L "$SYSTEM_ABSENT_MARKER" ]; then
        /bin/rm -f "$SYSTEM_ABSENT_MARKER"
    else
        echo "RIMES companion: no active system transaction to commit" >&2
        return 1
    fi
}

wait_for_user_processes_to_stop() {
    local uid="$1"
    local attempt=0
    local process_name process_probe pids probe_status

    case "$uid" in
        ""|*[!0-9]*)
            echo "RIMES companion: invalid login UID for process verification" >&2
            return 1
            ;;
    esac
    [ "$uid" -ne 0 ] || return 1

    while [ "$attempt" -lt 30 ]; do
        pids=""
        for process_name in RIMES ETInput RimeBuffer; do
            process_probe="$(
                /usr/bin/pgrep -U "$uid" -x "$process_name" 2>/dev/null
            )"
            probe_status=$?
            case "$probe_status" in
                0)
                    pids="${pids}${pids:+ }${process_probe}"
                    ;;
                1) ;;
                *)
                    echo "RIMES companion: process inventory failed" >&2
                    return 1
                    ;;
            esac
        done
        [ -n "$pids" ] || return 0
        attempt=$((attempt + 1))
        /bin/sleep 0.1 || return 1
    done
    echo "RIMES companion: old RIMES process is still running for uid $uid" >&2
    return 1
}

audit_running_process_owners() {
    local allowed_uid="${1:-none}"
    local process_name process_probe probe_status pid owner_uid

    case "$allowed_uid" in
        none) ;;
        ""|*[!0-9]*)
            echo "RIMES companion: invalid allowed process owner UID" >&2
            return 1
            ;;
    esac
    for process_name in RIMES ETInput RimeBuffer; do
        process_probe="$(
            /usr/bin/pgrep -x "$process_name" 2>/dev/null
        )"
        probe_status=$?
        case "$probe_status" in
            1) continue ;;
            0) ;;
            *)
                echo "RIMES companion: system process inventory failed" >&2
                return 1
                ;;
        esac
        for pid in $process_probe; do
            case "$pid" in
                ""|*[!0-9]*) return 1 ;;
            esac
            owner_uid="$(
                /bin/ps -p "$pid" -o uid= 2>/dev/null \
                    | /usr/bin/tr -d '[:space:]'
            )"
            if [ -z "$owner_uid" ]; then
                # A process that disappeared after pgrep is no longer a
                # replacement hazard. Any still-live unreadable PID is unknown.
                /bin/kill -0 "$pid" 2>/dev/null || continue
                echo "RIMES companion: process owner is unavailable for pid $pid" >&2
                return 1
            fi
            case "$owner_uid" in
                *[!0-9]*) return 1 ;;
            esac
            if [ "$owner_uid" != "$allowed_uid" ]; then
                echo "RIMES companion: running $process_name for uid $owner_uid blocks the system update" >&2
                return 1
            fi
        done
    done
    return 0
}

verify_managed_user_app() {
    local app="$1"
    local identifier

    [ -d "$app" ] && [ ! -L "$app" ] || return 1
    identifier="$(
        /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
            "$app/Contents/Info.plist" 2>/dev/null
    )" || return 1
    case "$identifier" in
        com.scholay.inputmethod.isaac|com.scholay.isaac|com.isaac.inputmethod.RimeBuffer|com.isaac.inputmethod.ETInput)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Set AUDIT_TARGET and return 0 when the exact leaf exists (including a broken
# symlink), 1 when a safely traversed parent proves it absent, and 2 when the
# home cannot be audited without following a symlink or guessing about state.
audit_exact_user_leaf() {
    local home="$1"
    local child_dir="$2"
    local leaf="$3"
    local path

    AUDIT_TARGET="$home/Library/$child_dir/$leaf"
    case "$home" in
        /*) ;;
        *) return 2 ;;
    esac
    [ -d "$home" ] && [ ! -L "$home" ] || return 2
    path="$home/Library"
    if [ -L "$path" ]; then
        return 2
    elif [ ! -e "$path" ]; then
        return 1
    elif [ ! -d "$path" ]; then
        return 2
    fi
    path="$path/$child_dir"
    if [ -L "$path" ]; then
        return 2
    elif [ ! -e "$path" ]; then
        return 1
    elif [ ! -d "$path" ]; then
        return 2
    fi
    if [ -e "$AUDIT_TARGET" ] || [ -L "$AUDIT_TARGET" ]; then
        return 0
    fi
    return 1
}

audit_user_record() {
    local uid="$1"
    local home="$2"
    local allowed_uid="$3"
    local app agent state owner_uid

    app="$home/Library/Input Methods/RIMES.app"
    agent="$home/Library/LaunchAgents/$USER_LABEL.plist"
    if [ -z "$TEST_ROOT" ]; then
        owner_uid="$(/usr/bin/stat -f '%u' "$home" 2>/dev/null)" || {
            echo "RIMES companion: user home ownership is unavailable: $home" >&2
            return 1
        }
        [ "$owner_uid" = "$uid" ] || {
            echo "RIMES companion: user home ownership is inconsistent: $home" >&2
            return 1
        }
    fi

    audit_exact_user_leaf "$home" "Input Methods" "RIMES.app"
    state=$?
    case "$state" in
        0)
            if [ "$uid" != "$allowed_uid" ]; then
                echo "RIMES companion: per-user development app blocks the system package: $app" >&2
                return 1
            fi
            if ! verify_managed_user_app "$app"; then
                echo "RIMES companion: current user's development app cannot be safely retired: $app" >&2
                return 1
            fi
            if [ -z "$TEST_ROOT" ]; then
                owner_uid="$(/usr/bin/stat -f '%u' "$app" 2>/dev/null)" \
                    || return 1
                [ "$owner_uid" = "$uid" ] || {
                    echo "RIMES companion: development app ownership is inconsistent: $app" >&2
                    return 1
                }
            fi
            ;;
        1) ;;
        *)
            echo "RIMES companion: user Input Methods path cannot be safely audited: $app" >&2
            return 1
            ;;
    esac

    audit_exact_user_leaf "$home" "LaunchAgents" "$USER_LABEL.plist"
    state=$?
    case "$state" in
        0)
            if [ "$uid" != "$allowed_uid" ]; then
                echo "RIMES companion: per-user development LaunchAgent blocks the system package: $agent" >&2
                return 1
            fi
            if ! verify_agent "$agent" "$USER_LABEL" "$app" user; then
                echo "RIMES companion: current user's development LaunchAgent cannot be safely retired: $agent" >&2
                return 1
            fi
            if [ -z "$TEST_ROOT" ]; then
                owner_uid="$(/usr/bin/stat -f '%u' "$agent" 2>/dev/null)" \
                    || return 1
                [ "$owner_uid" = "$uid" ] || {
                    echo "RIMES companion: development LaunchAgent ownership is inconsistent: $agent" >&2
                    return 1
                }
            fi
            ;;
        1) ;;
        *)
            echo "RIMES companion: user LaunchAgents path cannot be safely audited: $agent" >&2
            return 1
            ;;
    esac
    return 0
}

audit_system_install_conflicts() {
    local allowed_uid="${1:-none}"
    local line parsed username uid account_record record_uid home extra fixture

    require_system_authority || return 1
    case "$allowed_uid" in
        none) ;;
        ""|*[!0-9]*)
            echo "RIMES companion: invalid allowed console UID" >&2
            return 1
            ;;
    esac

    if [ -n "$TEST_ROOT" ]; then
        fixture="$TEST_ROOT/local-users.tsv"
        [ -f "$fixture" ] && [ ! -L "$fixture" ] || {
            echo "RIMES companion: test user inventory is unavailable" >&2
            return 1
        }
        while IFS=$'\t' read -r uid home extra; do
            [ -n "$uid" ] && [ -n "$home" ] && [ -z "$extra" ] || return 1
            case "$uid" in
                *[!0-9]*) return 1 ;;
            esac
            [ "$uid" -ge 500 ] || continue
            audit_user_record "$uid" "$home" "$allowed_uid" || return 1
        done <"$fixture"
        return 0
    fi

    audit_list="$(
        /usr/bin/mktemp /private/tmp/rimes-companion-users.XXXXXX
    )" || return 1
    /bin/chmod 600 "$audit_list" || return 1
    /usr/bin/dscl . -list /Users UniqueID >"$audit_list" || {
        echo "RIMES companion: local account inventory failed" >&2
        return 1
    }
    while IFS= read -r line; do
        parsed="$(
            printf '%s\n' "$line" | /usr/bin/awk '
                NF == 2 && $2 ~ /^-?[0-9]+$/ {
                    printf "%s\\t%s", $1, $2
                    valid = 1
                }
                END { if (!valid) exit 1 }
            '
        )" || {
            echo "RIMES companion: malformed local account inventory" >&2
            return 1
        }
        IFS=$'\t' read -r username uid <<<"$parsed"
        [ "$uid" -ge 500 ] 2>/dev/null || continue
        account_record="$(/usr/bin/id -P "$username" 2>/dev/null)" || {
            echo "RIMES companion: local account record is unavailable: $username" >&2
            return 1
        }
        case "$account_record" in
            *$'\n'*)
                echo "RIMES companion: ambiguous local account record: $username" >&2
                return 1
                ;;
        esac
        record_uid="$(
            printf '%s\n' "$account_record" \
                | /usr/bin/awk -F: 'NF >= 10 { print $3 }'
        )"
        home="$(
            printf '%s\n' "$account_record" \
                | /usr/bin/awk -F: 'NF >= 10 { print $9 }'
        )"
        [ "$record_uid" = "$uid" ] && [ -n "$home" ] || {
            echo "RIMES companion: inconsistent local account record: $username" >&2
            return 1
        }
        audit_user_record "$uid" "$home" "$allowed_uid" || return 1
    done <"$audit_list"
    /bin/rm -f "$audit_list" || return 1
    audit_list=""
    return 0
}

case "$MODE" in
    install-user)
        USER_AGENT="$USER_AGENT_DIR/$USER_LABEL.plist"
        write_agent "$USER_AGENT_DIR" "$USER_AGENT" "$USER_LABEL" \
            "$USER_APP" "$USER_APP" user
        ;;
    verify-user)
        verify_agent "$USER_AGENT_DIR/$USER_LABEL.plist" \
            "$USER_LABEL" "$USER_APP" user
        ;;
    remove-user)
        remove_agent "$USER_AGENT_DIR/$USER_LABEL.plist" \
            "$USER_LABEL" "$USER_APP" user
        ;;
    install-system)
        require_system_authority || exit 1
        SYSTEM_AGENT="$SYSTEM_AGENT_DIR/$SYSTEM_LABEL.plist"
        physical_app="${TEST_ROOT}${SYSTEM_APP}"
        write_agent "$SYSTEM_AGENT_DIR" "$SYSTEM_AGENT" "$SYSTEM_LABEL" \
            "$SYSTEM_APP" "$physical_app" system
        ;;
    verify-system)
        verify_agent "$SYSTEM_AGENT_DIR/$SYSTEM_LABEL.plist" \
            "$SYSTEM_LABEL" "$SYSTEM_APP" system
        ;;
    remove-system)
        require_system_authority || exit 1
        remove_agent "$SYSTEM_AGENT_DIR/$SYSTEM_LABEL.plist" \
            "$SYSTEM_LABEL" "$SYSTEM_APP" system
        ;;
    begin-system-update)
        begin_system_transaction
        ;;
    rollback-system-update)
        rollback_system_transaction
        ;;
    commit-system-update)
        commit_system_transaction
        ;;
    wait-user-processes-stopped)
        wait_for_user_processes_to_stop "${2:-}"
        ;;
    audit-system-processes)
        audit_running_process_owners "${2:-none}"
        ;;
    audit-system-conflicts)
        audit_system_install_conflicts "${2:-none}"
        ;;
    *)
        echo "usage: rimes-companion-launch-agent.sh <install-user|verify-user|remove-user|install-system|verify-system|remove-system|begin-system-update|rollback-system-update|commit-system-update|wait-user-processes-stopped UID|audit-system-processes [allowed-console-uid]|audit-system-conflicts [allowed-console-uid]>" >&2
        exit 2
        ;;
esac
