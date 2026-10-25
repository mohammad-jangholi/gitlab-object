# GitLab Stack Deployment, Backup, and Recovery Guide

## 1. Purpose

This document describes the deployment, configuration, backup, verification, and recovery preparation of a containerized GitLab environment.

The stack consists of:

- GitLab Community Edition (CE)
- GitLab Runner
- RustFS S3-compatible object storage
- Docker Compose
- Automated backup using a shell script
- Systemd service and timer for scheduled backups
- Local backup retention and remote backup upload

This guide records the implemented configuration and provides operational commands for maintenance and future recovery.

## 2. Architecture

```text
                    Git Users
                        |
                        v
               +------------------+
               |     GitLab CE    |
               | Repositories/CI  |
               +--------+---------+
                        |
                        v
               +------------------+
               |   GitLab Runner  |
               | Executes CI Jobs |
               +------------------+

               Backup Automation
                        |
                        v
               +------------------+
               | Backup Script    |
               | Verify / Archive |
               +--------+---------+
                        |
                +-------+-------+
                |               |
                v               v
        Local Backup       RustFS S3
        Retention          Object Storage
```

## 3. Environment

| Component | Configuration |
|---|---|
| Operating system | Red Hat Enterprise Linux 9.8 |
| Container runtime | Docker |
| Stack management | Docker Compose |
| GitLab image | `gitlab/gitlab-ce:19.5.1-ce.0` |
| GitLab Runner | Containerized |
| RustFS | S3-compatible object storage |
| Stack directory | `/opt/gitlab-stack` |
| Backup directory | `/opt/gitlab-stack/backups` |
| Backup script | `/opt/gitlab-stack/backup/scripts/backup-stack.sh` |
| Backup schedule | Daily at 02:00 server local time |
| Local retention | Seven backup sets |

Service endpoints and credentials are maintained in the deployment configuration and are intentionally excluded from this document.

## 4. Prerequisites

Before deploying or maintaining the stack, verify the following:

- RHEL 9.8 is installed and operational.
- Docker Engine is installed and running.
- Docker Compose is available.
- Sufficient disk space is available for GitLab data and backup archives.
- Required network connectivity is available between GitLab, Runner, and RustFS.
- Required container images are available.
- Administrative access is available for creating directories and configuring systemd.
- Credentials are stored securely and are not included in source control.

Check the host:

```bash
cat /etc/redhat-release
docker --version
docker compose version
systemctl status docker --no-pager
docker ps
```

If a command is unavailable, resolve the prerequisite before proceeding.

## 5. Create the Directory Structure

The stack is maintained under `/opt/gitlab-stack`.

Create the required directories:

```bash
mkdir -p /opt/gitlab-stack/{gitlab,gitlab-runner,rustfs,backup/scripts,backups}

mkdir -p /opt/gitlab-stack/gitlab/{config,logs,data}

mkdir -p /opt/gitlab-stack/gitlab-runner/config

mkdir -p /opt/gitlab-stack/rustfs/data
```

The expected structure is:

```text
/opt/gitlab-stack/
├── compose.yaml
├── .env
├── .env.example
├── .gitignore
├── README.md
├── gitlab/
│   ├── compose.yaml
│   ├── config/
│   ├── logs/
│   └── data/
├── gitlab-runner/
│   ├── compose.yaml
│   └── config/
├── rustfs/
│   ├── compose.yaml
│   └── data/
├── backup/
│   └── scripts/
│       └── backup-stack.sh
└── backups/
    └── stack-<timestamp>/
        ├── <gitlab-backup-archive>.tar
        ├── stack-data.tar.gz
        └── SHA256SUMS
```

The directory names above describe the deployment layout. Existing files and permissions must be preserved when working on an already-running installation.

Verify the directories:

```bash
find /opt/gitlab-stack -maxdepth 3 -type d -print
```

## 6. Configuration Files

### 6.1 Main Compose file

Location:

```text
/opt/gitlab-stack/compose.yaml
```

The main Compose file coordinates the component Compose files for RustFS, GitLab CE, and GitLab Runner.

The expected component relationships are:

```text
compose.yaml
    |
    +-- rustfs/compose.yaml
    |
    +-- gitlab/compose.yaml
    |
    +-- gitlab-runner/compose.yaml
```

Inspect the current configuration:

```bash
cd /opt/gitlab-stack
cat compose.yaml
```

