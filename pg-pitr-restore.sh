#!/usr/bin/env bash
# Point-in-time recovery: pulihkan seluruh cluster ke titik waktu tertentu.
#
#   sudo ./pg-pitr-restore.sh "2026-10-29 03:15:00+00"
#
# Memakai base backup terbaru yang dibuat SEBELUM titik waktu itu, lalu memutar ulang arsip WAL.
# Data cluster lama TIDAK dihapus, hanya dipindah ke <data>.before-restore-<epoch>.
set -euo pipefail

TARGET=${1:?"Berikan titik waktu, mis. '2026-10-29 03:15:00+00' (sertakan zona waktu)"}
DEST=${DEST:-/var/backups/pg}
[[ $EUID -eq 0 ]] || { echo "Jalankan sebagai root (sudo)."; exit 1; }

read -r VER CLUSTER _ _ _ DATA _ < <(pg_lsclusters -h | head -1)
target_epoch=$(date -d "$TARGET" +%s) || { echo "Format waktu tidak valid: $TARGET"; exit 1; }

# base backup terbaru yang dibuat sebelum titik waktu target
BASE=""
for d in $(find "$DEST/base" -mindepth 1 -maxdepth 1 -type d | sort); do
  b_epoch=$(date -d "$(basename "$d" | sed -E 's/^([0-9]{4})([0-9]{2})([0-9]{2})-([0-9]{2})([0-9]{2})([0-9]{2})$/\1-\2-\3 \4:\5:\6/')" +%s)
  ((b_epoch <= target_epoch)) && BASE="$d/base.tar.gz"
done
[[ -n $BASE ]] || { echo "Tidak ada base backup sebelum $TARGET. Backup tersedia:"; ls "$DEST/base"; exit 1; }

echo "Cluster   : $VER/$CLUSTER ($DATA)"
echo "Base      : $BASE"
echo "Target    : $TARGET"

pg_ctlcluster "$VER" "$CLUSTER" stop
OLD="$DATA.before-restore-$(date +%s)"
mv "$DATA" "$OLD"
install -d -m 700 -o postgres -g postgres "$DATA"
tar -xzf "$BASE" -C "$DATA"
chown -R postgres:postgres "$DATA"

cat >>"$DATA/postgresql.auto.conf" <<EOF
restore_command = 'cp $DEST/wal/%f %p'
recovery_target_time = '$TARGET'
recovery_target_action = 'promote'
EOF
touch "$DATA/recovery.signal"
pg_ctlcluster "$VER" "$CLUSTER" start

echo -n "Memutar ulang WAL"
for _ in $(seq 120); do
  if [[ $(runuser -u postgres -- psql -qAtX -c "SELECT pg_is_in_recovery()" 2>/dev/null) == f ]]; then
    echo " selesai."
    # bersihkan setelan pemulihan supaya restart berikutnya normal
    runuser -u postgres -- psql -qAtX -c "ALTER SYSTEM RESET restore_command" \
      -c "ALTER SYSTEM RESET recovery_target_time" -c "ALTER SYSTEM RESET recovery_target_action" >/dev/null
    echo "Cluster dipulihkan ke $TARGET. Data lama disimpan di $OLD"
    exit 0
  fi
  echo -n .
  sleep 1
done
echo " GAGAL. Lihat log: /var/log/postgresql/postgresql-$VER-$CLUSTER.log"
echo "Untuk membatalkan dan kembali ke data sebelum restore:"
echo "  pg_ctlcluster $VER $CLUSTER stop; rm -rf $DATA; mv $OLD $DATA; pg_ctlcluster $VER $CLUSTER start"
exit 1
