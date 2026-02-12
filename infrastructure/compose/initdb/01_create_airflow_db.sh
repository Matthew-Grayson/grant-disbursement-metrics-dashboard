#!/usr/bin/env bash
set -euo pipefail

AIRFLOW_DB_NAME="${AIRFLOW_DB_NAME:-airflow}"
OWNER_USER="${POSTGRES_USER:?POSTGRES_USER is not set}"

echo "Init: ensuring database '${AIRFLOW_DB_NAME}' exists (owner: '${OWNER_USER}')"

# Check if DB exists (returns name if found)
if psql -v ON_ERROR_STOP=1 --username "$OWNER_USER" --dbname "postgres" \
  -tAc "SELECT 1 FROM pg_database WHERE datname='${AIRFLOW_DB_NAME}'" | grep -q 1; then
  echo "Init: database '${AIRFLOW_DB_NAME}' already exists"
else
  echo "Init: creating database '${AIRFLOW_DB_NAME}'"
  createdb --username "$OWNER_USER" "$AIRFLOW_DB_NAME"
fi

# Ensure ownership/privileges (safe to re-run)
psql -v ON_ERROR_STOP=1 --username "$OWNER_USER" --dbname "postgres" <<SQL
ALTER DATABASE ${AIRFLOW_DB_NAME} OWNER TO ${OWNER_USER};
GRANT ALL PRIVILEGES ON DATABASE ${AIRFLOW_DB_NAME} TO ${OWNER_USER};
SQL

echo "Init: done"
