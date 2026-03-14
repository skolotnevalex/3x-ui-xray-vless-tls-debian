#!/usr/bin/env bash
set -euo pipefail

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Запустите скрипт с правами root: sudo bash ./install_nginx_debian.sh"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

log() {
  echo "==> $*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  sudo bash ./install_nginx_debian.sh

Опции (необязательно, чтобы не спрашивать интерактивно):
  --stage <nginx|vhost|certbot|issue|renewal|all>
  --domain <example.com>
  --domain-www <www.example.com>     (опционально)
  --site-conf <path>                (по умолчанию: /etc/nginx/sites-available/default)
  --open-ufw <yes|no|ask>           (по умолчанию: ask)
  -h, --help

Примеры:
  sudo bash ./install_nginx_debian.sh --stage all --domain example.com --domain-www www.example.com
  sudo bash ./install_nginx_debian.sh --stage vhost --domain example.com
EOF
}

prompt() {
  local message="$1"
  local default_value="${2:-}"
  local value=""

  if [ -n "$default_value" ]; then
    read -r -p "$message [$default_value]: " value
    value="${value:-$default_value}"
  else
    read -r -p "$message: " value
  fi

  printf '%s' "$value"
}

confirm() {
  local message="$1"
  local answer=""
  read -r -p "$message [y/N]: " answer
  case "${answer:-}" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "Не найдено: $cmd"
}

DOMAIN="${DOMAIN:-}"
DOMAIN_WWW="${DOMAIN_WWW:-}"
NGINX_SITE_CONF="${NGINX_SITE_CONF:-/etc/nginx/sites-available/default}"
OPEN_UFW="${OPEN_UFW:-ask}"
STAGE="${STAGE:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --stage)
      STAGE="${2:-}"; shift 2 ;;
    --domain)
      DOMAIN="${2:-}"; shift 2 ;;
    --domain-www)
      DOMAIN_WWW="${2:-}"; shift 2 ;;
    --site-conf)
      NGINX_SITE_CONF="${2:-}"; shift 2 ;;
    --open-ufw)
      OPEN_UFW="${2:-}"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "Неизвестный аргумент: $1 (используй --help)" ;;
  esac
done

select_stage_interactive() {
  cat <<'EOF'
Выбери этап:
  1) Установить Nginx + включить сервис
  2) Настроить server_name (vhost на 80) + reload
  3) Установить Certbot + python3-certbot-nginx
  4) Выпустить сертификат (certbot --nginx)
  5) Проверить автопродление (dry-run)
  6) Всё (1-5)
EOF

  local choice=""
  read -r -p "Этап [1-6]: " choice
  case "${choice:-}" in
    1) STAGE="nginx" ;;
    2) STAGE="vhost" ;;
    3) STAGE="certbot" ;;
    4) STAGE="issue" ;;
    5) STAGE="renewal" ;;
    6) STAGE="all" ;;
    *) die "Неверный выбор этапа: ${choice:-<empty>}" ;;
  esac
}

ensure_domain_vars() {
  if [ -z "${DOMAIN:-}" ]; then
    DOMAIN="$(prompt "Введите основной домен (DOMAIN), например example.com")"
  fi
  if [ -z "${DOMAIN:-}" ]; then
    die "DOMAIN не задан"
  fi

  if [ -z "${DOMAIN_WWW:-}" ]; then
    DOMAIN_WWW="$(prompt "Введите дополнительный домен (DOMAIN_WWW), например www.example.com (можно оставить пустым)" "")"
  fi
}

server_names() {
  if [ -n "${DOMAIN_WWW:-}" ]; then
    printf '%s %s' "$DOMAIN" "$DOMAIN_WWW"
  else
    printf '%s' "$DOMAIN"
  fi
}

