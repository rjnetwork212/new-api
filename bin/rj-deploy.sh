#!/usr/bin/env bash
# Fork-only: build a pushed tag locally and ship it to the VPS over SSH (no registry, no GitHub Actions).
# Usage: bin/rj-deploy.sh v1.0.0-rc.51-rj.1 [ssh-host]
# Rollback: run again with an older tag.
set -euo pipefail

TAG="${1:?usage: $0 <tag v...-rj.N> [ssh-host]}"
HOST="${2:-167.86.66.132}"
IMAGE="rjnetwork212/new-api:$TAG"
REMOTE_DIR=/opt/new-api
cd "$(git rev-parse --show-toplevel)"

[[ "$TAG" =~ ^v[0-9A-Za-z.-]+-rj\.[0-9]+$ ]] || { echo "invalid tag '$TAG' (expected v...-rj.N)" >&2; exit 1; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || { echo "tag $TAG does not exist locally" >&2; exit 1; }
# AGPL: the source of what runs on the VPS must be public, so the tag must already be on GitHub.
[ "$(git ls-remote --tags origin "refs/tags/$TAG" "refs/tags/$TAG^{}" | tail -1 | cut -f1)" = "$(git rev-parse "$TAG^{commit}")" ] \
  || { echo "push the tag first: git push origin $TAG" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'git worktree remove --force "$WORK" >/dev/null 2>&1 || rm -rf "$WORK"' EXIT
git worktree add -q --detach "$WORK" "$TAG"
echo "$TAG" > "$WORK/VERSION"
docker build --platform linux/amd64 -t "$IMAGE" "$WORK"

echo "Shipping $IMAGE to $HOST ..."
docker save "$IMAGE" | gzip | ssh "$HOST" 'gunzip | docker load'
scp -q bin/rj-compose.yml "$HOST:/tmp/new-api-compose.yml"
scp -q bin/rj-backup.sh "$HOST:/tmp/new-api-backup.sh"

ssh "$HOST" TAG="$TAG" DIR="$REMOTE_DIR" bash -s <<'REMOTE'
set -euo pipefail
mkdir -p "$DIR/data"
cd "$DIR"
install -m 644 /tmp/new-api-compose.yml docker-compose.yml && rm -f /tmp/new-api-compose.yml
install -m 700 /tmp/new-api-backup.sh backup.sh && rm -f /tmp/new-api-backup.sh
# Daily backup at 03:30 server time; the new image may migrate the schema, so also back up before switching.
echo '30 3 * * * root /opt/new-api/backup.sh daily >/dev/null 2>&1' > /etc/cron.d/new-api-backup
if [ -f data/one-api.db ]; then ./backup.sh "pre-$TAG"; fi
if [ ! -f .env ]; then
  # First deploy: secret is generated on the VPS and never leaves it.
  umask 077
  printf 'SESSION_SECRET=%s\nNEW_API_TAG=%s\n' "$(openssl rand -hex 32)" "$TAG" > .env
fi
OLD="$(sed -n 's/^NEW_API_TAG=//p' .env)"
if [ -n "$OLD" ] && [ "$OLD" != "$TAG" ]; then
  # Remember the version being replaced so cleanup keeps it as the rollback image.
  if grep -q '^PREV_NEW_API_TAG=' .env; then
    sed -i "s|^PREV_NEW_API_TAG=.*|PREV_NEW_API_TAG=$OLD|" .env
  else
    echo "PREV_NEW_API_TAG=$OLD" >> .env
  fi
fi
sed -i "s|^NEW_API_TAG=.*|NEW_API_TAG=$TAG|" .env
docker compose up -d
for _ in $(seq 1 30); do
  if curl -fs http://127.0.0.1:18500/api/status | grep -q "\"version\":\"$TAG\""; then
    echo "OK: new-api $TAG is up on 127.0.0.1:18500"
    # Keep only the running and the previous version; touch no other repository.
    PREV="$(sed -n 's/^PREV_NEW_API_TAG=//p' .env)"
    docker image ls rjnetwork212/new-api --format '{{.Tag}}' | while read -r t; do
      case "$t" in "$TAG"|"$PREV"|"<none>") continue ;; esac
      docker rmi "rjnetwork212/new-api:$t" || echo "kept rjnetwork212/new-api:$t (in use)" >&2
    done
    exit 0
  fi
  sleep 2
done
echo "new-api $TAG did not report healthy; check: docker logs new-api" >&2
exit 1
REMOTE
