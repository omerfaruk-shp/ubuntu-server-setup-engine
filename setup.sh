#!/usr/bin/env bash
set -euo pipefail

# ==========================
# Ubuntu Server Full Setup
# ==========================
USERNAME="${USERNAME:-faruk}"
SSH_PORT="${SSH_PORT:-2222}"
TZ="${TZ:-Europe/Istanbul}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)}"
DOMAIN="${DOMAIN:-}"             # Örn: example.com (boş bırakılırsa HTTPS kurulmaz)
LE_EMAIL="${LE_EMAIL:-}"         # Örn: admin@example.com (Let's Encrypt için)
FTP_PASV_MIN="${FTP_PASV_MIN:-40000}"
FTP_PASV_MAX="${FTP_PASV_MAX:-40100}"

log()  { echo -e "\033[1;36m[+] $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }
err()  { echo -e "\033[1;31m[-] $*\033[0m" >&2; }
need_root(){ [[ $EUID -eq 0 ]] || { err "Root yetkisi gerekli. 'sudo ./setup_full.sh' ile çalıştır."; exit 1; }; }

apt_quiet(){
  export DEBIAN_FRONTEND=noninteractive
  log "Paketler güncelleniyor…"
  apt-get update -y
  apt-get upgrade -y
}

install_base(){
  log "Temel paketler ve servisler kuruluyor…"
  apt-get install -y \
    ca-certificates apt-transport-https software-properties-common \
    build-essential curl wget unzip git gnupg lsb-release tzdata \
    ufw fail2ban openssh-server \
    htop ncdu net-tools iproute2 jq tree zip tar rsync \
    python3 python3-pip \
    openjdk-17-jdk \
    nginx php-fpm php-cli php-mysql php-zip php-xml php-curl php-gd \
    mysql-server \
    docker.io docker-compose-plugin \
    vsftpd \
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
  if grep -qiE '^\s*Port\s+' "${cfg}"; then
    sed -ri "s@^\s*Port\s+.*@Port ${SSH_PORT}@I" "${cfg}"
  else
    echo "Port ${SSH_PORT}" >> "${cfg}"
  fi
  if grep -qiE '^\s*PermitRootLogin\s+' "${cfg}"; then
    sed -ri "s@^\s*PermitRootLogin\s+.*@PermitRootLogin no@I" "${cfg}"
  else
    echo "PermitRootLogin no" >> "${cfg}"
  fi
  if ! grep -qiE '^\s*PasswordAuthentication\s+' "${cfg}"; then
    echo "PasswordAuthentication yes" >> "${cfg}"
  fi
  systemctl restart ssh
}

configure_ufw(){
  log "UFW ayarlanıyor…"
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  # SSH
  ufw allow "${SSH_PORT}"/tcp
  # HTTP/HTTPS
  ufw allow 80/tcp
  ufw allow 443/tcp
  # FTP/FTPS (vsftpd, PASV aralığı)
  ufw allow 21/tcp
  ufw allow ${FTP_PASV_MIN}:${FTP_PASV_MAX}/tcp
  ufw --force enable
  ufw status verbose || true
}

configure_fail2ban(){
  log "Fail2Ban yapılandırılıyor…"
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

[nginx-http-auth]
enabled = true
port = http,https
filter = nginx-http-auth
logpath = /var/log/nginx/error.log
EOF
  systemctl enable fail2ban --now
  systemctl restart fail2ban
  fail2ban-client status || true
}

configure_nginx_php(){
  log "Nginx + PHP-FPM yapılandırılıyor…"
  systemctl enable nginx --now
  systemctl enable php*-fpm --now || true

  mkdir -p /var/www/html
  if [[ ! -f /var/www/html/index.php ]]; then
    echo "<?php phpinfo(); ?>" >/var/www/html/index.php
  fi
  chown -R www-data:www-data /var/www/html

  # Güvenli varsayılanlar
  sed -ri 's@server_tokens on;@server_tokens off;@' /etc/nginx/nginx.conf || true
  if ! grep -q "server_names_hash_bucket_size" /etc/nginx/nginx.conf; then
    sed -ri 's@http \{@http {\n    server_names_hash_bucket_size 64;@' /etc/nginx/nginx.conf || true
  fi

  # Varsayılan site (PHP desteği)
  cat >/etc/nginx/sites-available/default <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    root /var/www/html;

    index index.php index.html index.htm;

    location / {
        try_files $uri $uri/ /index.php?$args;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php-fpm.sock;
    }

    location ~* \.(log|conf|ini|sh|sql|bak)$ {
        deny all;
    }

    client_max_body_size 64m;
    sendfile on;
}
EOF

  nginx -t && systemctl reload nginx
}

secure_mysql(){
  log "MySQL güvenli yapılandırması…"
  systemctl enable mysql --now || true
  mysql --user=root <<SQL || { warn "MySQL root erişimi başarısız. Güvenlik adımı atlandı."; return; }
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQL
}

