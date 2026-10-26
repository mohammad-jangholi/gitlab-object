import json
import os
import time
import smtplib
import threading
from email.message import EmailMessage
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

SMTP_HOST = os.getenv("SMTP_HOST", "mailpit")
SMTP_PORT = int(os.getenv("SMTP_PORT", "1025"))
MAIL_FROM = os.getenv("MAIL_FROM", "gitlab@behsacorp.com")
MAIL_TO = os.getenv("MAIL_TO", "root@behsacorp.com")
LOG_FILE = Path("/login-events/audit_json.log")
STATE_FILE = Path("/state/audit.offset")
SECRET_FILE = Path("/run/secrets/webhook_secret")

def send_email(subject, body):
    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = MAIL_FROM
    msg["To"] = MAIL_TO
    msg.set_content(body)

    with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=15) as smtp:
        smtp.send_message(msg)

def monitor_logins():
    # Start at the current end of the log to avoid replaying old events.
    inode = None
    offset = None

    while True:
        try:
            with LOG_FILE.open("r", encoding="utf-8", errors="replace") as f:
                current_inode = os.fstat(f.fileno()).st_ino

                if inode != current_inode or offset is None:
                    inode = current_inode
                    if STATE_FILE.exists() and inode == current_inode:
                        try:
                            offset = int(STATE_FILE.read_text().strip())
                        except Exception:
                            offset = None
                    if offset is None:
                        f.seek(0, os.SEEK_END)
                        offset = f.tell()

                if f.seek(0, os.SEEK_END) < offset:
                    offset = 0

                f.seek(offset)
                while True:
                    line = f.readline()
                    if not line:
                        break

                    offset = f.tell()
                    try:
                        event = json.loads(line)
                    except json.JSONDecodeError:
                        continue

                    if event.get("event_name") == "authenticated_with_password":
                        user = event.get("meta.user") or event.get("author_name", "unknown")
                        ip = event.get("meta.remote_ip", "unknown")
                        when = event.get("time", event.get("created_at", "unknown"))
                        client = event.get("meta.client_name", "unknown")
                        try:
                            send_email(
                                f"GitLab login: {user}",
                                f"Successful GitLab login\n\n"
                                f"User: {user}\nTime: {when}\nIP: {ip}\n"
                                f"Client: {client}\n"
                                f"GitLab: http://172.18.99.71\n"
                            )
                        except Exception as exc:
                            print(f"Login email failed: {exc}", flush=True)

                STATE_FILE.write_text(str(offset))
        except FileNotFoundError:
            pass
        except Exception as exc:
            print(f"Login monitor error: {exc}", flush=True)

        time.sleep(2)

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/webhook":
            self.send_error(404)
            return

        supplied = self.headers.get("X-Gitlab-Token", "")
        expected = SECRET_FILE.read_text().strip()
        if not supplied or not __import__("hmac").compare_digest(supplied, expected):
            self.send_error(403)
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length))
            if payload.get("object_kind") != "pipeline":
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"Ignored non-pipeline event")
                return

            project = payload.get("project", {}).get("path_with_namespace", "unknown")
            attrs = payload.get("object_attributes", {})
            status = attrs.get("status", "unknown")
            ref = attrs.get("ref", "unknown")
            user = payload.get("user", {}).get("username", "unknown")
            url = attrs.get("url") or payload.get("project", {}).get("web_url", "")
            duration = attrs.get("duration", "unknown")
            pipeline_id = attrs.get("id", "unknown")

            send_email(
                f"GitLab pipeline {status}: {project} ({ref})",
                f"Pipeline result\n\nProject: {project}\nBranch/ref: {ref}\n"
                f"Status: {status}\nUser: {user}\nDuration: {duration}\n"
                f"Pipeline ID: {pipeline_id}\nURL: {url}\n"
            )

            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"Notification sent")
        except Exception as exc:
            print(f"Webhook processing failed: {exc}", flush=True)
            self.send_error(500, "Notification failed")

    def log_message(self, fmt, *args):
        print(fmt % args, flush=True)

if __name__ == "__main__":
    threading.Thread(target=monitor_logins, daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
