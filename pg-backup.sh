#!/usr/bin/env bash
# Backup PostgreSQL: dump harian, base backup (untuk PITR), verifikasi restore, retensi.
#
#   sudo pg-backup.sh dump        # dump semua database + globals (roles), checksum, retensi
#   sudo pg-backup.sh basebackup  # base backup fisik; dipakai bersama arsip WAL untuk PITR
#   sudo pg-backup.sh verify      # RESTORE dump terakhir ke database sementara & bandingkan jumlah baris
#   sudo pg-backup.sh all         # dump + basebackup + verify (dipanggil timer harian)
#
# Variabel: DEST (default /var/backups/pg), KEEP_DAYS (default 7)
set -euo pipefail

DEST=${DEST:-/var/backups/pg}
KEEP_DAYS=${KEEP_DAYS:-7}
export PGOPTIONS='--client-min-messages=warning' # sembunyikan NOTICE "database does not exist, skipping"
PGU=(runuser -u postgres --)
psql_q() { "${PGU[@]}" psql -qAtX "$@"; }
stamp() { date +%Y%m%d-%H%M%S; }
log() { echo "[$(date +%T)] $*"; }

[[ $EUID -eq 0 ]] || { echo "Jalankan sebagai root (sudo)."; exit 1; }
# DEST harus bisa DILEWATI user postgres (x untuk group), kalau tidak arsip WAL gagal tanpa suara
install -d -m 750 -o root -g postgres "$DEST"
install -d -m 700 "$DEST/dump" "$DEST/base"
install -d -m 700 -o postgres -g postgres "$DEST/wal" # arsip WAL ditulis oleh user postgres

prune() {
  find "$DEST/dump" "$DEST/base" -mindepth 1 -maxdepth 1 -mtime +"$KEEP_DAYS" -exec rm -rf {} +
  find "$DEST/wal" -type f -mtime +$((KEEP_DAYS + 1)) -delete # WAL yang lebih tua dari base backup tertua tidak berguna
}

dump() {
  local s tmp db
  s=$(stamp)
  tmp="$DEST/dump/$s.tmp"
  mkdir -p "$tmp"
  "${PGU[@]}" pg_dumpall --globals-only >"$tmp/globals.sql"
  for db in $(psql_q -c "SELECT datname FROM pg_database WHERE NOT datistemplate AND datname NOT LIKE 'verify\_%'"); do
    "${PGU[@]}" pg_dump -Fc "$db" >"$tmp/$db.dump"
    log "dump $db: $(du -h "$tmp/$db.dump" | cut -f1)"
  done
  (cd "$tmp" && sha256sum ./* >SHA256SUMS)
  chmod 600 "$tmp"/*
  mv "$tmp" "$DEST/dump/$s" # rename di akhir: dump yang setengah jadi tidak pernah terlihat sebagai backup valid
  date +%s >"$DEST/last-dump"
  prune
  log "dump selesai: $DEST/dump/$s"
}

basebackup() {
  local s dir
  s=$(stamp)
  dir="$DEST/base/$s.tmp"
  mkdir -p "$dir"
  "${PGU[@]}" pg_basebackup -D - -Ft -X fetch | gzip >"$dir/base.tar.gz"
  [[ ${PIPESTATUS[0]} -eq 0 ]] || { rm -rf "$dir"; echo "pg_basebackup gagal"; exit 1; }
  chmod 600 "$dir/base.tar.gz"
  mv "$dir" "$DEST/base/$s"
  date +%s >"$DEST/last-base"
  log "base backup selesai: $DEST/base/$s ($(du -h "$DEST/base/$s/base.tar.gz" | cut -f1))"
}

verify() {
  local latest f db rdb t a b bad=0 tables
  latest=$(find "$DEST/dump" -mindepth 1 -maxdepth 1 -type d ! -name '*.tmp' | sort | tail -1)
  [[ -n $latest ]] || { echo "Belum ada dump untuk diverifikasi."; exit 1; }
  (cd "$latest" && sha256sum -c --quiet SHA256SUMS) || { echo "CHECKSUM TIDAK COCOK: $latest"; exit 1; }
  log "checksum OK: $latest"
  for f in "$latest"/*.dump; do
    db=$(basename "$f" .dump)
    rdb="verify_$db"
    psql_q -c "DROP DATABASE IF EXISTS \"$rdb\"" -c "CREATE DATABASE \"$rdb\"" >/dev/null
    if ! "${PGU[@]}" pg_restore --no-owner -d "$rdb" <"$f" 2>/dev/null; then
      log "GAGAL restore $db"; bad=1; continue
    fi
    tables=$(psql_q -d "$db" -c "SELECT format('%I.%I', schemaname, tablename) FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema')")
    for t in $tables; do
      a=$(psql_q -d "$db" -c "SELECT count(*) FROM $t")
      b=$(psql_q -d "$rdb" -c "SELECT count(*) FROM $t" 2>/dev/null || echo -1)
      # baris di sumber boleh bertambah sejak dump, tapi hasil restore tidak boleh kosong atau lebih banyak
      if ((b < 0 || b > a || (a > 0 && b == 0))); then log "TIDAK COCOK $db.$t: sumber=$a restore=$b"; bad=1
      else log "restore OK $db.$t: $b baris (sumber: $a)"; fi
    done
    psql_q -c "DROP DATABASE \"$rdb\"" >/dev/null
  done
  ((bad == 0)) || { echo "VERIFIKASI GAGAL"; exit 1; }
  date +%s >"$DEST/last-verify"
  log "verifikasi restore lulus"
}

case "${1:-}" in
  dump) dump ;;
  basebackup) basebackup ;;
  verify) verify ;;
  all) dump; basebackup; verify ;;
  *) echo "Usage: $0 dump|basebackup|verify|all"; exit 1 ;;
esac