install_docker(){
  log "Docker etkinleştiriliyor…"
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

configure_vsftpd(){
  log "vsftpd (FTP/FTPS) yapılandırılıyor…"
  systemctl enable vsftpd --now || true

  # FTPS için self-signed sertifika (Let's Encrypt kullanılmazsa)
  local cert="/etc/ssl/private/vsftpd.pem"
  if [[ ! -f "$cert" ]]; then
    log "FTPS için self-signed sertifika üretiliyor…"
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
      -keyout "$cert" -out "$cert" \
      -subj "/C=TR/ST=NA/L=NA/O=Server/OU=FTP/CN=$(hostname -f)" >/dev/null 2>&1 || true
    chmod 600 "$cert"
  fi

  # FTP kök dizini olarak web kökünü de kullanılabilir yap (deploy kolaylığı)
  mkdir -p /var/www/html
  chown -R "${USERNAME}":www-data /var/www/html
  chmod -R 775 /var/www/html

  # vsftpd ana konfig
  cp -n /etc/vsftpd.conf "/etc/vsftpd.conf.bak.$(date +%s)" || true
  cat >/etc/vsftpd.conf <<EOF
listen=YES
listen_ipv6=NO
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=022
dirmessage_enable=YES
use_localtime=YES
xferlog_enable=YES
connect_from_port_20=YES

# Kullanıcıyı home içinde hapsedin (chroot)
chroot_local_user=YES
allow_writeable_chroot=YES

# Pasif mod
pasv_enable=YES
pasv_min_port=${FTP_PASV_MIN}
pasv_max_port=${FTP_PASV_MAX}

# TLS (Explicit FTPS)
ssl_enable=YES
rsa_cert_file=${cert}
force_local_logins_ssl=YES
force_local_data_ssl=YES
ssl_tlsv1=NO
ssl_tlsv1_1=NO
ssl_tlsv1_2=YES
require_ssl_reuse=NO

# Güvenlik
seccomp_sandbox=NO
pam_service_name=vsftpd

# Karakter setleri
utf8_filesystem=YES
EOF

  # Varsayılan shell'i olan normal sistem kullanıcısını FTP'ye sokuyoruz
  usermod -d "/home/${USERNAME}" "${USERNAME}" || true
  mkdir -p "/home/${USERNAME}/ftp"
  # Web klasörüne kolay erişim için symlink
  ln -sf /var/www/html "/home/${USERNAME}/ftp/webroot"
  chown -R "${USERNAME}":"${USERNAME}" "/home/${USERNAME}/ftp"

  systemctl restart vsftpd
}

configure_https_if_domain(){
  if [[ -n "${DOMAIN}" && -n "${LE_EMAIL}" ]]; then
    log "Let’s Encrypt ile HTTPS hazırlanıyor (DOMAIN=${DOMAIN})…"
    apt-get install -y certbot python3-certbot-nginx
    # Basit server blok olarak default'u DOMAIN ile güncelle
    sed -ri "s/server_name _;/server_name ${DOMAIN};/" /etc/nginx/sites-available/default
    nginx -t && systemctl reload nginx

    if certbot --nginx -d "${DOMAIN}" -m "${LE_EMAIL}" --agree-tos --redirect --non-interactive; then
      log "HTTPS başarıyla etkinleştirildi."
    else
      warn "Let’s Encrypt başarısız oldu. HTTP ile devam ediliyor."
    fi
  else
    warn "DOMAIN/LE_EMAIL ayarlanmadı, HTTPS kurulmadı. (Opsiyonel)"
  fi
}

summary(){
  echo
  echo "====================== ÖZET ======================"
  echo " Kullanıcı            : ${USERNAME} (sudo+docker)"
  echo " SSH Port             : ${SSH_PORT} (root login: kapalı)"
  echo " Zaman Dilimi         : ${TZ}"
  echo " HTTP(S)              : Nginx + PHP-FPM (root: /var/www/html)"
  if [[ -n "${DOMAIN}" ]]; then
    echo " Domain               : ${DOMAIN} (Let's Encrypt: ${LE_EMAIL:-YOK})"
  else
    echo " Domain               : YOK (HTTP açık, HTTPS opsiyonel)"
  fi
  echo " MySQL Root Parolası  : ${MYSQL_ROOT_PASSWORD}"
  echo " Docker               : docker & compose hazir"
  echo " UFW                  : 80,443,${SSH_PORT},21 ve ${FTP_PASV_MIN}-${FTP_PASV_MAX} açık"
  echo " Fail2Ban             : sshd + nginx-http-auth aktif"
  echo " FTP/FTPS (vsftpd)    : Port 21 + pasif ${FTP_PASV_MIN}-${FTP_PASV_MAX}"
  echo "   FTP Home           : /home/${USERNAME}/ftp  (web: /home/${USERNAME}/ftp/webroot -> /var/www/html)"
  echo " Otomatik Güncelleme  : unattended-upgrades aktif"
  echo "=================================================="
  echo
  warn "Güvenlik: SSH anahtarı ekledikten sonra /etc/ssh/sshd_config içinde 'PasswordAuthentication no' yapmanı öneririm."
  warn "FTP istemcisinde 'Explicit TLS/FTPS' ve PASV modunu kullan."
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
  configure_vsftpd
  configure_https_if_domain
  summary
}

main "$@"
