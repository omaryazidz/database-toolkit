#!/usr/bin/env bash
# PostgreSQL: audit & perbaikan keamanan, tuning performa, dan backup otomatis (termasuk PITR).
# Untuk Ubuntu/Debian dengan PostgreSQL dari apt (cluster pertama dari pg_lsclusters).
#
#   sudo ./pg-setup.sh audit                    # cek saja, tidak mengubah apa pun
#   sudo ./pg-setup.sh apply                    # perbaiki yang FAIL
#
# Variabel opsional untuk apply:
#   ALLOW_CIDR=10.0.0.0/24 APP_DB=appdb APP_USER=appuser   izinkan server aplikasi (hostssl + scram)
#   STORAGE=ssd|hdd         default ssd (mempengaruhi random_page_cost)
#   SLOW_MS=500             ambang slow query log
#   ROTATE_PASSWORDS=1      role dengan hash md5 diberi password acak baru (WAJIB update aplikasi!)
set -uo pipefail

MODE="${1:-audit}"
DEST=${DEST:-/var/backups/pg}
STORAGE=${STORAGE:-ssd}
SLOW_MS=${SLOW_MS:-500}
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
TS=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="/var/backups/pg-setup-$TS"

if [[ -t 1 || -n ${FORCE_COLOR:-} ]]; then G=$'\e[32m' R=$'\e[31m' Y=$'\e[33m' N=$'\e[0m'; else G='' R='' Y='' N=''; fi
warn() { echo "  ${Y}[WARN]${N} $*"; }

[[ $EUID -eq 0 ]] || { echo "Jalankan sebagai root (sudo)."; exit 1; }
case "$MODE" in audit|apply) ;; *) echo "Usage: $0 audit|apply"; exit 1 ;; esac
command -v pg_lsclusters >/dev/null || { echo "PostgreSQL (apt) tidak ditemukan."; exit 1; }
read -r VER CLUSTER _ _ _ DATA _ < <(pg_lsclusters -h | head -1)
[[ -n ${VER:-} ]] || { echo "Tidak ada cluster PostgreSQL."; exit 1; }
CONF_DIR=/etc/postgresql/$VER/$CLUSTER
HBA=$CONF_DIR/pg_hba.conf

psql_q() { runuser -u postgres -- psql -qAtX "$@"; }
sql() { psql_q -c "$1" 2>/dev/null; }
setting() { sql "SELECT setting FROM pg_settings WHERE name='$1'"; }
bytes() { sql "SELECT setting::bigint * CASE unit WHEN '8kB' THEN 8192 WHEN 'kB' THEN 1024 WHEN 'MB' THEN 1048576 ELSE 1 END FROM pg_settings WHERE name='$1'"; }
RAM=$(awk '/MemTotal/ {print $2 * 1024}' /proc/meminfo)
RAM_MB=$((RAM / 1048576))
age_ok() { [[ -f $1 ]] && (($(date +%s) - $(<"$1") < $2)); } # file berisi epoch; umur < $2 detik

# ---------- Pemeriksaan ----------
audit_listen() { [[ $(setting listen_addresses) != *'*'* && $(setting listen_addresses) != *0.0.0.0* ]]; }
audit_hba() { # tidak ada aturan trust atau terbuka ke seluruh internet
  [[ $(sql "SELECT count(*) FROM pg_hba_file_rules WHERE auth_method='trust' OR address IN ('0.0.0.0','::','all') OR netmask IN ('0.0.0.0','::')") == 0 ]]
}
audit_scram() {
  [[ $(setting password_encryption) == scram-sha-256 && $(sql "SELECT count(*) FROM pg_authid WHERE rolpassword LIKE 'md5%'") == 0 ]]
}
audit_app_not_super() { [[ $(sql "SELECT count(*) FROM pg_roles WHERE rolsuper AND rolname <> 'postgres'") == 0 ]]; }
audit_logging() {
  [[ $(setting log_connections) == on && $(setting log_disconnections) == on && $(setting log_lock_waits) == on ]]
}
audit_slow_log() { local v; v=$(setting log_min_duration_statement); [[ $v =~ ^[0-9]+$ ]] && ((v <= 2000)); }
audit_pgss() {
  [[ $(setting shared_preload_libraries) == *pg_stat_statements* ]] &&
    [[ $(psql_q -d postgres -c "SELECT count(*) FROM pg_extension WHERE extname='pg_stat_statements'") == 1 ]]
}
audit_memory() {
  local sb ecs
  sb=$(bytes shared_buffers); ecs=$(bytes effective_cache_size)
  [[ -n $sb && -n $ecs ]] && ((sb * 100 >= RAM * 20 && ecs * 100 >= RAM * 50))
}
audit_wal() {
  local mw
  mw=$(bytes max_wal_size)
  [[ $(setting checkpoint_completion_target) == 0.9 && -n $mw ]] && ((mw >= 2147483648))
}
audit_archive() { # bukan hanya setelannya: pengarsipan terakhir tidak boleh gagal
  [[ $(setting archive_mode) == on && -n $(setting archive_command) && $(setting archive_command) != '(disabled)' ]] &&
    [[ $(sql "SELECT count(*) FROM pg_stat_archiver WHERE last_failed_time IS NOT NULL AND (last_archived_time IS NULL OR last_failed_time > last_archived_time)") == 0 ]]
}
audit_ssl() { [[ $(setting ssl) == on ]]; }
audit_backup_fresh() { age_ok "$DEST/last-dump" 93600 && age_ok "$DEST/last-base" 691200; } # dump < 26 jam, base < 8 hari
audit_restore_verified() { age_ok "$DEST/last-verify" 691200; }
audit_backup_timer() { systemctl is-enabled --quiet pg-backup.timer 2>/dev/null; }

