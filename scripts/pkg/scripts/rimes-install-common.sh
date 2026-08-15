#!/bin/bash

# Shared helpers for Installer scripts. Keep user-session commands in the
# console user's GUI bootstrap and never let the root script open a path under
# the user's home directory for redirection.

RIMES_LOGIN_USER=""
RIMES_LOGIN_UID=""
RIMES_USER_HOME=""
RIMES_TIMEOUT_HELPER="$SCRIPT_DIR/rimes-timeout"
RIMES_INSTALL_DEADLINE=""

rimes_begin_budget() {
    local budget_seconds="$1"
    local started
    started="$("$RIMES_TIMEOUT_HELPER" --monotonic 2>/dev/null)" \
        || return 1
    case "$started" in
        ""|*[!0-9]*) return 1 ;;
    esac
    RIMES_INSTALL_DEADLINE=$((started + budget_seconds))
}

# Every potentially blocking command is executed in the independent process
# group created by this signed helper. On timeout it terminates the entire
# group, bounds every reap, and returns 124; descendants only inherit private
# unlinked output files and cannot retain PackageKit's log descriptors.
rimes_run_bounded() {
    local timeout_seconds="$1"
    local now remaining
    shift
    [ -x "$RIMES_TIMEOUT_HELPER" ] || {
        echo "RIMES installer: signed timeout helper is unavailable" >&2
        return 125
    }
    if [ -n "$RIMES_INSTALL_DEADLINE" ]; then
        now="$("$RIMES_TIMEOUT_HELPER" --monotonic 2>/dev/null)" \
            || return 125
        case "$now" in
            ""|*[!0-9]*) return 125 ;;
        esac
        remaining=$((RIMES_INSTALL_DEADLINE - now))
        [ "$remaining" -gt 0 ] || return 124
        if [ "$timeout_seconds" -gt "$remaining" ]; then
            timeout_seconds="$remaining"
        fi
    fi
    "$RIMES_TIMEOUT_HELPER" "$timeout_seconds" "$@"
}

rimes_account_record() {
    local record_file
    record_file="$(/usr/bin/mktemp -t rimes-account-record)" || return 1
    /bin/chmod 600 "$record_file" 2>/dev/null || true
    if ! rimes_run_bounded 5 /usr/bin/id -P "$1" \
        >"$record_file" 2>/dev/null; then
        /bin/rm -f "$record_file"
        return 1
    fi
    /bin/cat "$record_file"
    /bin/rm -f "$record_file"
}

rimes_resolve_console_user() {
    RIMES_LOGIN_USER="$(/usr/bin/stat -f%Su /dev/console 2>/dev/null || true)"
    case "$RIMES_LOGIN_USER" in
        ""|root|loginwindow|_mbsetupuser)
            return 1
            ;;
    esac

    rimes_home_record="$(rimes_account_record "$RIMES_LOGIN_USER" || true)"
    RIMES_LOGIN_UID="$(
        printf '%s\n' "$rimes_home_record" | /usr/bin/awk -F: 'NR == 1 { print $3 }'
    )"
    case "$RIMES_LOGIN_UID" in
        ""|*[!0-9]*)
            return 1
            ;;
    esac
    [ "$RIMES_LOGIN_UID" -ne 0 ] || return 1

    RIMES_USER_HOME="$(
        printf '%s\n' "$rimes_home_record" | /usr/bin/awk -F: 'NR == 1 { print $9 }'
    )"
    case "$RIMES_USER_HOME" in
        /*) ;;
        *) return 1 ;;
    esac
    rimes_run_login_user_bounded /bin/test -d "$RIMES_USER_HOME" \
        >/dev/null 2>&1 || return 1
    return 0
}

# File operations do not need a live Aqua bootstrap. Keeping them separate
# ensures a damaged/exiting GUI launchd domain cannot also suppress the durable
# pending marker used on the next login.
rimes_run_login_user_bounded() {
    rimes_run_login_user_bounded_with_timeout 3 "$@"
}

rimes_run_login_user_bounded_with_timeout() {
    local timeout_seconds="$1"
    shift
    rimes_run_bounded "$timeout_seconds" \
        /usr/bin/sudo -H -u "$RIMES_LOGIN_USER" \
        /usr/bin/env \
            HOME="$RIMES_USER_HOME" \
            USER="$RIMES_LOGIN_USER" \
            LOGNAME="$RIMES_LOGIN_USER" \
            RIMES_OUTER_WATCHDOG=1 \
            "$@"
}

rimes_run_console_user_bounded() {
    local timeout_seconds="$1"
    shift
    rimes_run_bounded "$timeout_seconds" \
        /bin/launchctl asuser "$RIMES_LOGIN_UID" \
        /usr/bin/sudo -H -u "$RIMES_LOGIN_USER" \
        /usr/bin/env \
            HOME="$RIMES_USER_HOME" \
            USER="$RIMES_LOGIN_USER" \
            LOGNAME="$RIMES_LOGIN_USER" \
            "$@"
}

rimes_run_console_user_activation_bounded() {
    rimes_run_console_user_bounded 100 "$@"
}

rimes_bundle_identifier() {
    rimes_run_bounded 5 \
        /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "$1/Contents/Info.plist" 2>/dev/null
}

# Return 0 only for a managed RIMES identity, 1 only when the identifier was
# read successfully and is known to be different, and 2 when the bundle cannot
# be inspected. Callers that police the physical TIS namespace must not turn a
# timeout/read error into proof that a candidate is unrelated.
rimes_is_owned_bundle() {
    local identifier probe_status
    identifier="$(rimes_bundle_identifier "$1")"
    probe_status=$?
    [ "$probe_status" -eq 0 ] || return 2
    case "$identifier" in
        com.isaac.inputmethod.RimeBuffer|com.isaac.inputmethod.ETInput)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

rimes_is_owned_bundle_as_login_user() {
    local identifier probe_status
    identifier="$(
        rimes_run_login_user_bounded /usr/libexec/PlistBuddy \
            -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" \
            2>/dev/null
    )"
    probe_status=$?
    [ "$probe_status" -eq 0 ] || return 2
    case "$identifier" in
        com.isaac.inputmethod.RimeBuffer|com.isaac.inputmethod.ETInput)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}
