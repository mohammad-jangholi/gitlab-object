# GitLab Stack Deployment, Backup, Email Notifications, and Recovery Guide

## 1. Purpose

This document describes the containerized GitLab environment running on RHEL 9.8, including deployment, CI/CD, email notifications, object storage, automated backups, and recovery preparation.

The guide records the known implementation state. Verify the live host before treating any status as current.

## 2. Architecture

```text
                     Developers / Git Clients
                               |
                               v
                      +------------------+
                      |    GitLab CE     |
                      | Repositories/CI  |
                      +--------+---------+
                               |
                     +---------+----------+
                     |                    |
                     v                    v
             +---------------+    +------------------+
             | GitLab Runner |    | Pipeline Webhook |
             | Executes Jobs |    +--------+---------+
             +---------------+             |
                                            v
                                   +------------------+
                                   | GitLab Notifier  |
                                   | Webhook Handler  |
                                   +--------+---------+
                                            |
                                            v
                                     Email Delivery
                                            |
                                            v
                                   +------------------+
                                   |     Mailpit      |
                                   | Test Mail Inbox  |
                                   +------------------+

                  Backup and Recovery
                           |
                           v
                  +------------------+
                  | Backup Script    |
                  | Archive / Verify |
                  +--------+---------+
                           |
                     +-----+------+
                     |            |
                     v            v
               Local Backups    RustFS
               Retention        S3-Compatible
```

### Component responsibilities

| Component | Purpose |
|---|---|
| GitLab CE | Source control, projects, pipelines, and CI/CD |
| GitLab Runner | Executes CI/CD jobs |
| GitLab Notifier | Receives configured events and sends notifications |
| Mailpit | Captures test email for inspection |
| RustFS | S3-compatible object storage for backup files |
| Docker Compose | Manages containerized services |
| Backup script | Creates, verifies, and uploads backups |
| systemd service/timer | Runs scheduled backups |

## 3. Environment

| Item | Configuration |
|---|---|
| Operating system | Red Hat Enterprise Linux 9.8 |
| Container runtime | Docker |
| Stack management | Docker Compose |
| GitLab image | `gitlab/gitlab-ce:19.5.1-ce.0` |
| GitLab Runner | Containerized |
| Object storage | RustFS |
| Email testing | Mailpit |
| Notification service | `gitlab-notifier` |
| Stack directory | `/opt/gitlab-stack` |
| Backup directory | `/opt/gitlab-stack/backups` |
| Backup script | `/opt/gitlab-stack/backup/scripts/backup-stack.sh` |
| Backup schedule | Daily at 02:00 server local time |
| Local retention | Seven backup sets |

Real endpoints, hostnames, email addresses, and credentials are intentionally excluded. Use the protected deployment configuration to find environment-specific values.

## 4. Prerequisites and Basic Checks

Required components include:

- RHEL 9.8
- Docker Engine and Docker Compose
- Persistent storage for GitLab and related services
- Network connectivity between the required containers
- Required container images
- Protected configuration and credentials
- Sufficient free space for application data and backup archives

Check the host:

```bash
cat /etc/redhat-release
docker --version
docker compose version
systemctl status docker --no-pager
docker ps
```

## 5. Directory Structure

The stack root is:

```text
/opt/gitlab-stack
```

Reference layout:

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

The notifier and Mailpit configurations may be maintained in separate Compose files or configuration directories. Confirm their actual locations before changing the deployment.

Inspect the existing structure:

```bash
find /opt/gitlab-stack -maxdepth 4 -type d -print
```

Do not overwrite existing configuration or recreate directories without checking current contents and permissions.

## 6. Configuration and Stack Management

### 6.1 Main Compose configuration

Main configuration:

```text
/opt/gitlab-stack/compose.yaml
```

Validate the configuration before applying changes:

```bash
cd /opt/gitlab-stack
docker compose config --quiet
docker compose ps
```

The main Compose configuration coordinates the applicable component configurations. Confirm actual service names, networks, mounts, and Compose include/merge behavior before editing it.

### 6.2 Environment variables and secrets

The environment file is:

```text
/opt/gitlab-stack/.env
```

Protect it:

```bash
chmod 600 /opt/gitlab-stack/.env
```

Do not commit `.env`, access tokens, webhook secrets, SMTP passwords, GitLab secrets, or private configuration to source control.

Use placeholder values in `.env.example`. Never paste secrets into documentation, command output, tickets, or shared logs.

### 6.3 GitLab CE

Image:

```text
gitlab/gitlab-ce:19.5.1-ce.0
```

Persistent data includes GitLab configuration, logs, and application data.

Inspect the container:

```bash
docker inspect gitlab --format 'Image: {{.Config.Image}}'
docker inspect gitlab --format '{{json .Mounts}}'
docker logs --tail 100 gitlab
```

Where supported by the deployed container:

```bash
docker exec gitlab gitlab-ctl status
```

GitLab's native backup does not replace a backup of the required configuration and secrets.

### 6.4 GitLab Runner

The Runner is containerized and executes jobs defined by project CI configuration.

Check its state:

```bash
docker ps -a --filter name=gitlab-runner
docker logs --tail 100 gitlab-runner
docker exec gitlab-runner gitlab-runner --version
docker exec gitlab-runner gitlab-runner list
docker exec gitlab-runner gitlab-runner verify
```

The Runner's persistent configuration and registration credentials must be protected.

If the Runner uses the host container-runtime socket, treat that socket as highly privileged. Access to it may allow control of host containers.

### 6.5 RustFS

RustFS provides S3-compatible object storage. The configured backup bucket is:

```text
gitlab-backups
```

Check the service:

```bash
docker ps -a --filter name=rustfs
docker logs --tail 100 rustfs
```

Use the configured S3-compatible endpoint and credentials for manual checks. Do not place access keys directly into command-line arguments or documentation.

### 6.6 Starting and stopping services

From the stack directory:

```bash
cd /opt/gitlab-stack
docker compose config --quiet
docker compose ps
```

Start the configured stack only when intended:

```bash
docker compose up -d
```

Inspect running containers:

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
```

Avoid destructive volume removal, broad container cleanup, or recreation of persistent storage as routine troubleshooting.

## 7. Email Notifications and Mailpit

### 7.1 Purpose

Mailpit provides a test inbox for inspecting email generated by the configured notification workflow. It is useful for validating email content and delivery during development and testing.

**Mailpit is an email testing tool, not a production outbound mail relay.** Messages captured by Mailpit should not be assumed to have reached a real recipient.

### 7.2 Notification flow

The configured notification workflow includes the following components:

1. An event occurs in GitLab.
2. For pipeline notifications, GitLab sends an event to the configured webhook.
3. The notifier receives and processes the event.
4. The notifier creates and sends an email through its configured mail-delivery path.
5. Mailpit captures the message for inspection.

The notifier has also been configured for successful-login notifications through a login-event forwarding path. This path is separate from pipeline webhook notifications.

```text
GitLab login event
        |
        v
Login event forwarding
        |
        v
Notifier
        |
        v
Mail delivery
        |
        v
Mailpit inbox
```

Pipeline event flow:

```text
Pipeline starts or finishes
        |
        v
GitLab webhook
        |
        v
Notifier webhook handler
        |
        v
Email notification
        |
        v
