#!/usr/bin/env bash
# watch-error-log.sh — Email new errors from Nginx/Apache/PHP error logs.
#
# Run from cron every 5-15 minutes. The script greps each log for error
# patterns, compares matches against a persistent state file of hashes it has
# already reported, and emails only the NEW lines. Repeated occurrences of
# the same error (same message, new timestamp) still alert, because each
# occurrence is a fresh event worth knowing about.
#
# Usage:
#   watch-error-log.sh --log /var/log/nginx/error.log \
#                      --log /var/log/php8.2-fpm.log \
#                      --to admin@example.com
#
# Options:
#   --log FILE        Error log to watch (repeatable, at least one required)
#   --to EMAIL        Where to send the alert (required unless --dry-run)
#   --from EMAIL      Sender address (default: root@<hostname>)
#   --state FILE      Hash state file (default: /var/lib/error-log-watcher/state)
#   --pattern REGEX   Match pattern (default: error|fatal|critical|emergency|alert)
#   --exclude REGEX   Skip lines matching this (repeatable)
#   --max-lines N     Cap lines per alert email (default: 50)
#   --json            Print a JSON summary instead of human text
#   --dry-run         Print what would be emailed, send nothing, touch no state
#   --quiet           Print nothing unless there are new errors
#   --help            Show usage
#
# Exit codes: 0 = no new errors, 1 = new errors found (and emailed),
#             2 = usage/config error.
#
set -euo pipefail

LOGS=()
TO=""
FROM=""
STATE_FILE="/var/lib/error-log-watcher/state"
PATTERN="error|fatal|critical|emergency|alert"
EXCLUDES=()
MAX_LINES=50
JSON=0
DRY_RUN=0
QUIET=0

usage() {
    sed -n '2,/^#$/p' "$0" | sed 's/^# //; s/^#//'
    exit "${1:-0}"
}

