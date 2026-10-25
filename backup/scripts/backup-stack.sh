#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="/opt/gitlab-stack"
BACKUP_ROOT="$ROOT/backups"
STAMP="$(date +%Y%m%d-%H%M%S)"
WORK="$BACKUP_ROOT/.stack-${STAMP}.inprogress"
FINAL="$BACKUP_ROOT/stack-${STAMP}"

exec 9>/run/lock/gitlab-stack-backup.lock
if ! flock -n 9; then
    echo "Another stack backup is already running."
    exit 1
fi

cleanup() {
    rc=$?
    if [[ -d "$WORK" ]]; then
        if [[ $rc -ne 0 ]]; then
            echo "Backup failed. Incomplete files remain at: $WORK"
        fi
    fi
    exit "$rc"
}
trap cleanup EXIT

cd "$ROOT"

for cmd in docker tar sha256sum find sort head du df flock; do
    command -v "$cmd" >/dev/null || {
        echo "Required command not found: $cmd"
        exit 1
    }
done

for path in \
    compose.yaml .env \
    gitlab/compose.yaml gitlab/config gitlab/data \
    gitlab-runner/compose.yaml gitlab-runner/config \
    rustfs/compose.yaml rustfs/data; do
    [[ -e "$ROOT/$path" ]] || {
        echo "Required path missing: $ROOT/$path"
        exit 1
    }
done

docker inspect -f '{{.State.Running}}' gitlab | grep -qx true
docker inspect -f '{{.State.Running}}' rustfs | grep -qx true
docker inspect -f '{{.State.Running}}' gitlab-runner | grep -qx true

mkdir -m 700 "$WORK"

echo "Starting GitLab native backup..."
docker exec gitlab gitlab-backup create STRATEGY=copy

GITLAB_ARCHIVE="$(
    find "$ROOT/gitlab/data/backups" -maxdepth 1 -type f \
        -name '*_gitlab_backup.tar' -printf '%T@ %p\n' |
    sort -nr | head -n 1 | cut -d' ' -f2-
)"

[[ -n "$GITLAB_ARCHIVE" && -f "$GITLAB_ARCHIVE" ]] || {
    echo "GitLab backup archive was not found."
    exit 1
}

mv "$GITLAB_ARCHIVE" "$WORK/"

echo "Archiving configuration and RustFS data..."
tar --acls --xattrs -czf "$WORK/stack-data.tar.gz" \
    -C "$ROOT" \
    compose.yaml .env .env.example .gitignore README.md \
    gitlab/compose.yaml gitlab/config \
    gitlab-runner/compose.yaml gitlab-runner/config \
    rustfs/compose.yaml rustfs/data

(
    cd "$WORK"
    sha256sum -- *.tar *.tar.gz > SHA256SUMS
)

echo "Checking archive integrity..."
while IFS= read -r archive; do
    tar -tf "$WORK/$archive" >/dev/null
done < <(find "$WORK" -maxdepth 1 -type f \
    \( -name '*.tar' -o -name '*.tar.gz' \) -printf '%f\n')

(
    cd "$WORK"
    sha256sum -c SHA256SUMS
)

mv "$WORK" "$FINAL"
chmod -R go-rwx "$FINAL"

echo "Backup completed: $FINAL"
du -sh "$FINAL"


echo "Uploading completed backup to RustFS..."

# Load the existing private configuration.
set -a
source "$ROOT/.env"
set +a

: "${RUSTFS_ACCESS_KEY:?RUSTFS_ACCESS_KEY is missing from .env}"
: "${RUSTFS_SECRET_KEY:?RUSTFS_SECRET_KEY is missing from .env}"

AWS_IMAGE="amazon/aws-cli"
BACKUP_NAME="$(basename "$FINAL")"

docker run --rm --network host \
    -e AWS_ACCESS_KEY_ID="$RUSTFS_ACCESS_KEY" \
    -e AWS_SECRET_ACCESS_KEY="$RUSTFS_SECRET_KEY" \
    -e AWS_DEFAULT_REGION=us-east-1 \
    -e AWS_EC2_METADATA_DISABLED=true \
    -v "$FINAL:/backup:ro" \
    "$AWS_IMAGE" \
    --endpoint-url http://127.0.0.1:9000 \
    s3 cp /backup/ "s3://gitlab-backups/${BACKUP_NAME}/" --recursive

echo "Verifying uploaded objects in RustFS..."
docker run --rm --network host \
    -e AWS_ACCESS_KEY_ID="$RUSTFS_ACCESS_KEY" \
    -e AWS_SECRET_ACCESS_KEY="$RUSTFS_SECRET_KEY" \
    -e AWS_DEFAULT_REGION=us-east-1 \
    -e AWS_EC2_METADATA_DISABLED=true \
    "$AWS_IMAGE" \
    --endpoint-url http://127.0.0.1:9000 \
    s3 ls "s3://gitlab-backups/${BACKUP_NAME}/" --recursive

echo "RustFS upload and listing completed for: ${BACKUP_NAME}"

# Retain the seven most recent completed backup sets.
mapfile -t OLD_BACKUPS < <(
    find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 \
        -type d -name 'stack-*' -printf '%T@ %p\n' |
    sort -nr | tail -n +8 | cut -d' ' -f2-
)

for old in "${OLD_BACKUPS[@]}"; do
    [[ -n "$old" ]] && rm -rf -- "$old"
done

echo "Backup finished successfully."
