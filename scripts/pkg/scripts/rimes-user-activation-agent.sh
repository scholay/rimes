#!/bin/bash
# Create/remove a one-shot per-user LaunchAgent. This script is always executed
# as the login user (never root), so user-controlled home-directory paths cannot
# turn Installer writes into privileged symlink traversal.
set -u

MODE="${1:-}"
MARKER_KIND="${2:-activation}"
LABEL="com.scholay.rimes.activation-repair"
EXE="/Library/Input Methods/ETInput.app/Contents/MacOS/ETInput"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
TIMEOUT_HELPER="${RIMES_TIMEOUT_HELPER:-$SCRIPT_DIR/rimes-timeout}"
MARKER_DIR="$HOME/Library/Application Support/RIMES"
MARKER="$MARKER_DIR/input-source-activation-pending"
LOCK="$MARKER_DIR/input-source-activation-repair.lock"
AGENT_DIR="$HOME/Library/LaunchAgents"
AGENT="$AGENT_DIR/$LABEL.plist"
marker_tmp=""
agent_tmp=""

cleanup() {
    [ -z "$marker_tmp" ] || /bin/rm -f "$marker_tmp"
    [ -z "$agent_tmp" ] || /bin/rm -f "$agent_tmp"
}

run_locked_mode() {
    local locked_mode="$1"
    local attempt=0
    local lock_status=75
    shift

    # A repair process holds the same lock only while taking or committing a
    # marker snapshot. Retry that short critical section instead of dropping a
    # newer marker generation on the first EWOULDBLOCK. The signed outer
    # watchdog remains the hard deadline and owns this entire process group.
    while [ "$attempt" -lt 100 ]; do
        "$TIMEOUT_HELPER" --lock-exec "$LOCK" \
            /bin/bash "$0" "$locked_mode" "$@"
        lock_status=$?
        [ "$lock_status" -eq 0 ] && return 0
        [ "$lock_status" -eq 75 ] || return "$lock_status"
        attempt=$((attempt + 1))
        /bin/sleep 0.1 || return 75
    done
    return 75
}

case "$MODE" in
    install)
        umask 077
        [ "${RIMES_OUTER_WATCHDOG:-}" = "1" ] || exit 1
        /bin/mkdir -p "$MARKER_DIR" "$AGENT_DIR" || exit 1
        case "$MARKER_KIND" in
            activation|duplicate-conflict) ;;
            *) exit 2 ;;
        esac
        [ -x "$TIMEOUT_HELPER" ] || exit 1
        # The signed helper acquires a kernel advisory lock, then execs in the
        # existing outer watchdog group. This avoids stale-file races without
        # creating a nested group that a shortened PackageKit budget could miss.
        run_locked_mode install-locked "$MARKER_KIND"
        exit $?
        ;;
    install-locked)
        umask 077
        trap cleanup EXIT

        marker_tmp="$(/usr/bin/mktemp "$MARKER_DIR/.activation-pending.XXXXXX")" \
            || exit 1
        marker_token="${marker_tmp##*.}"
        case "$marker_token" in
            ""|*[!A-Za-z0-9]*) exit 1 ;;
        esac
        agent_tmp="$(/usr/bin/mktemp "$AGENT_DIR/.rimes-activation.XXXXXX")" \
            || {
                /bin/rm -f "$marker_tmp"
                exit 1
            }

        # duplicate-conflict is the stronger durable condition. Never let a
        # concurrent ordinary activation request downgrade it before a repair
        # has physically proved both Input Methods roots clear.
        if [ -f "$MARKER" ] && [ ! -L "$MARKER" ]; then
            existing_marker="$(/usr/bin/head -c 64 "$MARKER" 2>/dev/null)"
            [ "$?" -eq 0 ] || exit 1
            case "$existing_marker" in
                duplicate-conflict|v1:duplicate-conflict:*)
                    MARKER_KIND="duplicate-conflict"
                    ;;
            esac
        fi

        /usr/bin/plutil -create xml1 "$agent_tmp" || exit 1
        /usr/libexec/PlistBuddy -c "Add :Label string $LABEL" "$agent_tmp" \
            || exit 1
        /usr/libexec/PlistBuddy -c 'Add :ProgramArguments array' "$agent_tmp" \
            || exit 1
        /usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $EXE" "$agent_tmp" \
            || exit 1
        /usr/libexec/PlistBuddy \
            -c 'Add :ProgramArguments:1 string --repair-pending-install' \
            "$agent_tmp" || exit 1
        /usr/libexec/PlistBuddy -c 'Add :RunAtLoad bool true' "$agent_tmp" \
            || exit 1
        /usr/libexec/PlistBuddy \
            -c 'Add :LimitLoadToSessionType string Aqua' "$agent_tmp" \
            || exit 1
        /usr/libexec/PlistBuddy -c 'Add :ProcessType string Background' "$agent_tmp" \
            || exit 1
        /usr/bin/plutil -lint "$agent_tmp" >/dev/null || exit 1
        /bin/chmod 600 "$marker_tmp" "$agent_tmp" || exit 1
        printf 'v1:%s:%s\n' "$MARKER_KIND" "$marker_token" \
            >"$marker_tmp" || exit 1
        # Publish the runnable agent first. The marker is the commit point: if
        # this process is interrupted between the two renames, a marker can
        # never be left without a consumer. A marker-less stale agent removes
        # itself when it next starts.
        /bin/mv -f "$agent_tmp" "$AGENT" || exit 1
        [ -f "$AGENT" ] && [ ! -L "$AGENT" ] \
            && /usr/bin/plutil -lint "$AGENT" >/dev/null || exit 1
        /bin/mv -f "$marker_tmp" "$MARKER" || exit 1
        [ -f "$MARKER" ] && [ ! -L "$MARKER" ] \
            && [ -f "$AGENT" ] && [ ! -L "$AGENT" ] || exit 1
        echo "RIMES postinstall: scheduled one-shot activation repair for next GUI login"
        ;;
    remove)
        umask 077
        [ "${RIMES_OUTER_WATCHDOG:-}" = "1" ] || exit 1
        /bin/mkdir -p "$MARKER_DIR" || exit 1
        [ -x "$TIMEOUT_HELPER" ] || exit 1
        run_locked_mode remove-locked
        exit $?
        ;;
    remove-locked)
        umask 077
        trap cleanup EXIT
        # Marker absence is the safety fence: never remove its only consumer
        # after a failed/uncertain marker deletion.
        /bin/rm -f "$MARKER" || exit 1
        [ ! -e "$MARKER" ] && [ ! -L "$MARKER" ] || exit 1
        /bin/rm -f "$AGENT" || exit 1
        [ ! -e "$AGENT" ] && [ ! -L "$AGENT" ] || exit 1
        ;;
    *)
        echo "usage: rimes-user-activation-agent.sh <install|remove> [activation|duplicate-conflict]" >&2
        exit 2
        ;;
esac
