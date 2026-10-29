#!/usr/bin/env bash
# Uji lengkap: VM baru -> database toko yang rentan -> serang, ukur, audit -> apply -> ulangi -> simulasi bencana.
# Layar tetap berwarna (untuk direkam), salinan polos disimpan ke results/.
# Jalankan di lab WSL:  sudo bash test/run-lab.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
mkdir -p results
KEY=/root/dblab/lab_key
SSHO=(-i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
SSH=(ssh -tt -q "${SSHO[@]}" -p 2224 sysadmin@127.0.0.1)
save() { tee >(sed 's/\x1b\[[0-9;]*m//g; s/\r$//' >"results/$1"); }
step() { echo; echo "##### $* #####"; }
vm() { "${SSH[@]}" "$@"; }

command -v psql >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq postgresql-client >/dev/null

if [[ ${1:-} != --no-setup ]]; then
  step "0. MENYIAPKAN SERVER DATABASE (PostgreSQL bawaan, 2 juta pesanan, belum diamankan)"
  bash test/lab-vm.sh down
  bash test/lab-vm.sh up || exit 1
  scp -q "${SSHO[@]}" -P 2224 pg-*.sh test/setup-vulnerable.sh test/vm-bench.sh test/vm-disaster.sh sysadmin@127.0.0.1:
  vm 'sudo bash setup-vulnerable.sh' >/dev/null 2>&1 || { echo "setup gagal"; exit 1; }
fi

step "1. AKSES DARI LUAR SEBELUM HARDENING"
FORCE_COLOR=1 bash test/attack-demo.sh 127.0.0.1 5433 postgres toko123 | save db-attack-before.txt
step "2. AUDIT SEBELUM"
vm 'sudo FORCE_COLOR=1 bash pg-setup.sh audit' | save db-audit-before.txt
step "3. BENCHMARK SEBELUM (konfigurasi bawaan, belum ada index)"
vm 'sudo bash vm-bench.sh "A. bawaan, tanpa index"' | save db-bench.txt
step "4. APPLY"
vm 'time sudo FORCE_COLOR=1 ROTATE_PASSWORDS=1 bash pg-setup.sh apply' | save db-apply.txt
step "5. BENCHMARK SESUDAH TUNING, LALU CARI QUERY LAMBAT"
vm 'sudo bash vm-bench.sh "B. sudah ditala, tanpa index"' | tee >(sed 's/\x1b\[[0-9;]*m//g; s/\r$//' >>results/db-bench.txt)
echo; echo "Query paling lambat menurut pg_stat_statements:"
vm 'sudo pg-slowquery.sh appdb 3' | save db-slowquery.txt
step "6. TAMBAH INDEX YANG DITEMUKAN, UKUR ULANG"
vm 'sudo runuser -u postgres -- psql -qAtX -d appdb -c "CREATE INDEX CONCURRENTLY orders_customer_id_idx ON orders(customer_id)" -c "ANALYZE orders" && echo "CREATE INDEX orders_customer_id_idx ON orders(customer_id)"'
vm 'sudo bash vm-bench.sh "C. ditala + index"' | tee >(sed 's/\x1b\[[0-9;]*m//g; s/\r$//' >>results/db-bench.txt)
step "7. AKSES DARI LUAR SESUDAH HARDENING (password lama)"
FORCE_COLOR=1 bash test/attack-demo.sh 127.0.0.1 5433 postgres toko123 | save db-attack-after.txt
step "8. BENCANA: DROP TABLE DI PRODUCTION, LALU PITR"
vm 'sudo bash vm-disaster.sh' | save db-disaster.txt
step "9. AUDIT SETELAH PEMULIHAN (konfigurasi harus tetap utuh)"
vm 'sudo FORCE_COLOR=1 bash pg-setup.sh audit' | save db-audit-after.txt
sleep 1 # tunggu tee di process substitution selesai menulis
