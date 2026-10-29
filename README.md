# PostgreSQL: Keamanan, Tuning, Backup & Point-in-Time Recovery

Script untuk **mengaudit** lalu **menyiapkan** server PostgreSQL produksi: akses aman, performa ditala, backup otomatis yang **terbukti bisa direstore**, dan pemulihan ke titik waktu tertentu (PITR) saat ada yang salah menghapus data.

Kasus yang ditangani: database di VPS biasanya berjalan dengan konfigurasi bawaan atau dibuka seadanya agar aplikasi bisa terhubung. Aksesnya terbuka ke internet, aplikasi memakai akun superuser, tidak ada backup, dan kalau ada tabel terhapus tidak ada jalan kembali.

## Hasil uji (lab)

Diuji di VM **Ubuntu 24.04** (RAM 4 GB, cloud image resmi) dengan **PostgreSQL 16** dan database toko online berisi **50 ribu pelanggan dan 2 juta pesanan**. Server dibuat dengan kesalahan konfigurasi yang umum ditemukan di server klien. Semua kredensial dan data di dalamnya palsu.

**Skor audit: 0/14 → 14/14**. Proses apply sekitar 45 detik, sudah termasuk backup pertama dan uji restore.

### 1. Akses dari luar ([`test/attack-demo.sh`](test/attack-demo.sh))

| Percobaan | Sebelum | Sesudah |
|---|---|---|
| Login sebagai `postgres` dengan password umum | berhasil, data pelanggan terbaca | ditolak |
| Login sebagai akun aplikasi | berhasil, dan akunnya **superuser** | ditolak |
| Koneksi terenkripsi | SSL mati, password terkirim polos | tidak bisa dihubungi dari luar |

### 2. Bencana: `DROP TABLE` di production ([`test/vm-disaster.sh`](test/vm-disaster.sh))

```
1. Kondisi normal         : 2000000 pesanan (backup malam tadi berisi 2.000.000)
2. Pesanan baru masuk     : 2000500 pesanan (500 pesanan ini TIDAK ada di backup malam)
3. Titik waktu aman       : 2026-10-29 06:36:23+0000
4. BENCANA: DROP TABLE orders dijalankan di production
   Cek tabel orders       : ERROR:  relation "orders" does not exist
5. Memulihkan ke 2026-10-29 06:36:23+0000 ...
[PASS] semua 2.000.500 pesanan kembali, termasuk 500 yang tidak ada di backup malam
[PASS] 500 pesanan terakhir sebelum bencana ikut pulih
```

Restore dari backup biasa hanya mengembalikan kondisi malam tadi. Dengan PITR, data yang masuk setelah backup ikut kembali. Setelah pemulihan, audit tetap **14/14** (konfigurasi tidak rusak).

### 3. Query lambat ([`test/vm-bench.sh`](test/vm-bench.sh))

Beban kerja: 4 klien mencari pesanan milik pelanggan acak. Angka adalah **median dari 3 pengukuran** (pemanasan 3 detik, tiap pengukuran 8 detik).

| | Query/detik | Rata-rata per query |
|---|---:|---:|
| A. Konfigurasi bawaan, tanpa index | 4 | 1.013 ms |
| B. Sudah ditala, tanpa index | 5 | 857 ms |
| C. Ditala + index yang ditemukan `pg_stat_statements` | **2.811** | **1,4 ms** |

Yang menemukan penyebabnya adalah `pg_stat_statements` ([`pg-slowquery.sh`](pg-slowquery.sh)): satu query `WHERE customer_id = $1` yang melakukan seq scan di tabel 2 juta baris menghabiskan hampir seluruh waktu server. Index tunggal di `customer_id` memperbaikinya.

**Yang perlu dibaca jujur:**
- Pada beban kerja ini, **tuning memori saja tidak memberi perbedaan yang berarti** (A dan B hampir sama). Query-nya terikat CPU karena seq scan, dan datanya sudah muat di cache OS. Tuning memori membantu kasus lain, misalnya data yang jauh lebih besar dari RAM, banyak sorting, atau checkpoint berat. Pada jasa ini, tuning dijual bersama pencarian query lambat, bukan sebagai pengganti.
- Angka mutlak berubah-ubah antar-run di lab ini (C pernah terukur 5.000 sampai 16.000 query/detik pada run lain) karena VM berbagi CPU dengan laptop. Yang konsisten adalah perbandingannya: index membuat query ratusan sampai ribuan kali lebih cepat.

### 4. Backup yang dites ([`pg-backup.sh`](pg-backup.sh))

```
dump appdb: 43M            base backup selesai: 57M
checksum OK
restore OK appdb.public.customers: 50000 baris (sumber: 50000)
restore OK appdb.public.orders: 2000000 baris (sumber: 2000000)
verifikasi restore lulus
```

Backup yang tidak pernah dites restore bukan backup. Karena itu `verify` benar-benar me-restore dump ke database sementara dan membandingkan jumlah baris tiap tabel. Audit menandai FAIL kalau uji restore terakhir lebih dari 8 hari.

Output mentah semua uji ada di [`results/`](results/).

## Pemakaian