Mailpit inbox
```

The exact event types, filters, SMTP settings, and service URLs are deployment-specific and must be read from the protected configuration.

### 7.3 Mailpit verification

Check whether Mailpit is running:

```bash
docker ps -a --filter name=mailpit
docker logs --tail 100 mailpit
```

Inspect its port mappings without publishing the result into shared documentation:

```bash
docker port mailpit
```

Open the Mailpit web interface using the endpoint configured for your environment.

Verify that:

- The interface is accessible to authorized users.
- New test messages appear in the inbox.
- The sender, recipient, subject, and body are correct.
- The message timestamp matches the test.
- No credentials or sensitive data are unintentionally included in the message.

Mailpit's persistent data configuration should be checked to determine whether messages survive container recreation. Do not assume that email history is persistent unless the relevant volume or storage configuration has been verified.

### 7.4 Notifier verification

The notifier container is named:

```text
gitlab-notifier
```

Inspect its status and logs:

```bash
docker ps -a --filter name=gitlab-notifier
docker logs --tail 100 gitlab-notifier
```

The webhook handler has been configured to listen on the notifier's internal service port. The actual address and route must be taken from the current configuration.

Verify:

- The notifier is running.
- The expected internal network is attached.
- Its webhook handler is reachable from GitLab.
- Required mail configuration is available to the container.
- The webhook secret is configured securely.
- Logs show successful processing without exposing secrets.

Do not expose the notifier's internal webhook directly to untrusted networks.

### 7.5 Pipeline webhook configuration

In GitLab, open the applicable project's webhook settings and confirm:

- The URL matches the currently configured notifier endpoint.
- The webhook secret matches the protected notifier configuration.
- Pipeline events are enabled.
- The webhook is not unintentionally configured for unrelated events.
- The most recent delivery result and response are available for inspection.

A successful webhook response confirms that the webhook endpoint accepted the request. It does **not** by itself prove that an email was generated or captured.

### 7.6 End-to-end pipeline notification test

1. Confirm GitLab, the notifier, and Mailpit are running.
2. Confirm the project's pipeline webhook configuration.
3. Trigger a test pipeline in a non-critical project.
4. Open the webhook delivery details in GitLab.
5. Confirm the event reached the notifier.
6. Check notifier logs for processing or mail errors.
7. Open Mailpit and confirm the expected email appears.
8. Inspect the message subject, body, sender, recipient, and timestamp.

Record the outcome separately for webhook delivery and email delivery.

### 7.7 Login notification test

1. Confirm the login-event forwarding component is active.
2. Perform a permitted test login.
3. Check the forwarding component and notifier logs.
4. Open Mailpit and look for the corresponding notification.
5. Verify that the message relates to the test event and does not include credentials or session tokens.

Login notifications and pipeline notifications use different event sources. Test and troubleshoot them independently.

### 7.8 Email troubleshooting

| Symptom | Checks |
|---|---|
| No webhook delivery | GitLab webhook URL, event selection, connectivity, and delivery response |
| Webhook succeeds but no email | Notifier logs, event processing, mail settings, and SMTP connectivity |
| Email sent but absent in Mailpit | Mailpit service, SMTP destination, container network, and configured mail port |
| Login email missing | Login event forwarding, event processing, and notifier logs |
| Duplicate notifications | Webhook configuration, retries, event filters, and notifier behavior |
| Mailpit history disappears | Check persistent storage and container recreation behavior |
| Webhook authentication fails | Compare configured secret values securely without printing them |

Useful commands:

```bash
docker logs --tail 100 gitlab
docker logs --tail 100 gitlab-notifier
docker logs --tail 100 mailpit
docker ps -a
```

Review configuration locally and redact sensitive values before sharing diagnostic output.

### 7.9 Security considerations

- Use a webhook secret and validate incoming webhook requests.
- Keep webhook endpoints private unless external access is specifically required.
- Restrict access to Mailpit because it may contain internal event information.
- Do not treat Mailpit as a production email relay.
- Protect SMTP credentials and notification tokens.
- Avoid including passwords, access tokens, session cookies, or other secrets in notification messages.
- Review notification logs for accidental disclosure.
- Rotate any credential that may have been exposed.

## 8. Backup Implementation

Backup script:

```text
/opt/gitlab-stack/backup/scripts/backup-stack.sh
```

The recorded workflow is designed to:

1. Create a native GitLab backup using the configured copy strategy.
2. Collect the resulting GitLab backup archive.
3. Archive selected stack configuration and data.
4. Include required GitLab configuration and secrets in the configuration archive.
5. Generate SHA-256 checksums.
6. Verify the generated archives.
7. Create a timestamped local backup set.
8. Upload completed backup files to RustFS.
9. List uploaded objects to verify their availability.
10. Apply local retention.

Local backup root:

```text
/opt/gitlab-stack/backups
```

Backup set naming convention:

```text
stack-<timestamp>
```

### 8.1 Expected archive contents

```text
stack-<timestamp>/
├── <gitlab-backup-archive>.tar
├── stack-data.tar.gz
└── SHA256SUMS
```

The exact contents depend on the current script and configuration. Inspect the archive before relying on it for recovery.

The configuration archive may include Compose files, environment configuration, GitLab configuration, Runner configuration, and selected RustFS data.

### 8.2 Backup limitations

- GitLab's native backup does not include every external configuration file.
- Registry image backup was disabled in the previously recorded native backup run. Plan a separate recovery method if the Container Registry is used.
- Archiving RustFS data while it is actively changing may produce an inconsistent copy. Use a consistent, supported backup method for object storage.
- A backup stored on the same host does not protect against total host or disk failure.
- Checksums detect changes relative to the checksum file but do not prove that restoration will succeed.
- Backup coverage must be reviewed whenever services, volumes, or configuration locations change.

## 9. Backup Permissions

Backups may contain application data, configuration, and secrets.

Check permissions:

```bash
stat -c '%A %U:%G %n' \
  /opt/gitlab-stack/.env \
  /opt/gitlab-stack/backups
