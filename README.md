# VPS Error Log Watcher

Emails you the *new* errors from your Nginx, Apache or PHP error logs — nothing you have already seen. Run it from cron every 5–15 minutes and your inbox only gets fresh problems.

## How it works

1. Greps each log for error patterns (`error|fatal|critical|emergency|alert`, configurable).
2. Normalises each match (strips the leading timestamp) and hashes it.
3. Compares hashes against a persistent state file; only unseen lines are reported.
4. Emails the new lines via `mail` (or `sendmail` fallback) and records their hashes, so a mail failure never re-alerts the same lines.

## Usage

```bash
# Cron entry (every 10 minutes)
*/10 * * * * /usr/local/bin/watch-error-log.sh \
    --log /var/log/nginx/error.log \
    --log /var/log/php8.2-fpm.log \
    --to admin@example.com

# Test without sending or touching state
./watch-error-log.sh --log /var/log/nginx/error.log --to admin@example.com --dry-run

# Only watch for PHP fatals, skip a noisy known warning
./watch-error-log.sh --log /var/log/php8.2-fpm.log --to admin@example.com \
    --pattern 'fatal|uncaught' --exclude 'Deprecated: .* in /var/www/old-app/'
```

## Options

| Option | Description |
|---|---|
| `--log FILE` | Error log to watch (repeatable, at least one required) |
| `--to EMAIL` | Alert recipient (required unless `--dry-run`) |
| `--from EMAIL` | Sender (default `root@<hostname>`) |
| `--state FILE` | Hash state file (default `/var/lib/error-log-watcher/state`) |
| `--pattern REGEX` | Match pattern (default `error\|fatal\|critical\|emergency\|alert`) |
| `--exclude REGEX` | Skip lines matching this (repeatable) |
| `--max-lines N` | Cap lines per alert email (default 50) |
| `--json` | Print a JSON summary instead of human text |
| `--dry-run` | Print what would be emailed; send nothing, touch no state |
| `--quiet` | Print nothing unless there are new errors |

Exit codes: `0` = no new errors, `1` = new errors found (and emailed), `2` = usage/config error — so cron and Nagios can use it directly.

## Notes

- Repeated occurrences of the same message still alert (a new timestamp means a fresh event), but a log that is simply re-read never re-alerts.
- The state file is a plain list of SHA-1 hashes — safe to delete if you want a full re-alert.
- Requires `mail` or `sendmail` for delivery; without either it prints the alert to stdout and still exits `1`.

## License

MIT — see [LICENSE](LICENSE).