die() {
    echo "watch-error-log: $*" >&2
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --log)       [[ $# -ge 2 ]] || die "--log needs a value"; LOGS+=("$2"); shift 2 ;;
        --to)        [[ $# -ge 2 ]] || die "--to needs a value"; TO="$2"; shift 2 ;;
        --from)      [[ $# -ge 2 ]] || die "--from needs a value"; FROM="$2"; shift 2 ;;
        --state)     [[ $# -ge 2 ]] || die "--state needs a value"; STATE_FILE="$2"; shift 2 ;;
        --pattern)   [[ $# -ge 2 ]] || die "--pattern needs a value"; PATTERN="$2"; shift 2 ;;
        --exclude)   [[ $# -ge 2 ]] || die "--exclude needs a value"; EXCLUDES+=("$2"); shift 2 ;;
        --max-lines) [[ $# -ge 2 ]] || die "--max-lines needs a value"
                     [[ "$2" =~ ^[0-9]+$ ]] && [[ "$2" -gt 0 ]] || die "--max-lines must be a positive integer"
                     MAX_LINES="$2"; shift 2 ;;
        --json)      JSON=1; shift ;;
        --dry-run)   DRY_RUN=1; shift ;;
        --quiet)     QUIET=1; shift ;;
        --help|-h)   usage 0 ;;
        *)           die "unknown option: $1 (see --help)" ;;
    esac
done

[[ ${#LOGS[@]} -gt 0 ]] || die "at least one --log is required"
if [[ $DRY_RUN -eq 0 && -z "$TO" ]]; then
    die "--to is required (or use --dry-run)"
fi
[[ -n "$FROM" ]] || FROM="root@$(hostname -f 2>/dev/null || hostname)"

# --- Collect new error lines -------------------------------------------------

STATE_DIR="$(dirname "$STATE_FILE")"
if [[ $DRY_RUN -eq 0 ]]; then
    mkdir -p "$STATE_DIR" 2>/dev/null || die "cannot create state dir $STATE_DIR"
    touch "$STATE_FILE" 2>/dev/null || die "cannot write state file $STATE_FILE"
fi

TMPDIR_WORK="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_WORK"' EXIT
NEW_LINES="$TMPDIR_WORK/new-lines.txt"
NEW_HASHES="$TMPDIR_WORK/new-hashes.txt"
: > "$NEW_LINES"
: > "$NEW_HASHES"

READABLE=0
for LOG in "${LOGS[@]}"; do
    if [[ ! -r "$LOG" ]]; then
        echo "watch-error-log: warning: cannot read $LOG, skipping" >&2
        continue
    fi
    READABLE=1

    # grep -i returns 1 when nothing matches; that is fine, not an error.
    MATCHES="$TMPDIR_WORK/matches.txt"
    grep -iE "$PATTERN" "$LOG" > "$MATCHES" || true
    for EX in "${EXCLUDES[@]}"; do
        grep -viE "$EX" "$MATCHES" > "$MATCHES.tmp" || true
        mv "$MATCHES.tmp" "$MATCHES"
    done

    while IFS= read -r LINE; do
        [[ -n "$LINE" ]] || continue
        # Hash the full line (timestamp included): re-reading the same file
        # never re-alerts, but a fresh occurrence of the same message does.
        # In dry-run the state file may not exist; grep then fails quietly
        # and the line is treated as new, which is the correct preview.
        HASH="$(printf '%s' "$LINE" | sha1sum | awk '{print $1}')"
        if ! grep -qxF "$HASH" "$STATE_FILE" 2>/dev/null; then
            printf '%s\n' "$LINE" >> "$NEW_LINES"
            printf '%s\n' "$HASH" >> "$NEW_HASHES"
        fi
    done < "$MATCHES"
done

[[ $READABLE -eq 1 ]] || die "no readable log files"

NEW_COUNT="$(wc -l < "$NEW_LINES")"

if [[ "$NEW_COUNT" -eq 0 ]]; then
    if [[ $JSON -eq 1 ]]; then
        printf '{"status":"ok","new_errors":0}\n'
    elif [[ $QUIET -eq 0 ]]; then
        echo "No new errors."
    fi
    exit 0
fi

# --- Report ------------------------------------------------------------------

SUBJECT="[error-log] $NEW_COUNT new error(s) on $(hostname)"
if [[ "$NEW_COUNT" -gt "$MAX_LINES" ]]; then
    TRUNCATED=$((NEW_COUNT - MAX_LINES))
    BODY="$(head -n "$MAX_LINES" "$NEW_LINES")"$'\n'"... and $TRUNCATED more line(s) truncated."
else
    BODY="$(cat "$NEW_LINES")"
fi

if [[ $DRY_RUN -eq 1 ]]; then
    if [[ $JSON -eq 1 ]]; then
        python3 -c 'import json,sys; print(json.dumps({"status":"dry_run","new_errors":int(sys.argv[1]),"lines":open(sys.argv[2]).read().splitlines()}))' "$NEW_COUNT" "$NEW_LINES"
    else
        printf 'Subject: %s\nTo: %s\n\n%s\n' "$SUBJECT" "${TO:-<none>}" "$BODY"
    fi
    exit 1
fi

# Record the hashes BEFORE mailing, so a mail failure does not re-alert the
# same lines on the next run (the lines are still in the email's absence
# visible via the exit code and the log itself).
cat "$NEW_HASHES" >> "$STATE_FILE"

if command -v mail >/dev/null 2>&1; then
    printf '%s\n' "$BODY" | mail -s "$SUBJECT" -r "$FROM" "$TO"
elif command -v sendmail >/dev/null 2>&1; then
    {
        printf 'From: %s\nTo: %s\nSubject: %s\n\n' "$FROM" "$TO" "$SUBJECT"
        printf '%s\n' "$BODY"
    } | sendmail -t
else
    echo "watch-error-log: warning: neither 'mail' nor 'sendmail' found; printing alert instead" >&2
    printf 'Subject: %s\nTo: %s\n\n%s\n' "$SUBJECT" "$TO" "$BODY"
fi

if [[ $JSON -eq 1 ]]; then
    printf '{"status":"alerted","new_errors":%s,"to":"%s"}\n' "$NEW_COUNT" "$TO"
elif [[ $QUIET -eq 0 ]]; then
    echo "$NEW_COUNT new error(s) reported to $TO."
fi
exit 1