```

Restrict access to authorized administrators. Do not make backup files world-readable or store secret-bearing archives in an unrestricted repository.

## 10. systemd Backup Service

Service:

```text
/etc/systemd/system/gitlab-stack-backup.service
```

The one-shot service runs the backup script.

Inspect the installed unit:

```bash
systemctl cat gitlab-stack-backup.service
systemctl status gitlab-stack-backup.service --no-pager
```

Review its logs:

```bash
journalctl -u gitlab-stack-backup.service -n 100 --no-pager
```

A completed one-shot service may show `inactive (dead)` after execution. Check its result and logs rather than treating that state alone as a failure.

## 11. systemd Backup Timer

Timer:

```text
/etc/systemd/system/gitlab-stack-backup.timer
```

The recorded schedule is daily at 02:00 server local time, with persistent scheduling enabled.

Enable or reload the timer only after confirming the installed unit files:

```bash
systemctl daemon-reload
systemctl enable --now gitlab-stack-backup.timer
```

Check its state:

```bash
systemctl status gitlab-stack-backup.timer --no-pager
systemctl list-timers gitlab-stack-backup.timer
```

Trigger a manual backup:

```bash
systemctl start gitlab-stack-backup.service
```

Review the latest run:

```bash
systemctl status gitlab-stack-backup.service --no-pager
journalctl -u gitlab-stack-backup.service -n 100 --no-pager
```

A manual service run and the timer's scheduled trigger are separate events.

## 12. Local Backup Retention

The script is configured to retain the seven most recent local backup sets.

List backups:

```bash
ls -lht /opt/gitlab-stack/backups
```

Check disk usage:

```bash
du -sh /opt/gitlab-stack/backups
df -h
```

Local retention does not automatically remove remote RustFS objects. Remote retention must be defined and tested separately before enabling remote deletion.

## 13. RustFS Upload and Verification

The configured backup bucket is:

```text
gitlab-backups
```

The intended object prefix is:

```text
stack-<timestamp>/
```

The script uses an AWS CLI container and an S3-compatible endpoint to upload backup files and list objects.

For a manual listing, use the configured credentials securely:

```bash
aws --endpoint-url "$RUSTFS_ENDPOINT" \
  s3 ls s3://gitlab-backups/ --recursive
```

This example assumes that `RUSTFS_ENDPOINT` and the required AWS-compatible credentials are already configured in the environment.

Do not place access keys directly in commands or documentation.

Successful upload and object listing were reported in earlier tests. Repeat the check after relevant changes and as part of routine backup monitoring.

## 14. Backup Integrity Verification

Find the newest local backup set:

```bash
LATEST="$(find /opt/gitlab-stack/backups \
  -maxdepth 1 -type d -name 'stack-*' \
  -printf '%T@ %p\n' |
  sort -nr |
  head -1 |
  cut -d' ' -f2-)"

if [ -z "$LATEST" ]; then
  echo "ERROR: No backup set found"
  exit 1
fi

echo "Latest backup: $LATEST"
```

Verify checksums:

```bash
cd "$LATEST"
sha256sum -c SHA256SUMS
```

Check whether the configuration archive can be listed:

```bash
tar -tzf "$LATEST/stack-data.tar.gz" >/dev/null &&
  echo "Configuration archive: OK"
```

Check for expected GitLab configuration paths:

```bash
tar -tzf "$LATEST/stack-data.tar.gz" |
  grep -E 'gitlab/config/(gitlab\.rb|gitlab-secrets\.json)$'
