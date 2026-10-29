#!/usr/bin/env bash
# Beban kerja toko online: 4 klien mencari pesanan milik pelanggan acak.
# Pemanasan 3 detik, lalu 3 kali pengukuran 8 detik; yang dilaporkan adalah MEDIAN (satu pengukuran di VM terlalu berisik).
# Usage (di dalam VM, root): bash vm-bench.sh "<label>"
set -euo pipefail
LABEL=${1:-uji}
PGBENCH=$(ls /usr/lib/postgresql/*/bin/pgbench | head -1)
cat >/tmp/q.sql <<'EOF'
\set cid random(1, 50000)
SELECT count(*), sum(amount) FROM orders WHERE customer_id = :cid;
EOF
chmod 644 /tmp/q.sql
run() { runuser -u postgres -- "$PGBENCH" -n -c 4 -j 2 -T "$1" -f /tmp/q.sql appdb 2>&1; }
run 3 >/dev/null

tps=(); lat=()
for _ in 1 2 3; do
  out=$(run 8)
  tps+=("$(awk '/^tps/ {printf "%.0f", $3}' <<<"$out")")
  lat+=("$(awk '/latency average/ {print $4}' <<<"$out")")
done
median() { printf '%s\n' "$@" | sort -n | sed -n 2p; }
printf '%-34s %8s query/detik   rata-rata %s ms/query   (3 pengukuran: %s)\n' \
  "$LABEL" "$(median "${tps[@]}")" "$(median "${lat[@]}")" "${tps[*]}"