Validate the Compose configuration:

```bash
docker compose config --quiet
```

Do not replace the existing Compose file with a generic example without first checking the current service names, mounts, networks, and environment variables.

### 6.2 Environment file

Location:

```text
/opt/gitlab-stack/.env
```

The environment file contains deployment-specific configuration and sensitive credentials used by the Compose services and backup automation.

Protect it:

```bash
chmod 600 /opt/gitlab-stack/.env
```

Do not print its contents into terminal logs, include it in public repositories, or share its credentials in tickets or documentation.

An example template may be maintained separately as `.env.example`, containing placeholder values only.

### 6.3 GitLab Compose configuration

Location:

```text
/opt/gitlab-stack/gitlab/compose.yaml
```

The GitLab service uses persistent storage for its configuration, logs, and application data.

The persistent directories are:

```text
gitlab/config
gitlab/logs
gitlab/data
```

The deployed image is:

```text
gitlab/gitlab-ce:19.5.1-ce.0
```

Check the service and image:

```bash
docker inspect gitlab \
  --format 'Image: {{.Config.Image}}'

docker inspect gitlab \
  --format '{{json .Mounts}}'
```

The native GitLab backup and the separate configuration archive have different responsibilities. Both are required for the recovery plan.

### 6.4 GitLab Runner Compose configuration

Location:

```text
/opt/gitlab-stack/gitlab-runner/compose.yaml
```

Persistent Runner configuration:

```text
/opt/gitlab-stack/gitlab-runner/config
```

The Runner executes CI/CD jobs defined in the GitLab repository.

Check the Runner:

```bash
docker ps --filter name=gitlab-runner

docker logs --tail 100 gitlab-runner

docker exec gitlab-runner gitlab-runner --version

docker exec gitlab-runner gitlab-runner list
```

Runner registration credentials must remain protected. If a token has been exposed, rotate it through the appropriate GitLab administration workflow.

### 6.5 RustFS Compose configuration

Location:

```text
/opt/gitlab-stack/rustfs/compose.yaml
```

Persistent data directory:

```text
/opt/gitlab-stack/rustfs/data
```

RustFS provides S3-compatible object storage for backup archives.

The configured bucket is:

```text
gitlab-backups
```

The backup script reads the required access credentials from the protected environment file.

Verify RustFS:

```bash
docker ps --filter name=rustfs

docker logs --tail 100 rustfs
```

The exact RustFS command-line options and health-check endpoint depend on the deployed configuration.

## 7. Deploying or Managing the Stack

From the stack root:

```bash
cd /opt/gitlab-stack
```

Validate the Compose configuration:

```bash
docker compose config --quiet
```

List the services:

```bash
docker compose ps
```

Review the component Compose files before applying changes.

To start the configured stack, when starting it is intended:

```bash
docker compose up -d
```

To inspect container status:

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
```

**Operational warning:** Starting, recreating, or upgrading services may affect availability. Do not use destructive commands or remove persistent volumes as part of routine troubleshooting.

## 8. Backup Implementation

Backup script:

```text
/opt/gitlab-stack/backup/scripts/backup-stack.sh
```

The script automates the following operations:

1. Creates a native GitLab backup using the copy strategy.
2. Collects the resulting GitLab backup archive.
3. Archives the required stack configuration and data.
4. Includes GitLab configuration and encryption secrets in the separate archive.
5. Generates SHA-256 checksums.
6. Verifies the generated archives.
7. Creates a timestamped local backup directory.
8. Uploads the completed backup files to RustFS.
9. Lists the uploaded objects to verify their availability.
10. Applies local backup retention.

The local backup root is:

```text
/opt/gitlab-stack/backups
```

The completed backup directory uses the following naming convention:

```text
stack-<timestamp>
```

### 8.1 Backup archive contents

Each backup set contains:

```text
stack-<timestamp>/
├── <gitlab-backup-archive>.tar
├── stack-data.tar.gz
└── SHA256SUMS
```

The native GitLab archive contains the application data supported by GitLab's backup procedure.

The `stack-data.tar.gz` archive contains selected Compose files, environment configuration, GitLab configuration, Runner configuration, and the configured RustFS data directory.

The `SHA256SUMS` file contains checksums used to detect accidental changes or corruption.

**Important limitations:**

- GitLab native backup does not include every external configuration file.
- GitLab registry image backup was disabled in the observed native backup run. If the registry is used, its recovery must be planned separately.
- Archiving RustFS data while it is actively changing may produce an inconsistent copy.
- A backup stored on the same host does not protect against total host or disk failure.

## 9. Backup Permissions

Backup files and configuration archives may contain sensitive data.

The backup service uses a restrictive umask, and the backup script restricts the permissions of completed backup sets.

Check the permissions:

```bash
stat -c '%A %U:%G %n' \
  /opt/gitlab-stack/.env \
  /opt/gitlab-stack/backups
