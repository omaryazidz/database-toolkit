#!/usr/bin/env bash
# Percobaan akses database dari LUAR server (seperti penyerang di internet).
# Usage: ./attack-demo.sh <host> <port> <password-postgres-lama> <password-appuser-lama>
HOST=${1:-127.0.0.1}; PORT=${2:-5433}; PW_PG=${3:-postgres}; PW_APP=${4:-toko123}
if [[ -t 1 || -n ${FORCE_COLOR:-} ]]; then R=$'\e[31m' G=$'\e[32m' N=$'\e[0m'; else R='' G='' N=''; fi
export PGCONNECT_TIMEOUT=5
q() { PGPASSWORD=$2 psql -qAtX -h "$HOST" -p "$PORT" -U "$1" -d "${3:-appdb}" -c "$4" 2>&1; }

echo "Target: $HOST:$PORT"
echo "1. Login dari internet memakai password umum"
out=$(q postgres "$PW_PG" postgres "select 'superuser ' || current_user")
if [[ $out == "superuser postgres" ]]; then
  echo "  ${R}[TERBUKA]${N} login sebagai superuser 'postgres' berhasil dari luar"
  echo "  ${R}[TERBUKA]${N} data pelanggan terbaca: $(q postgres "$PW_PG" appdb "select name || ' <' || email || '>' from customers limit 1")"
else echo "  ${G}[AMAN]${N}    ditolak: $(head -1 <<<"$out" | sed 's/^psql: error: //; s/connection to server at .* failed: //')"; fi

echo "2. Login sebagai akun aplikasi"
out=$(q appuser "$PW_APP" appdb "select rolsuper from pg_roles where rolname = current_user")
if [[ $out == t ]]; then echo "  ${R}[TERBUKA]${N} login 'appuser' berhasil dan akun ini superuser (bisa baca file server, menjalankan perintah)"
elif [[ $out == f ]]; then echo "  ${R}[TERBUKA]${N} login 'appuser' berhasil dari internet"
else echo "  ${G}[AMAN]${N}    ditolak: $(head -1 <<<"$out" | sed 's/^psql: error: //; s/connection to server at .* failed: //')"; fi

echo "3. Koneksi terenkripsi"
out=$(PGPASSWORD=$PW_APP PGSSLMODE=require psql -qAtX -h "$HOST" -p "$PORT" -U appuser -d appdb -c 'select 1' 2>&1 | head -1)
if [[ $out == 1 ]]; then echo "  ${G}[AMAN]${N}    SSL aktif"
elif [[ $out == *"SSL"* ]]; then echo "  ${R}[TERBUKA]${N} server tidak mendukung SSL: password dikirim tanpa enkripsi"
else echo "  ${G}[AMAN]${N}    tidak bisa dihubungi dari luar"; fi
