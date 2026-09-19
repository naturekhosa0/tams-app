#!/usr/bin/env bash
# =====================================================================
# Creates the FIRST Council Administrator. Run once, by hand.
#
# Before running it:
#   1. Create the person's user in Supabase Auth yourself
#      (Dashboard -> Authentication -> Users -> Add user, with a
#      password, "Auto Confirm User" ticked). This is the only account
#      in the whole system created by hand.
#   2. Set the bootstrap secret on the server and deploy the function:
#        supabase secrets set TAMS_BOOTSTRAP_SECRET="$(openssl rand -hex 32)"
#        supabase functions deploy bootstrap-council-administrator
#
# Then run this script. It refuses if a Council Administrator already
# exists, so running it twice is harmless.
#
# When you are finished, remove the secret so the door is shut:
#        supabase secrets unset TAMS_BOOTSTRAP_SECRET
# =====================================================================
set -euo pipefail

: "${SUPABASE_URL:?Set SUPABASE_URL, e.g. https://your-ref.supabase.co}"
: "${SUPABASE_ANON_KEY:?Set SUPABASE_ANON_KEY (the public anon key)}"
: "${TAMS_BOOTSTRAP_SECRET:?Set TAMS_BOOTSTRAP_SECRET (the same value as the server secret)}"

EMPLOYEE_NUMBER="${1:?Usage: $0 <employee-number> <first-name> <surname> <email> <contact-number>}"
FIRST_NAME="${2:?Missing first name}"
LAST_NAME="${3:?Missing surname}"
EMAIL="${4:?Missing email address}"
CONTACT_NUMBER="${5:?Missing contact number}"

curl --fail-with-body -sS -X POST \
  "${SUPABASE_URL%/}/functions/v1/bootstrap-council-administrator" \
  -H "Authorization: Bearer ${SUPABASE_ANON_KEY}" \
  -H "apikey: ${SUPABASE_ANON_KEY}" \
  -H "x-bootstrap-secret: ${TAMS_BOOTSTRAP_SECRET}" \
  -H "Content-Type: application/json" \
  -d "$(cat <<JSON
{
  "employee_number": "${EMPLOYEE_NUMBER}",
  "first_name": "${FIRST_NAME}",
  "last_name": "${LAST_NAME}",
  "email": "${EMAIL}",
  "contact_number": "${CONTACT_NUMBER}"
}
JSON
)"
echo