maybe_open_ufw() {
  if ! command -v ufw >/dev/null 2>&1; then
    log "UFW не найден: пропускаем настройку firewall"
    return 0
  fi

  case "${OPEN_UFW:-ask}" in
    yes|YES|y|Y)
      log "UFW найден: открываем 80/443"
      ufw allow 80/tcp
      ufw allow 443/tcp
      ufw status
      ;;
    no|NO|n|N)
      log "UFW найден: пропускаем открытие портов"
      ;;
    ask|ASK|"")
      if confirm "UFW найден. Открыть порты 80/443?"; then
        ufw allow 80/tcp
        ufw allow 443/tcp
        ufw status
      else
        log "Оставляем UFW без изменений"
      fi
      ;;
    *)
      die "OPEN_UFW должен быть yes|no|ask, сейчас: ${OPEN_UFW}" ;;
  esac
}

stage_install_nginx() {
  log "Обновление пакетов"
  apt update -y

  log "Установка Nginx"
  apt install -y nginx

  log "Включение и запуск сервиса"
  systemctl enable --now nginx

  maybe_open_ufw

  log "Готово. Проверьте: http://SERVER_IP"
}

stage_configure_vhost() {
  ensure_domain_vars
  local names
  names="$(server_names)"

  NGINX_SITE_CONF="$(prompt "Файл конфигурации Nginx для правки" "${NGINX_SITE_CONF:-/etc/nginx/sites-available/default}")"
  if [ -z "${NGINX_SITE_CONF:-}" ]; then
    die "Путь до конфига Nginx не задан"
  fi

  if [ ! -f "$NGINX_SITE_CONF" ]; then
    die "Не найден файл конфигурации Nginx: $NGINX_SITE_CONF"
  fi

  log "Настройка server_name в $NGINX_SITE_CONF"
  local backup="${NGINX_SITE_CONF}.bak.$(date +%Y%m%d_%H%M%S)"
  cp -a "$NGINX_SITE_CONF" "$backup"
  log "Бэкап: $backup"

  if grep -qE '^[[:space:]]*server_name[[:space:]]+' "$NGINX_SITE_CONF"; then
    # Заменяем только первое вхождение server_name (как правило, это нужный server{} на 80 порту).
    sed -i -E "0,/^[[:space:]]*server_name[[:space:]]+[^;]*;/s//    server_name ${names};/" "$NGINX_SITE_CONF"
  else
    log "В $NGINX_SITE_CONF не найден server_name."
    if confirm "Перезаписать файл минимальным шаблоном (как в NGINX.md)?"; then
      cat >"$NGINX_SITE_CONF" <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    server_name ${names};

    root /var/www/html;
    index index.nginx-debian.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
    else
      die "Остановлено. Укажите server_name вручную или выберите другой конфиг (--site-conf)."
    fi
  fi

  log "Проверка конфига и reload"
  nginx -t
  systemctl reload nginx
}

stage_install_certbot() {
  log "Установка Certbot + nginx plugin"
  apt update -y
  apt install -y certbot python3-certbot-nginx
}

stage_issue_cert() {
  ensure_domain_vars
  require_cmd certbot

  log "Выпуск сертификата через certbot --nginx"
  if [ -n "${DOMAIN_WWW:-}" ]; then
    certbot --nginx -d "$DOMAIN" -d "$DOMAIN_WWW"
  else
    certbot --nginx -d "$DOMAIN"
  fi

  log "Reload nginx (на всякий случай)"
  systemctl reload nginx
}

stage_check_renewal() {
  require_cmd certbot

  log "Проверка systemd-таймеров Certbot"
  systemctl list-timers | grep certbot || true

  log "Dry-run продления сертификатов"
  certbot renew --dry-run
}

if [ -z "${STAGE:-}" ]; then
  select_stage_interactive
fi

case "${STAGE:-}" in
  nginx)
    stage_install_nginx
    ;;
  vhost)
    stage_configure_vhost
    ;;
  certbot)
    stage_install_certbot
    ;;
  issue)
    stage_issue_cert
    ;;
  renewal)
    stage_check_renewal
    ;;
  all)
    stage_install_nginx
    stage_configure_vhost
    stage_install_certbot
    stage_issue_cert
    stage_check_renewal
    ;;
  *)
    die "Неизвестный этап: ${STAGE:-<empty>} (ожидается nginx|vhost|certbot|issue|renewal|all)"
    ;;
esac
