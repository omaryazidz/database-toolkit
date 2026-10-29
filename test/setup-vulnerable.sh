#!/usr/bin/env bash
# PostgreSQL + database toko online dengan kesalahan konfigurasi yang umum ditemukan di server klien.
# HANYA untuk VM lab. Semua kredensial dan data di dalamnya palsu.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1
[[ $EUID -eq 0 ]] || { echo "Jalankan sebagai root."; exit 1; }

apt-get update -qq
apt-get install -y -qq postgresql postgresql-contrib >/dev/null
read -r VER CLUSTER _ < <(pg_lsclusters -h | head -1)
CONF=/etc/postgresql/$VER/$CLUSTER
P() { runuser -u postgres -- psql -qAtX -v ON_ERROR_STOP=1 "$@"; }

# --- kesalahan umum: hash md5, listen di semua interface, tanpa SSL ---
P -c "ALTER SYSTEM SET password_encryption = 'md5'" -c "ALTER SYSTEM SET listen_addresses = '*'" \
  -c "ALTER SYSTEM SET ssl = off" >/dev/null
P -c "SELECT pg_reload_conf()" >/dev/null
sleep 1
P -c "ALTER ROLE postgres PASSWORD 'postgres'" >/dev/null
P -c "CREATE ROLE appuser LOGIN SUPERUSER PASSWORD 'toko123'" >/dev/null # aplikasi berjalan sebagai superuser
P -c "CREATE DATABASE appdb OWNER appuser" >/dev/null

# --- kesalahan umum: terbuka ke seluruh internet ---
cat >"$CONF/pg_hba.conf" <<'EOF'
local   all             postgres                                peer
local   all             all                                     peer
host    all             all             0.0.0.0/0               md5
host    all             all             ::/0                    md5
EOF
pg_ctlcluster "$VER" "$CLUSTER" restart
sleep 2

# --- data toko: 50 ribu pelanggan, 2 juta pesanan (hanya primary key, tanpa index lain) ---
P -d appdb <<'SQL'
SET ROLE appuser;
CREATE TABLE customers (id serial PRIMARY KEY, name text NOT NULL, email text NOT NULL);
INSERT INTO customers (name, email)
  SELECT 'Pelanggan ' || g, 'pelanggan' || g || '@example.com' FROM generate_series(1, 50000) g;
CREATE TABLE orders (
  id bigserial PRIMARY KEY, customer_id int NOT NULL, status text NOT NULL,
  amount numeric(12,2) NOT NULL, created_at timestamptz NOT NULL);
INSERT INTO orders (customer_id, status, amount, created_at)
  SELECT 1 + (random() * 49999)::int,
         (ARRAY['baru','dibayar','dikirim','selesai'])[1 + (random() * 3)::int],
         round((random() * 900000 + 10000)::numeric, 2),
         now() - (random() * 365) * interval '1 day'
  FROM generate_series(1, 2000000);
ANALYZE;
SQL
echo "setup-ok: $(P -d appdb -c 'SELECT count(*) FROM orders') pesanan"