```bash
sudo ./pg-setup.sh audit    # cek saja, tidak mengubah apa pun
sudo ./pg-setup.sh apply    # perbaiki yang FAIL, pasang backup & jadwalnya
```

Opsi untuk `apply`:

```bash
# izinkan server aplikasi tertentu (hostssl + scram-sha-256), selain itu hanya localhost
sudo ALLOW_CIDR=10.0.0.0/24 APP_DB=appdb APP_USER=appuser ./pg-setup.sh apply
# role dengan hash md5 diberi password acak baru (WAJIB update konfigurasi aplikasi)
sudo ROTATE_PASSWORDS=1 ./pg-setup.sh apply
```

Pemulihan:

```bash
sudo pg-backup.sh verify                              # uji restore kapan saja
sudo pg-pitr-restore.sh "2026-10-29 03:15:00+00"      # pulihkan ke satu titik waktu
sudo pg-slowquery.sh appdb 5                          # 5 query paling lambat
```

## Yang dikerjakan

- **Akses**: `listen_addresses=localhost` (server aplikasi lewat `ALLOW_CIDR`), `pg_hba.conf` dibuat ulang tanpa `trust` dan tanpa `0.0.0.0/0`, SSL aktif, hash password `scram-sha-256`, dan role aplikasi bukan superuser.
- **Tuning**: `shared_buffers` 25% RAM, `effective_cache_size` 75%, `work_mem` dan `maintenance_work_mem` dihitung dari RAM dan `max_connections`, checkpoint dan ukuran WAL, serta `random_page_cost` untuk SSD (`STORAGE=hdd` untuk disk biasa).
- **Observabilitas**: log koneksi dan lock wait, slow query log (default 500 ms), dan `pg_stat_statements`.
- **Backup**: `pg_dump` semua database plus roles, base backup fisik, arsip WAL (batas kehilangan data maksimal 5 menit lewat `archive_timeout`), checksum SHA-256, retensi 7 hari, dan systemd timer harian jam 02:30.

## Bug yang ditemukan lewat pengujian

Pada run pertama PITR gagal. Penyebabnya folder backup hanya bisa dibuka root, jadi user `postgres` tidak bisa menulis arsip WAL. **Pengarsipan gagal tanpa suara**, padahal audit versi awal menyatakan PASS karena hanya membaca `archive_mode = on`. Perbaikannya ada dua: izin folder dibenahi, dan audit sekarang memeriksa `pg_stat_archiver` (pengarsipan terakhir tidak boleh gagal).

## Pengaman

| Risiko | Pengaman |
|---|---|
| Konfigurasi lama dibutuhkan lagi | `postgresql.conf` dan `pg_hba.conf` disalin ke `/var/backups/pg-setup-<waktu>/` sebelum diubah |
| Backup setengah jadi dianggap valid | Ditulis ke folder `.tmp`, di-rename hanya setelah selesai |
| Backup korup | Checksum SHA-256 diperiksa sebelum restore uji |
| PITR salah dan data hilang | Data cluster lama **tidak dihapus**, dipindah ke `<data>.before-restore-<waktu>`, dan ada perintah pembatalan kalau gagal |
| Password acak membuat aplikasi putus | Hanya dengan `ROTATE_PASSWORDS=1`. Tanpa itu, script hanya memberi peringatan |
| Dijalankan berulang | Idempotent: pemeriksaan yang sudah PASS dilewati |

## Batasan

- **Hanya PostgreSQL.** MySQL/MariaDB belum dicakup dan butuh script tersendiri.
- **Backup tersimpan di server yang sama.** Kalau disk atau server hilang, backup ikut hilang. Salinan ke luar server (S3, rclone, atau server lain) belum disertakan dan wajib ditambahkan untuk produksi.
- PITR memulihkan **seluruh cluster**, bukan satu tabel. Untuk mengembalikan satu tabel saja tanpa mengganggu data lain, restore ke server sementara lalu salin tabelnya.
- Sertifikat SSL memakai sertifikat self-signed bawaan Debian. Produksi sebaiknya memakai sertifikat sungguhan.
- Nilai tuning memakai aturan umum berdasarkan RAM, bukan hasil profil beban kerja klien. Setelah dipantau beberapa hari lewat `pg-slowquery.sh`, nilainya masih bisa disesuaikan.
- Mengganti password (`ROTATE_PASSWORDS=1`) dan mencabut hak superuser bisa memutus aplikasi yang bergantung padanya. Selalu cek dulu.

## Menjalankan ulang lab

Butuh WSL2 dengan KVM. Perintah ini membuat VM baru dan menjalankan semua tahap di atas (sekitar 6 menit):

```bash
sudo bash test/run-lab.sh
```

## Struktur

```
pg-setup.sh            audit + apply (keamanan, tuning, backup)
pg-backup.sh           dump, base backup, verifikasi restore, retensi
pg-pitr-restore.sh     pemulihan ke titik waktu
pg-slowquery.sh        query paling lambat (pg_stat_statements)
test/                  lab VM, database rentan, serangan, benchmark, simulasi bencana
results/               output asli dari lab
```
