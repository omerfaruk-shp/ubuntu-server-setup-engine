#!/usr/bin/env bash
set -euo pipefail
DESKTOP="${DESKTOP:-xfce}"  # xfce | mate | lxde
RDP_PORT="${RDP_PORT:-3389}"
USER_NAME="${USER_NAME:-$SUDO_USER}"

log(){ echo -e "\033[1;36m[+] $*\033[0m"; }

[[ $EUID -eq 0 ]] || { echo "sudo ile çalıştır."; exit 1; }

log "Paketler güncelleniyor…"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y && apt-get upgrade -y

if [[ "$DESKTOP" == "xfce" ]]; then
  log "XFCE masaüstü kuruluyor…"
  apt-get install -y xfce4 xfce4-goodies
  SESSION_CMD="startxfce4"
elif [[ "$DESKTOP" == "mate" ]]; then
  log "MATE masaüstü kuruluyor…"
  apt-get install -y mate-desktop-environment-core
  SESSION_CMD="mate-session"
elif [[ "$DESKTOP" == "lxde" ]]; then
  log "LXDE masaüstü kuruluyor…"
  apt-get install -y lxde
  SESSION_CMD="startlxde"
else
  echo "DESKTOP=xfce|mate|lxde"; exit 1
fi

log "XRDP kuruluyor…"
apt-get install -y xrdp
systemctl enable xrdp --now

# Siyah ekran fix: .xsession içine oturum yaz
TARGET_USER="${USER_NAME:-$(logname || echo ubuntu)}"
HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
mkdir -p "$HOME_DIR"
echo "$SESSION_CMD" > "$HOME_DIR/.xsession"
chown "$TARGET_USER":"$TARGET_USER" "$HOME_DIR/.xsession"

# Polkit/consolekit olmadan yetki sorunlarını azalt
apt-get install -y policykit-1 dbus-x11

# UFW'yi aç (varsa)
if command -v ufw >/dev/null 2>&1; then
  log "UFW RDP portu açılıyor (${RDP_PORT}/tcp)…"
  ufw allow "${RDP_PORT}/tcp" || true
fi

# xorgxrdp genelde bağımlılık olarak gelir; gelmediyse:
apt-get install -y xorgxrdp || true

log "XRDP servisi yeniden başlatılıyor…"
systemctl restart xrdp

log "Bitti. RDP ile bağlan: ${RDP_PORT}"
