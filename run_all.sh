#!/usr/bin/env bash
# Builds the whole project end-to-end on PostgreSQL 13+.
# Usage:  ./run_all.sh            (uses PGHOST/PGUSER/PGDATABASE env vars)
#         DB=readmit ./run_all.sh
set -euo pipefail
cd "$(dirname "$0")"

DB="${DB:-${PGDATABASE:-readmit}}"
PSQL="psql -d $DB -v ON_ERROR_STOP=1 -q"

if [ ! -f data/diabetic_data.csv ]; then
  echo ">> Downloading dataset from UCI..."
  ./data/download_data.sh
fi

echo ">> 1/6 schema";            $PSQL -f sql/01_schema.sql
echo ">> 2/6 lookups";           $PSQL -f sql/02_seed_lookups.sql
echo ">> 3/6 load raw CSV";      $PSQL -c "\copy hosp.stg_encounter FROM 'data/diabetic_data.csv' CSV HEADER"
echo ">> 4/6 transform";         $PSQL -f sql/03_transform.sql
echo ">> 5/6 views + PL/pgSQL";  $PSQL -f sql/04_views.sql -f sql/05_plpgsql.sql
echo ">> 6/6 tests";             $PSQL -f tests/run_tests.sql
echo ">> Running analysis -> docs/analysis_output.txt"
psql -d "$DB" -f sql/06_analysis.sql > docs/analysis_output.txt
echo ">> Done."
