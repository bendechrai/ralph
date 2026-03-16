#!/bin/bash
set -e

# Create test database alongside the main database
# This runs automatically on first postgres container start
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE DATABASE "${POSTGRES_DB}_test";
EOSQL

echo "Test database ${POSTGRES_DB}_test created successfully"