# ---------- Perbaikan ----------
backup_config() {
  [[ -d $BACKUP_DIR ]] && return
  mkdir -p "$BACKUP_DIR" && cp -a "$CONF_DIR" "$BACKUP_DIR/conf" && cp -a "$DATA/postgresql.auto.conf" "$BACKUP_DIR/" 2>/dev/null
  chmod -R go-rwx "$BACKUP_DIR"
}
alter() { psql_q -c "ALTER SYSTEM SET $1 = '$2'" >/dev/null; }

fix_config() {
  local max_conn sb ecs maint work preload
  max_conn=$(setting max_connections)
  sb=$((RAM_MB / 4)); ecs=$((RAM_MB * 3 / 4))
  maint=$((RAM_MB / 16)); ((maint > 1024)) && maint=1024
  work=$((RAM_MB / 4 / (max_conn * 2))); ((work < 4)) && work=4
  preload=$(setting shared_preload_libraries)
  [[ $preload == *pg_stat_statements* ]] || preload="${preload:+$preload,}pg_stat_statements"

  alter listen_addresses localhost
  alter password_encryption scram-sha-256
  alter ssl on
  alter shared_buffers "${sb}MB"
  alter effective_cache_size "${ecs}MB"
  alter maintenance_work_mem "${maint}MB"
  alter work_mem "${work}MB"
  alter wal_buffers 16MB
  alter checkpoint_completion_target 0.9
  alter max_wal_size 4GB
  alter min_wal_size 1GB
  if [[ $STORAGE == ssd ]]; then alter random_page_cost 1.1; alter effective_io_concurrency 200; fi
  alter log_connections on
  alter log_disconnections on
  alter log_lock_waits on
  alter log_min_duration_statement "$SLOW_MS"
  alter log_line_prefix '%m [%p] %q%u@%d '
  alter shared_preload_libraries "$preload"
  install -d -m 750 -o root -g postgres "$DEST" # user postgres harus bisa melewati folder ini
  install -d -m 700 -o postgres -g postgres "$DEST/wal"
  alter wal_level replica
  alter archive_mode on
  alter archive_command "test ! -f $DEST/wal/%f && cp %p $DEST/wal/%f"
  alter archive_timeout 300 # batas kehilangan data maksimal untuk PITR: 5 menit
}

fix_hba() {
  {
    echo "# Managed by pg-setup.sh (versi sebelumnya di $BACKUP_DIR)"
    echo "local   all             postgres                                peer"
    echo "local   all             all                                     peer"
    echo "local   replication     all                                     peer"
    echo "host    all             all             127.0.0.1/32            scram-sha-256"
    echo "host    all             all             ::1/128                 scram-sha-256"
    if [[ -n ${ALLOW_CIDR:-} ]]; then
      echo "hostssl ${APP_DB:?APP_DB wajib diisi bersama ALLOW_CIDR}  ${APP_USER:?APP_USER wajib diisi}  $ALLOW_CIDR  scram-sha-256"
      alter listen_addresses "localhost,$(hostname -I | awk '{print $1}')"
    fi
  } >"$HBA"
  chown postgres:postgres "$HBA"
}

fix_roles() { # dipanggil setelah server restart dengan konfigurasi baru
  local r pw
  for r in $(sql "SELECT rolname FROM pg_roles WHERE rolsuper AND rolname <> 'postgres'"); do
    [[ $r =~ ^[a-z0-9_]+$ ]] || { warn "role '$r' dilewati (nama tidak standar)"; continue; }
    psql_q -c "ALTER ROLE \"$r\" NOSUPERUSER" >/dev/null &&
      warn "role '$r' tidak lagi superuser: pastikan aplikasi tetap berjalan"
  done
  for r in $(sql "SELECT rolname FROM pg_authid WHERE rolpassword LIKE 'md5%'"); do
    [[ $r =~ ^[a-z0-9_]+$ ]] || { warn "role '$r' dilewati (nama tidak standar)"; continue; }
    if [[ ${ROTATE_PASSWORDS:-0} == 1 ]]; then
      pw=$(openssl rand -hex 16)
      psql_q -c "ALTER ROLE \"$r\" PASSWORD '$pw'" >/dev/null
      (umask 077; echo "$r : $pw" >>"$BACKUP_DIR/credentials.txt")
      warn "password '$r' diganti, tersimpan di $BACKUP_DIR/credentials.txt. UPDATE konfigurasi aplikasi!"
    else
      warn "role '$r' masih memakai hash md5 (tidak bisa dikonversi tanpa password asli). Ganti password-nya, atau jalankan ulang dengan ROTATE_PASSWORDS=1"
    fi
  done
}

