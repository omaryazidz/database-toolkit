#!/usr/bin/env bash
# Lab uji: VM Ubuntu 24.04 (cloud image resmi, sama seperti VPS) via QEMU/KVM, RAM 4GB.
#   sudo ./lab-vm.sh up     # boot VM: SSH 127.0.0.1:2224, PostgreSQL 127.0.0.1:5433
#   sudo ./lab-vm.sh down   # matikan & hapus disk VM
set -euo pipefail

LAB=/root/dblab
IMG_URL=https://cloud-images.ubuntu.com/noble/current
IMG=noble-server-cloudimg-amd64.img
PORT=2224

up() {
  command -v qemu-system-x86_64 >/dev/null ||
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq qemu-system-x86 qemu-utils cloud-image-utils >/dev/null
  mkdir -p "$LAB" && cd "$LAB"
  if [[ ! -f $IMG ]]; then
    for d in /root/weblab /root/vmlab; do [[ -f $d/$IMG ]] && cp "$d/$IMG" . && break; done
    [[ -f $IMG ]] || curl -fsSLO "$IMG_URL/$IMG"
    curl -fsSL "$IMG_URL/SHA256SUMS" | grep " \*$IMG\$" | sha256sum -c --quiet
  fi
  [[ -f lab_key ]] || ssh-keygen -q -t ed25519 -N "" -f lab_key

  cat >user-data <<EOF
#cloud-config
hostname: db-lab-01
users:
  - name: sysadmin
    groups: sudo
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys: [$(cat lab_key.pub)]
EOF
  echo "instance-id: db-lab-01" >meta-data
  cloud-localds seed.iso user-data meta-data
  qemu-img create -q -f qcow2 -F qcow2 -b "$IMG" vm.qcow2 20G

  qemu-system-x86_64 -enable-kvm -cpu host -m 4096 -smp 2 \
    -drive file=vm.qcow2,if=virtio -drive file=seed.iso,format=raw,if=virtio \
    -nic user,model=virtio,hostfwd=tcp:127.0.0.1:$PORT-:22,hostfwd=tcp:127.0.0.1:5433-:5432 \
    -display none -serial file:serial.log -pidfile vm.pid -daemonize

  echo -n "Menunggu VM boot"
  for _ in $(seq 90); do
    if ssh -q -i lab_key -p $PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=3 sysadmin@127.0.0.1 'cloud-init status --wait >/dev/null'; then
      echo " siap"; return
    fi
    echo -n .; sleep 2
  done
  echo " timeout, lihat $LAB/serial.log"; exit 1
}

down() {
  local pid
  if [[ -f $LAB/vm.pid ]]; then
    pid=$(cat "$LAB/vm.pid")
    kill "$pid" 2>/dev/null
    for _ in $(seq 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done # tunggu port benar-benar lepas
  fi
  rm -f "$LAB"/vm.qcow2 "$LAB"/vm.pid "$LAB"/seed.iso
}

"${1:-up}"
