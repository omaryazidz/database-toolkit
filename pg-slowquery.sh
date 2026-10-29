#!/usr/bin/env bash
# Daftar query paling memakan waktu (dari pg_stat_statements).
#   sudo ./pg-slowquery.sh <database> [jumlah=5]
#   sudo ./pg-slowquery.sh <database> reset      # kosongkan statistik sebelum mengukur ulang
set -euo pipefail
DB=${1:?"Usage: $0 <database> [jumlah|reset]"}
ARG=${2:-5}
[[ $EUID -eq 0 ]] || { echo "Jalankan sebagai root (sudo)."; exit 1; }

if [[ $ARG == reset ]]; then
  runuser -u postgres -- psql -qAtX -d "$DB" -c "SELECT pg_stat_statements_reset()" >/dev/null
  echo "Statistik direset."
  exit 0
fi
[[ $ARG =~ ^[0-9]+$ ]] || { echo "Jumlah harus angka."; exit 1; }

runuser -u postgres -- psql -X -d "$DB" <<SQL
SELECT round(total_exec_time::numeric) AS total_ms,
       calls,
       round(mean_exec_time::numeric, 2) AS mean_ms,
       left(regexp_replace(query, '\s+', ' ', 'g'), 80) AS query
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
  AND query NOT ILIKE '%pg_stat_statements%'
ORDER BY total_exec_time DESC
LIMIT $ARG;
SQL
