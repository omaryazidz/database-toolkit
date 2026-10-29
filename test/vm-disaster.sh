#!/usr/bin/env bash
# Simulasi bencana: tabel produksi terhapus karena salah perintah, lalu dipulihkan dengan PITR.
# Usage (di dalam VM, root): bash vm-disaster.sh
set -uo pipefail
G=$'\e[32m' R=$'\e[31m' N=$'\e[0m'
Q() { runuser -u postgres -- psql -qAtX -d appdb "$@"; }
count() { Q -c "SELECT count(*) FROM orders"; }

echo "1. Kondisi normal         : $(count) pesanan (backup malam tadi berisi 2.000.000)"
Q -c "INSERT INTO orders(customer_id,status,amount,created_at) SELECT 1,'baru',100000,now() FROM generate_series(1,500)"
echo "2. Pesanan baru masuk     : $(count) pesanan (500 pesanan ini TIDAK ada di backup malam)"
sleep 2
T=$(date '+%F %T%z')
sleep 1
Q -c "SELECT pg_switch_wal()" >/dev/null # pastikan WAL sampai titik ini sudah diarsipkan
sleep 3
echo "3. Titik waktu aman       : $T"

Q -c "DROP TABLE orders" >/dev/null
echo "4. ${R}BENCANA${N}: DROP TABLE orders dijalankan di production"
echo "   Cek tabel orders       : $(Q -c 'SELECT count(*) FROM orders' 2>&1 | head -1)"

echo "5. Memulihkan ke $T ..."
/usr/local/bin/pg-pitr-restore.sh "$T" 2>&1 | sed 's/^/   /'

after=$(count)
marker=$(Q -c "SELECT count(*) FROM orders WHERE status='baru' AND customer_id=1 AND amount=100000")
echo "6. Setelah pemulihan      : $after pesanan"
if [[ $after == 2000500 ]]; then echo "${G}[PASS]${N} semua 2.000.500 pesanan kembali, termasuk 500 yang tidak ada di backup malam"
else echo "${R}[FAIL]${N} jumlah pesanan $after, seharusnya 2000500"; fi
[[ $marker -ge 500 ]] && echo "${G}[PASS]${N} 500 pesanan terakhir sebelum bencana ikut pulih" || echo "${R}[FAIL]${N} pesanan terakhir hilang"