```

Do not make backups world-readable. Access to the backup directory should be limited to authorized administrators.

## 10. Systemd Backup Service

Service file:

```text
/etc/systemd/system/gitlab-stack-backup.service
```

The service is configured as a one-shot root-owned job.

Its purpose is to execute:

```text
/opt/gitlab-stack/backup/scripts/backup-stack.sh
```

Inspect the installed service:

```bash
systemctl cat gitlab-stack-backup.service
```

The service may show `inactive (dead)` after execution. This is expected for a successfully completed one-shot service; check the result and logs to confirm success.

## 11. Systemd Backup Timer

Timer file:

```text
/etc/systemd/system/gitlab-stack-backup.timer
```

The timer is configured to run daily at 02:00 server local time, with persistent scheduling enabled.

The timer was enabled using:

```bash
systemctl daemon-reload

systemctl enable --now gitlab-stack-backup.timer
```

Check the timer:

```bash
systemctl status gitlab-stack-backup.timer --no-pager

systemctl list-timers gitlab-stack-backup.timer
```

Start a manual backup:

```bash
systemctl start gitlab-stack-backup.service
```

Check the last execution:

```bash
systemctl status gitlab-stack-backup.service --no-pager

journalctl -u gitlab-stack-backup.service \
  -n 100 --no-pager
```

The timer schedule and the service's last execution are separate pieces of information. A manual service run does not necessarily update the timer's recorded last-trigger time.

## 12. Local Backup Retention

The backup script retains the seven most recent local backup directories.

List the backups:

```bash
ls -lht /opt/gitlab-stack/backups
```

Check the size of the backup directory:

```bash
du -sh /opt/gitlab-stack/backups
```

Remote RustFS objects are not automatically deleted by this local retention process. A separate remote retention policy must be designed and tested before enabling remote deletion.

## 13. RustFS Upload and Verification

Backup objects are uploaded under a separate prefix for each backup set:

```text
s3://gitlab-backups/stack-<timestamp>/
```

The script uses the AWS CLI container and an S3-compatible endpoint to upload the backup files.

The upload process performs an object-listing step after the transfer.

A successful upload and listing were verified during the initial backup test.

For an additional manual check, use the same AWS CLI container and credentials configured for the deployment. Do not put credentials directly on the command line or include them in shared logs.

Example listing command, when executed with the appropriate credential environment:

```bash
aws --endpoint-url "$RUSTFS_ENDPOINT" \
  s3 ls s3://gitlab-backups/ --recursive
```

The endpoint and credentials must be supplied from the existing protected environment. The example assumes that the AWS CLI is already configured to use the relevant credential variables.

## 14. Backup Integrity Verification

Identify the latest local backup:

```bash
LATEST="$(find /opt/gitlab-stack/backups \
  -maxdepth 1 -type d -name 'stack-*' \
  -printf '%T@ %p\n' |
  sort -nr |
  head -1 |
  cut -d' ' -f2-)"

echo "Latest backup: $LATEST"
```

Verify the recorded checksums:

```bash
cd "$LATEST"
sha256sum -c SHA256SUMS
```

Check that the configuration archive is readable:

```bash
tar -tzf "$LATEST/stack-data.tar.gz" >/dev/null &&
  echo "Configuration archive: OK"
```

Verify that the GitLab configuration and secrets are included:

```bash
tar -tzf "$LATEST/stack-data.tar.gz" |
  grep -E 'gitlab/config/(gitlab\.rb|gitlab-secrets\.json)$'
