"""
bootstrap_admin.py — create an auth account for a user.
Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
Run: python bootstrap_admin.py --email <email>
"""
import argparse, os, secrets, sys
import requests

SUPABASE_URL = os.environ.get("SUPABASE_URL")
SERVICE_KEY  = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
if not SUPABASE_URL or not SERVICE_KEY:
    raise SystemExit("Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY in env")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--email", required=True)
    parser.add_argument("--password", help="Optional; secure password generated if omitted")
    args = parser.parse_args()
    password = args.password or secrets.token_urlsafe(18)

    print(f"Creating auth user for {args.email} ...")
    resp = requests.post(
        f"{SUPABASE_URL}/auth/v1/admin/users",
        headers={"apikey": SERVICE_KEY, "Authorization": f"Bearer {SERVICE_KEY}",
                 "Content-Type": "application/json"},
        json={"email": args.email, "password": password, "email_confirm": True},
    )
    if resp.status_code == 200 and resp.json().get("id"):
        print(f"✓ Auth user created")
        print(f"  user id:  {resp.json()['id']}")
        print(f"  email:    {args.email}")
        print(f"  password: {password}")
        print("\nSave the password — not shown again.")
    elif resp.status_code == 422 and "already" in resp.text.lower():
        print(f"⚠ Auth user for {args.email} already exists")
        sys.exit(1)
    else:
        print(f"✗ Failed: {resp.status_code}")
        print(resp.text)
        sys.exit(1)

if __name__ == "__main__":
    main()