```

The last command assumes that the archive preserves those path names. Adjust the pattern if the archive layout differs.

A successful checksum and archive-listing test is useful, but a complete restore test is still required.

## 15. Recovery and Rollback

**The documented recovery procedure has not yet been validated by a complete isolated restore test.**

### 15.1 Preparation

Before attempting recovery:

- Record the incident and its impact.
- Record current image versions.
- Preserve the current state with a fresh backup if services are accessible.
- Identify the intended recovery point.
- Verify that the backup files are complete.
- Confirm the matching GitLab configuration and secrets.
- Ensure that the recovery environment cannot overwrite production data.

### 15.2 Isolated restore

Perform the first restore in a separate test environment. It must use compatible GitLab software and must not connect to production storage or overwrite production data.

Restore the native GitLab backup and its matching configuration, including the required GitLab secrets file, using the procedure supported by the deployed GitLab version.

### 15.3 Validation

Verify that:

- GitLab services start successfully.
- Users can authenticate.
- Repositories and commits are available.
- Required application configuration is present.
- Runner connectivity works.
- A test CI job executes successfully.
- The restored data matches the intended recovery point.

Record the commands and results from the successful restore test.

### 15.4 Production recovery warning

Do not assume that changing a GitLab image tag to an older version is a safe rollback. Database migrations and version compatibility matter. Use a compatible GitLab version and a consistent backup set.

## 16. Disaster Recovery Limitations

GitLab and RustFS are currently associated with the same host environment. A host, disk, or severe system failure may affect both the application and its backup copy.

Remaining improvements:

1. Configure an independent off-host backup destination.
2. Define remote retention and lifecycle rules.
3. Test restoring from RustFS rather than only from local files.
4. Plan registry backup if the Container Registry is used.
5. Measure recovery time and acceptable data loss after restore testing.
6. Monitor scheduled backup and upload failures.
7. Review backup coverage when the deployment changes.

## 17. Troubleshooting

### Container status

```bash
docker ps -a
```

### GitLab logs

```bash
docker logs --tail 100 gitlab
```

### Runner logs

```bash
docker logs --tail 100 gitlab-runner
```

### Notifier logs

```bash
docker logs --tail 100 gitlab-notifier
```

### Mailpit logs

```bash
docker logs --tail 100 mailpit
```

### Backup service logs

```bash
journalctl -u gitlab-stack-backup.service -n 100 --no-pager
```

### Disk space

```bash
df -h
du -sh /opt/gitlab-stack/*
```

### Compose validation

```bash
cd /opt/gitlab-stack
docker compose config --quiet
```

Before restarting or recreating a service, identify the failure and check its persistent mounts. Avoid deleting volumes or running destructive cleanup commands without a recovery plan.

## 18. Implementation Status

This table reflects the state recorded in the available deployment notes. Recheck the live environment before relying on it.

| Task | Recorded status |
|---|---|
| GitLab CE deployment | Completed |
| GitLab Runner deployment and registration | Completed |
| RustFS deployment | Completed |
| Native GitLab backup | Tested |
| Configuration archive | Tested |
| SHA-256 verification | Tested |
| RustFS upload and object listing | Tested |
| Daily systemd timer | Enabled |
| Seven-set local retention | Configured |
| Mailpit test inbox | Configured |
| Notifier container | Configured |
| Login notification path | Active in latest notes; verify end-to-end |
| Pipeline webhook | Configured; verify delivery and email end-to-end |
| Mail delivery to Mailpit | Test with a new event and confirm inbox receipt |
| Persistent Mailpit history | Verify current volume configuration |
| Remote backup retention | Pending |
| Independent off-host backup | Pending |
| Isolated restore test | Pending |
| Rollback validation | Pending |

## 19. Operational Checklists

### Routine checks

- [ ] Confirm GitLab, Runner, notifier, Mailpit, and RustFS are healthy.
- [ ] Review notifier logs for delivery failures.
- [ ] Verify pipeline webhook delivery when testing CI notifications.
- [ ] Confirm expected test emails appear in Mailpit.
- [ ] Confirm the backup timer is enabled.
- [ ] Review the latest backup service result.
- [ ] Verify the latest backup checksums.
- [ ] Confirm uploaded RustFS objects are accessible.
- [ ] Monitor disk usage and backup growth.
- [ ] Confirm credentials remain protected.

### Before an upgrade

- [ ] Create and verify a fresh backup.
- [ ] Record current image versions.
- [ ] Review application and database compatibility.
- [ ] Confirm the backup is accessible independently of the application being upgraded.
- [ ] Preserve the current Compose and service configuration.
- [ ] Ensure a documented recovery procedure is available.

### Before relying on disaster recovery

- [ ] Complete an isolated restore test.
- [ ] Verify GitLab data and configuration.
- [ ] Verify Runner connectivity and a test CI job.
- [ ] Test restoration from an independent backup destination.
- [ ] Document recovery results and remaining limitations.

## 20. Conclusion

The stack includes GitLab CE, GitLab Runner, RustFS-backed backup storage, a configured notifier, and Mailpit for inspecting test email. The documented backup workflow creates a native GitLab archive, captures selected configuration, generates checksums, uploads backup files to RustFS, and applies local retention.

Email notification paths include login-event forwarding and GitLab pipeline webhooks. These paths must be tested separately: successful webhook delivery does not guarantee that an email reached Mailpit.

The main outstanding disaster-recovery work is to complete an isolated restore test, establish independent off-host backups, and define remote retention. Continue to protect all credentials and use environment-specific endpoints only from the secured deployment configuration.