fix_ext() {
  local db
  for db in postgres $(sql "SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres'"); do
    psql_q -d "$db" -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements" >/dev/null
  done
}

fix_backup() {
  install -m 755 "$SCRIPT_DIR/pg-backup.sh" /usr/local/bin/pg-backup.sh
  install -m 755 "$SCRIPT_DIR/pg-pitr-restore.sh" /usr/local/bin/pg-pitr-restore.sh
  install -m 755 "$SCRIPT_DIR/pg-slowquery.sh" /usr/local/bin/pg-slowquery.sh
  cat >/etc/systemd/system/pg-backup.service <<EOF
[Unit]
Description=Backup PostgreSQL (dump, base backup, verifikasi restore)
[Service]
Type=oneshot
Environment=DEST=$DEST
ExecStart=/usr/local/bin/pg-backup.sh all
EOF
  cat >/etc/systemd/system/pg-backup.timer <<'EOF'
[Unit]
Description=Backup PostgreSQL harian
[Timer]
OnCalendar=*-*-* 02:30:00
RandomizedDelaySec=10min
Persistent=true
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now pg-backup.timer >/dev/null 2>&1
  DEST=$DEST /usr/local/bin/pg-backup.sh all
}

# ---------- Runner ----------
CHECKS=(listen hba scram app_not_super logging slow_log pgss memory wal archive ssl backup_fresh restore_verified backup_timer)
declare -A DESC=(
  [listen]="PostgreSQL tidak mendengarkan di semua interface (listen_addresses)"
  [hba]="pg_hba.conf: tidak ada aturan 'trust' atau terbuka ke 0.0.0.0/0"
  [scram]="Password memakai scram-sha-256 (tidak ada hash md5)"
  [app_not_super]="Tidak ada role aplikasi yang berstatus superuser"
  [logging]="Log koneksi, disconnect, dan lock wait aktif"
  [slow_log]="Slow query log aktif (log_min_duration_statement)"
  [pgss]="pg_stat_statements aktif untuk melacak query lambat"
  [memory]="Memori ditala (shared_buffers >= 20% RAM, effective_cache_size >= 50%)"
  [wal]="Checkpoint & WAL ditala (completion_target 0.9, max_wal_size >= 2GB)"
  [archive]="Arsip WAL aktif (syarat point-in-time recovery)"
  [ssl]="Koneksi terenkripsi SSL aktif"
  [backup_fresh]="Backup harian (dump + base backup) ada dan masih baru"
  [restore_verified]="Backup pernah DIUJI restore dalam 8 hari terakhir"
  [backup_timer]="Backup terjadwal otomatis (systemd timer)"
)
declare -A FIXES=(
  [listen]="config" [hba]="hba" [scram]="config roles" [app_not_super]="roles" [logging]="config"
  [slow_log]="config" [pgss]="config ext" [memory]="config" [wal]="config" [archive]="config"
  [ssl]="config" [backup_fresh]="backup" [restore_verified]="backup" [backup_timer]="backup"
)

run_audit() {
  local c rc pass=0 total=0
  [[ $(sql "SELECT 1") == 1 ]] || { echo "${R}PostgreSQL tidak bisa dihubungi, audit dibatalkan.${N}"; exit 1; }
  echo "== Audit PostgreSQL $VER $(hostname) (RAM ${RAM_MB}MB) - $(date '+%d %b %Y %H:%M:%S %Z') =="
  for c in "${CHECKS[@]}"; do
    "audit_$c"; rc=$?
    total=$((total + 1))
    if ((rc == 0)); then echo "  ${G}[PASS]${N} ${DESC[$c]}"; pass=$((pass + 1))
    else echo "  ${R}[FAIL]${N} ${DESC[$c]}"; fi
  done
  echo "== Skor: $pass/$total =="
}

run_apply() {
  local c f restart=0
  declare -A need=()
  for c in "${CHECKS[@]}"; do
    "audit_$c" && continue
    echo "  [FIX ] ${DESC[$c]}"
    for f in ${FIXES[$c]}; do need[$f]=1; done
  done
  ((${#need[@]})) || { echo; run_audit; return; }

  backup_config
  [[ -n ${need[config]:-} ]] && { fix_config; restart=1; }
  [[ -n ${need[hba]:-} ]] && { fix_hba; restart=1; }
  if ((restart)); then
    pg_ctlcluster "$VER" "$CLUSTER" restart || { warn "restart gagal, lihat /var/log/postgresql/"; return 1; }
    sleep 2
  fi
  [[ -n ${need[roles]:-} ]] && fix_roles
  [[ -n ${need[ext]:-} ]] && fix_ext
  [[ -n ${need[backup]:-} ]] && fix_backup
  echo "Backup konfigurasi lama: $BACKUP_DIR"
  echo
  run_audit
}

"run_$MODE"
