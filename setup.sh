#!/usr/bin/env bash
set -euo pipefail

# =======================
# Ubuntu Server Hazırlama
# =======================
# Değişkenler (istediğin gibi override edebilirsin: USERNAME=omer SSH_PORT=22022 bash setup.sh)
USERNAME="${USERNAME:-faruk}"
SSH_PORT="${SSH_PORT:-2222}"
TZ="${TZ:-Europe/Istanbul}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)}"

log() { echo -e "\033[1;36m[+] $*\033[0m"; }
warn(){ echo -e "\033[1;33m[!] $*\033[0m"; }
err() { echo -e "\033[1;31m[-] $*\033[0m" >&2; }
need_root(){
  if [[ "${EUID}" -ne 0 ]]; then err "Root yetkisi gerekli. 'sudo ./setup.sh' ile çalıştır."; exit 1; fi
}

apt_quiet(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get upgrade -y
}

install_base(){
  log "Temel paketler kuruluyor…"
  apt-get install -y \
    ca-certificates apt-transport-https software-properties-common \
    build-essential curl wget unzip git gnupg lsb-release \
    ufw fail2ban openssh-server tzdata \
    htop ncdu net-tools iproute2 jq tree zip tar \
    python3 python3-pip \
    openjdk-17-jdk \
    nginx php-fpm php-cli php-mysql php-zip php-xml php-curl php-gd \
    mysql-server \
    docker.io docker-compose-plugin \
    unattended-upgrades
}

set_timezone(){
  log "Zaman dilimi ayarlanıyor: ${TZ}"
  timedatectl set-timezone "${TZ}" || true
}

create_user(){
  if id -u "${USERNAME}" >/dev/null 2>&1; then
    log "Kullanıcı mevcut: ${USERNAME}"
  else
    log "Kullanıcı oluşturuluyor: ${USERNAME}"
    adduser --gecos "" --disabled-password "${USERNAME}"
    echo "${USERNAME}:$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12)" | chpasswd
  fi
  usermod -aG sudo "${USERNAME}"
  usermod -aG docker "${USERNAME}" || true
}

configure_ssh(){
  log "SSH yapılandırılıyor (port: ${SSH_PORT}, root girişi kapalı)…"
  systemctl enable ssh --now
  local cfg="/etc/ssh/sshd_config"
  cp -n "${cfg}" "${cfg}.bak.$(date +%s)" || true

  # Port satırı
  if grep -qiE '^\s*Port\s+' "${cfg}"; then
    sed -ri "s@^\s*Port\s+.*@Port ${SSH_PORT}@I" "${cfg}"
  else
    echo "Port ${SSH_PORT}" >> "${cfg}"
  fi
  # Root login kapat
  if grep -qiE '^\s*PermitRootLogin\s+' "${cfg}"; then
    sed -ri "s@^\s*PermitRootLogin\s+.*@PermitRootLogin no@I" "${cfg}"
  else
    echo "PermitRootLogin no" >> "${cfg}"
  fi
  # (İstersen parolayı sonra kapatabilirsin; burada erişimi kesmemek için açık bırakıyoruz)
  if ! grep -qiE '^\s*PasswordAuthentication\s+' "${cfg}"; then
    echo "PasswordAuthentication yes" >> "${cfg}"
  fi

  systemctl restart ssh
}

configure_ufw(){
  log "UFW (güvenlik duvarı) yapılandırılıyor…"
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "${SSH_PORT}"/tcp
  # Web servisi düşünülerek HTTP/HTTPS aç
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw --force enable
  ufw status verbose || true
}

configure_fail2ban(){
  log "Fail2Ban ayarlanıyor (SSHD koruması)…"
  mkdir -p /etc/fail2ban
  cat >/etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
destemail = root@localhost
sender = fail2ban@$(hostname -f)
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd
logpath = %(sshd_log)s
backend = systemd
EOF
  systemctl enable fail2ban --now
  systemctl restart fail2ban
  fail2ban-client status sshd || true
}

configure_nginx_php(){
  log "Nginx + PHP-FPM yapılandırılıyor…"
  systemctl enable nginx --now
  systemctl enable php*-fpm --now || true

  # Basit PHP info sayfası
  mkdir -p /var/www/html
  if [[ ! -f /var/www/html/index.php ]]; then
    echo "<?php phpinfo(); ?>" >/var/www/html/index.php
    chown -R www-data:www-data /var/www/html
  fi

  # Basit sert ayarlar
  sed -ri 's@server_tokens on;@server_tokens off;@' /etc/nginx/nginx.conf || true
  if ! grep -q "server_names_hash_bucket_size" /etc/nginx/nginx.conf; then
    sed -ri 's@http \{@http {\n    server_names_hash_bucket_size 64;@' /etc/nginx/nginx.conf || true
  fi

  nginx -t && systemctl reload nginx
}

secure_mysql(){
  log "MySQL güvenli yapılandırması yapılıyor…"
  systemctl enable mysql --now

  # root kullanıcıyı parola ile native auth'a geçir
  mysql --user=root <<SQL || { warn "MySQL root erişimi başarısız oldu. Güvenlik adımı atlandı."; return; }
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQL
}

install_docker(){
  log "Docker ve Compose etkinleştiriliyor…"
  systemctl enable docker --now
  docker --version || true
  docker compose version || true
}

enable_unattended(){
  log "Otomatik güvenlik güncellemeleri açılıyor…"
  dpkg-reconfigure -f noninteractive unattended-upgrades || true
  cat >/etc/apt/apt.conf.d/51auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
}

summary(){
  echo
  echo "===================== ÖZET ====================="
  echo " Kullanıcı        : ${USERNAME} (sudo+docker)"
  echo " SSH Port         : ${SSH_PORT}"
  echo " Root SSH         : DEVRE DIŞI"
  echo " Zaman Dilimi     : ${TZ}"
  echo " UFW              : 80,443,${SSH_PORT} açık; diğer gelen bağlantılar engelli"
  echo " Fail2Ban         : sshd koruması aktif"
  echo " Nginx/PHP        : /var/www/html/index.php (phpinfo)"
  echo " MySQL Root Parola: ${MYSQL_ROOT_PASSWORD}"
  echo " Docker           : docker ve docker compose hazır"
  echo " Otomatik Güvenlik Günc.: aktif"
  echo "================================================"
  echo
  warn "MySQL root parolasını güvenli bir yerde sakla."
  warn "SSH anahtarı ekledikten sonra 'PasswordAuthentication no' yapmanı öneririm: /etc/ssh/sshd_config"
}

main(){
  need_root
  apt_quiet
  install_base
  set_timezone
  create_user
  configure_ssh
  configure_ufw
  configure_fail2ban
  configure_nginx_php
  secure_mysql
  install_docker
  enable_unattended
  summary
}

main "$@"