```

A successful checksum check establishes that the files match their recorded checksums. It does not prove that the application can be restored successfully.

## 15. Rollback and Recovery Procedure

The rollback procedure is currently documented but has not yet been validated by an isolated restore test.

The recovery process must follow these steps.

### 15.1 Preserve the current state

Before attempting recovery:

- Identify the incident and its impact.
- Record the currently deployed image versions.
- Preserve the current state with a fresh backup if the services are still accessible.
- Identify the last known-good backup.
- Verify that the selected backup archives are complete.

Do not immediately overwrite the existing application data.

### 15.2 Restore into an isolated environment

The first restore must be performed in a separate test environment.

The test environment should use compatible GitLab software and must not connect to production storage or overwrite production data.

Restore the selected GitLab native backup and the matching configuration files, including the GitLab secrets.

### 15.3 Validate the restored system

Validate the following:

- GitLab services start successfully.
- Users can authenticate.
- Repositories and commits are available.
- Required application configuration is present.
- GitLab Runner can connect and execute a test job.
- The restored backup corresponds to the intended recovery point.

Record the exact commands and results from the successful restore test.

### 15.4 Production recovery

Only after the isolated restore has succeeded should the validated procedure be considered for production use.

**Critical warning:** Do not assume that changing the GitLab image tag to an older version is a safe rollback. Database migrations and application-version compatibility must be considered. Use a compatible GitLab version and a consistent backup set.

## 16. Recovery Limitations and Disaster Recovery

The current GitLab and RustFS deployment resides on the same server.

Consequently, a host failure, storage failure, or severe incident affecting the server may also affect the RustFS backup copy.

Recommended future improvements:

1. Configure an independent off-host backup destination.
2. Define remote retention and lifecycle rules.
3. Test restoration from the RustFS copy rather than only from local files.
4. Document registry backup requirements if the GitLab Container Registry is used.
5. Measure recovery time and acceptable data loss after successful restore tests.
6. Monitor scheduled backup failures and upload failures.
7. Review backup coverage whenever the deployment changes.

## 17. Troubleshooting Commands

### Check all containers

```bash
docker ps -a
```

### Inspect GitLab logs

```bash
docker logs --tail 100 gitlab
```

### Inspect Runner logs

```bash
docker logs --tail 100 gitlab-runner
```

### Inspect RustFS logs

```bash
docker logs --tail 100 rustfs
```

### Check backup service logs

```bash
journalctl -u gitlab-stack-backup.service \
  -n 100 --no-pager
```

### Check disk space

```bash
df -h
du -sh /opt/gitlab-stack/*
```

### Validate Compose configuration

```bash
cd /opt/gitlab-stack
docker compose config --quiet
```

## 18. Implementation Status

| Task | Status |
|---|---|
| GitLab CE deployment | Completed |
| GitLab Runner deployment | Completed |
| RustFS deployment | Completed |
| Stack directory structure | Created |
| Backup script | Implemented |
| GitLab native backup | Tested |
| Configuration archive | Tested |
| SHA-256 checksum verification | Tested |
| RustFS upload | Tested |
| RustFS object listing | Tested |
| Daily systemd timer | Enabled |
| Seven-set local retention | Configured |
| Remote retention | Pending |
| Independent off-host backup | Pending |
| Isolated restore test | Pending |
| Rollback validation | Pending |

## 19. Operational Checklist

### Routine checks

- [ ] Confirm the backup timer is enabled.
- [ ] Review the latest backup service result.
- [ ] Verify the latest backup checksums.
- [ ] Confirm the uploaded RustFS objects are accessible.
- [ ] Monitor disk usage and backup growth.
- [ ] Confirm that credentials remain protected.

### Before an upgrade

- [ ] Create and verify a fresh backup.
- [ ] Record the current image versions.
- [ ] Review application and database compatibility.
- [ ] Confirm the backup is available independently of the application being upgraded.
- [ ] Ensure a documented recovery procedure is available.

### Before relying on disaster recovery

- [ ] Complete an isolated restore test.
- [ ] Verify GitLab data and configuration.
- [ ] Verify Runner connectivity.
- [ ] Test restoration from the independent backup destination.
- [ ] Document the recovery results and remaining limitations.

## 20. Conclusion

The GitLab stack backup automation has been implemented and tested. The backup script creates a GitLab native archive, captures required configuration, generates checksums, uploads the completed backup to RustFS, and verifies the uploaded objects.

The daily systemd timer is enabled, and local retention is configured.

The remaining major task is to validate recovery by performing an isolated restore test. Independent off-host backup storage and remote retention should also be addressed before considering the environment fully prepared for disaster recovery.

