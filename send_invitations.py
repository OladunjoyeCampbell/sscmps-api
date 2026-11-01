"""
send_invitations.py — batch-invite remaining cooperative members.
Uses Supabase /auth/v1/invite endpoint. Writes CSV incrementally,
handles per-email errors gracefully.
"""

import os
import sys
import time
import csv
from datetime import datetime
import requests

SUPABASE_URL = os.environ.get("SUPABASE_URL")
SERVICE_KEY  = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
if not SUPABASE_URL or not SERVICE_KEY:
    raise SystemExit("Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY in env")

HEADERS = {
    "apikey": SERVICE_KEY,
    "Authorization": f"Bearer {SERVICE_KEY}",
    "Content-Type": "application/json",
}
RATE_LIMIT_SECONDS = 1.0


def get_members():
    r = requests.get(
        f"{SUPABASE_URL}/rest/v1/members",
        headers=HEADERS,
        params={
            "select": "registration_number,first_name,last_name,email,auth_user_id,role,status",
            "status": "eq.Active",
            "order": "registration_number",
        },
        timeout=30,
    )
    r.raise_for_status()
    return r.json()


def get_auth_users():
    users, page = [], 1
    while True:
        r = requests.get(
            f"{SUPABASE_URL}/auth/v1/admin/users",
            headers=HEADERS,
            params={"page": page, "per_page": 200},
            timeout=30,
        )
        r.raise_for_status()
        batch = r.json().get("users", [])
        if not batch:
            break
        users.extend(batch)
        if len(batch) < 200:
            break
        page += 1
    return users


def invite(email, attempt=1):
    """Send invitation. Correct endpoint: /auth/v1/invite. Retries once on connection error."""
    try:
        r = requests.post(
            f"{SUPABASE_URL}/auth/v1/invite",
            headers=HEADERS,
            json={"email": email},
            timeout=30,
        )
        if r.status_code == 200:
            return True, "invited", r.json().get("id")
        try:
            j = r.json()
            msg = j.get("msg") or j.get("message") or j.get("error_description") or r.text[:200]
        except Exception:
            msg = f"HTTP {r.status_code}: {r.text[:200]}"
        return False, msg, None
    except requests.exceptions.ConnectionError as e:
        if attempt == 1:
            time.sleep(2)
            return invite(email, attempt=2)
        return False, f"connection error after retry: {e}", None
    except Exception as e:
        return False, f"{type(e).__name__}: {e}", None


def main():
    include_officers = "--include-officers" in sys.argv
    do_send = "--send" in sys.argv

    print("Fetching members and auth users...")
    members = get_members()
    auth_users = get_auth_users()
    print(f"  Active members: {len(members)}")
    print(f"  Auth users:     {len(auth_users)}")

    auth_by_email = {(u.get("email") or "").lower(): u for u in auth_users if u.get("email")}

    to_invite, already_confirmed, skipped_officers, skipped_no_email = [], 0, 0, 0
    for m in members:
        reg = m.get("registration_number", "????")
        email = (m.get("email") or "").strip()
        if not include_officers and m.get("role") != "Member":
            skipped_officers += 1
            continue
        if not email:
            skipped_no_email += 1
            continue
        au = auth_by_email.get(email.lower())
        if au and au.get("email_confirmed_at"):
            already_confirmed += 1
            continue
        to_invite.append({**m, "_existing_auth": au})

    print(f"\n  Already confirmed:     {already_confirmed}")
    print(f"  Skipped (officers):    {skipped_officers}")
    print(f"  Skipped (no email):    {skipped_no_email}")
    print(f"  → To invite now:       {len(to_invite)}")

    if not to_invite:
        print("\nNothing to do.")
        return

    if not do_send:
        print("\n" + "=" * 70)
        print("DRY RUN — no emails sent.")
        print("=" * 70)
        for m in to_invite:
            status = "resend" if m["_existing_auth"] else "new"
            print(f"  [{status:6}] {m['registration_number']} {m['first_name']} {m['last_name']:<22} <{m['email']}>")
        print(f"\nTo actually send, re-run with --send")
        return

    print(f"\nAbout to send {len(to_invite)} invitation emails via Resend.")
    if input("Type 'SEND' to confirm: ").strip() != "SEND":
        print("Aborted.")
        return

    stamp = datetime.now().strftime("%Y%m%d-%H%M")
    logfile = f"invitations-{stamp}.csv"
    print(f"\nSending. Log: {logfile}\n" + "=" * 70)

    # Open CSV for incremental writes
    f = open(logfile, "w", newline="", encoding="utf-8")
    writer = csv.writer(f)
    writer.writerow(["registration_number", "name", "email", "status", "detail", "user_id", "timestamp"])

    sent_count, failed_count = 0, 0
    failed_details = []

    for i, m in enumerate(to_invite, 1):
        email = m["email"].strip()
        is_resend = m["_existing_auth"] is not None
        label = f"[{i:>2}/{len(to_invite)}] {m['registration_number']} {m['first_name']} {m['last_name']}"
        print(f"{label:<55} <{email}>... ", end="", flush=True)

        try:
            ok, msg, user_id = invite(email)
        except Exception as e:
            ok, msg, user_id = False, f"UNCAUGHT: {type(e).__name__}: {e}", None

        if ok:
            status = "invited-resend" if is_resend else "invited-new"
            sent_count += 1
        else:
            status = "failed"
            failed_count += 1
            failed_details.append((m["registration_number"], f"{m['first_name']} {m['last_name']}", email, msg))

        print(status)

        # Write each row immediately so we never lose partial progress
        writer.writerow([
            m["registration_number"],
            f"{m['first_name']} {m['last_name']}",
            email,
            status,
            msg,
            user_id or "",
            datetime.now().isoformat(),
        ])
        f.flush()

        if i < len(to_invite):
            time.sleep(RATE_LIMIT_SECONDS)

    f.close()
    print("\n" + "=" * 70)
    print(f"Sent:   {sent_count}")
    print(f"Failed: {failed_count}")
    print(f"Log:    {logfile}")

    if failed_details:
        print("\nFailures:")
        for reg, name, email, msg in failed_details:
            print(f"  {reg} {name} <{email}>")
            print(f"      {msg}")


if __name__ == "__main__":
    main()