#!/usr/bin/env bash
# Fork-only: back up the New API SQLite database and .env on the VPS, then prune old backups and file logs.
# Installed as /opt/new-api/backup.sh by bin/rj-deploy.sh; run daily from /etc/cron.d/new-api-backup and before each deploy.
# Usage: backup.sh [label]
set -euo pipefail

DIR=/opt/new-api
OUT="$DIR/backups"
LABEL="${1:-daily}"
KEEP_DAYS=14
STAMP="$(date +%Y%m%d-%H%M%S)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$OUT"
chmod 700 "$OUT"

# Online backup: consistent copy while the app keeps writing (WAL mode), unlike copying the file.
python3 - "$DIR/data/one-api.db" "$TMP/one-api.db" <<'PY'
import sqlite3, sys
src = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
dst = sqlite3.connect(sys.argv[2])
src.backup(dst)
ok = dst.execute("PRAGMA integrity_check").fetchone()[0]
dst.close()
src.close()
if ok != "ok":
    sys.exit(f"integrity_check failed: {ok}")
PY
cp "$DIR/.env" "$TMP/env"

umask 077
tar -czf "$OUT/new-api-$LABEL-$STAMP.tar.gz" -C "$TMP" one-api.db env
echo "backup: $OUT/new-api-$LABEL-$STAMP.tar.gz"

find "$OUT" -name 'new-api-*.tar.gz' -mtime +"$KEEP_DAYS" -delete
find "$DIR/data/logs" -name '*.log' -mtime +"$KEEP_DAYS" -delete 2>/dev/null || true
