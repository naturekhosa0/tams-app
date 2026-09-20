#!/usr/bin/env bash
# Runs the foundation migration and its test suite against a throwaway
# local PostgreSQL database. Nothing here touches a Supabase project.
set -euo pipefail

DB_NAME="${TAMS_TEST_DB:-tams_foundation_test}"
PSQL_USER="${TAMS_TEST_SUPERUSER:-postgres}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

run_sql() { su "$PSQL_USER" -c "psql -v ON_ERROR_STOP=1 -X -q -d '$1' -f '$2'"; }

echo "Recreating $DB_NAME…"
su "$PSQL_USER" -c "dropdb --if-exists $DB_NAME"
su "$PSQL_USER" -c "createdb $DB_NAME"

echo "Applying the local Supabase stand-in (auth schema, database roles)…"
run_sql "$DB_NAME" "$ROOT/supabase/tests/00_local_auth_stub.sql"

echo "Applying the foundation migration…"
for migration in "$ROOT"/supabase/migrations/*.sql; do
  echo "  $(basename "$migration")"
  run_sql "$DB_NAME" "$migration"
done

echo "Running the tests…"
run_sql "$DB_NAME" "$ROOT/supabase/tests/01_test_helpers.sql"
for suite in "$ROOT"/supabase/tests/0[2-3]_*.sql; do
  echo "  $(basename "$suite")"
  run_sql "$DB_NAME" "$suite"
done

# The legacy import suite runs the real importer over the real CSV
# package in data/legacy-import. The payload goes via a file so that no
# shell quoting can touch it.
echo "  04_legacy_import_tests.sql (building the import payload from CSV)"
PAYLOAD_DIR="$(mktemp -d)"
trap 'rm -rf "$PAYLOAD_DIR"' EXIT
node "$ROOT/scripts/build-import-payload.mjs" "$ROOT/data/legacy-import" > "$PAYLOAD_DIR/payload.json"
chmod 755 "$PAYLOAD_DIR"
chmod 644 "$PAYLOAD_DIR/payload.json"

su "$PSQL_USER" -c "psql -v ON_ERROR_STOP=1 -X -q -d '$DB_NAME' \
  -v payload_path='$PAYLOAD_DIR/payload.json' \
  -f '$ROOT/supabase/tests/04_legacy_import_tests.sql'"

# Prints every result and fails the run if anything failed.
su "$PSQL_USER" -c "psql -v ON_ERROR_STOP=1 -X -d '$DB_NAME' -f '$ROOT/supabase/tests/99_report.sql'"
