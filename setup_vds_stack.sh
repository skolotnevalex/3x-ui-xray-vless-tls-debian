#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Использование:
  sudo bash ./setup_vds_stack.sh [параметры]

Параметры:
  --config <path>                    Путь к конфиг-файлу в формате .env.
  --stage <name>                     Этап: preflight|ssh|docker|xui|nginx|certbot|hook|diag|all
  --non-interactive                  Не задавать вопросы; при нехватке переменных завершиться с ошибкой.

  --repo-dir <path>                  Путь к репозиторию на сервере (по умолчанию: каталог со скриптом)
  --domain <example.com>             Основной домен.
  --domain-www <www.example.com>     Дополнительный домен (опционально).
  --open-ufw <yes|no|ask>            Открывать 80/443 в UFW при необходимости (по умолчанию: ask).

  --cert-email <mail@example.com>    E-mail для Let's Encrypt.
  --cert-mode <nginx|webroot>        Режим Certbot (по умолчанию: nginx).
  --cert-staging <yes|no>            Использовать staging Let's Encrypt (по умолчанию: no).
  --cert-non-interactive <yes|no>    Запускать certbot без интерактива (по умолчанию: no).

  --enable-ssh-hardening <yes|no>    Включить этап SSH-hardening в --stage all (по умолчанию: no).
  --ssh-user <name>                  Пользователь для SSH-hardening.
  --ssh-port <port>                  Порт SSH (по умолчанию: 2222).
  --ssh-public-key <key_or_path>     Публичный SSH-ключ или путь к .pub.
  --ssh-disable-root <yes|no>        Установить PermitRootLogin no (по умолчанию: yes).
  --ssh-disable-password <yes|no>    Установить PasswordAuthentication no (по умолчанию: yes).

  -h, --help                         Показать справку.

Примеры:
  sudo bash ./setup_vds_stack.sh --stage all --config ./setup.env
  sudo bash ./setup_vds_stack.sh --stage certbot --domain example.com --cert-email admin@example.com
EOF
}

is_yes() {
  case "${1:-}" in
    y|Y|yes|YES|true|TRUE|1|д|Д|да|ДА) return 0 ;;
    *) return 1 ;;
  esac
}

confirm() {
  local message="$1"
  if is_yes "${NON_INTERACTIVE:-no}"; then
    return 1
  fi

  local answer=""
  read -r -p "$message [д/N]: " answer
  is_yes "${answer:-no}"
}

prompt() {
  local message="$1"
  local default_value="${2:-}"
  local answer=""

  if [ -n "$default_value" ]; then
    read -r -p "$message [$default_value]: " answer
    answer="${answer:-$default_value}"
  else
    read -r -p "$message: " answer
  fi

  printf '%s' "$answer"
}

prompt_if_empty() {
  local var_name="$1"
  local message="$2"
  local default_value="${3:-}"
  local allow_empty="${4:-no}"
  local current_value="${!var_name:-}"

  if [ -n "$current_value" ]; then
    return 0
  fi

  if is_yes "${NON_INTERACTIVE:-no}"; then
    if is_yes "$allow_empty"; then
      return 0
    fi
    die "В неинтерактивном режиме не задана обязательная переменная: $var_name"
  fi

  local result
  result="$(prompt "$message" "$default_value")"
  printf -v "$var_name" '%s' "$result"

  if [ -z "${!var_name:-}" ] && ! is_yes "$allow_empty"; then
    die "Обязательное значение пустое: $var_name"
  fi
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "Команда не найдена: $cmd"
}

set_sshd_option() {
  local key="$1"
  local value="$2"
  local config_file="$3"

  if grep -qE "^[[:space:]#]*${key}[[:space:]]+" "$config_file"; then
    sed -i -E "s|^[[:space:]#]*(${key})[[:space:]]+.*|\1 ${value}|g" "$config_file"
  else
    printf '%s %s\n' "$key" "$value" >>"$config_file"
  fi
}

load_config_file() {
  local config_path="$1"
  [ -f "$config_path" ] || die "Файл конфигурации не найден: $config_path"
  # shellcheck disable=SC1090
  set -a && . "$config_path" && set +a
  log "Загружен конфиг: $config_path"
}

select_stage_interactive() {
  cat <<'EOF'
Выберите этап:
  1) Проверки окружения (preflight)
  2) SSH-hardening (опционально, риск потери доступа)
  3) Установка Docker Engine
  4) Настройка и запуск 3x-ui
  5) Установка и настройка Nginx
  6) Установка Certbot и выпуск сертификата
  7) Установка deploy-hook сертификата (копирование в 3x-ui и рестарт контейнера)
  8) Диагностика
  9) Все этапы (2 запускается только при ENABLE_SSH_HARDENING=yes)
EOF
  local choice=""
  read -r -p "Выбор [1-9]: " choice

  case "${choice:-}" in
    1) STAGE="preflight" ;;
    2) STAGE="ssh" ;;
    3) STAGE="docker" ;;
    4) STAGE="xui" ;;
    5) STAGE="nginx" ;;
    6) STAGE="certbot" ;;
    7) STAGE="hook" ;;
    8) STAGE="diag" ;;
    9) STAGE="all" ;;
    *) die "Некорректный выбор этапа: ${choice:-<empty>}" ;;
  esac
}

normalize_panel_path() {
  PANEL_PATH="/${PANEL_PATH#/}"
  PANEL_PATH="${PANEL_PATH%/}"
  [ "$PANEL_PATH" = "/" ] && die "PANEL_PATH не может быть равен '/'"
}

maybe_open_ufw_http_https() {
  if ! command -v ufw >/dev/null 2>&1; then
    warn "UFW не установлен, этап настройки firewall пропущен"
    return 0
  fi

  case "${OPEN_UFW:-ask}" in
    yes|YES|y|Y)
      log "Открываю в UFW порты 80/tcp и 443/tcp"
      ufw allow 80/tcp
      ufw allow 443/tcp
      ;;
    no|NO|n|N)
      log "Пропускаю изменение правил UFW"
      ;;
    ask|"")
      if confirm "Открыть в UFW порты 80/tcp и 443/tcp?"; then
        ufw allow 80/tcp
        ufw allow 443/tcp
      else
        log "Оставляю UFW без изменений"
      fi
      ;;
    *)
      die "OPEN_UFW должен быть yes|no|ask, сейчас: $OPEN_UFW"
      ;;
  esac
}

ensure_domain_vars() {
  prompt_if_empty DOMAIN "Основной домен (DOMAIN), например: example.com"
  prompt_if_empty DOMAIN_WWW "Дополнительный домен (DOMAIN_WWW), например: www.example.com (опционально)" "" "yes"
}

server_names() {
  if [ -n "${DOMAIN_WWW:-}" ]; then
    printf '%s %s' "$DOMAIN" "$DOMAIN_WWW"
  else
    printf '%s' "$DOMAIN"
  fi
}

stage_preflight() {
  log "Запуск предварительных проверок"

  [ "${EUID:-$(id -u)}" -eq 0 ] || die "Запустите от root: sudo bash ./$SCRIPT_NAME ..."

  [ -f /etc/os-release ] || die "Файл /etc/os-release не найден"
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) ;;
    *) warn "Скрипт рассчитан на Debian/Ubuntu. Обнаружен ID=${ID:-unknown}" ;;
  esac

  require_cmd apt
  require_cmd systemctl
  require_cmd sed
  require_cmd grep

  log "Сводка параметров"
  printf '  STAGE=%s\n' "${STAGE:-<не задан>}"
  printf '  REPO_DIR=%s\n' "$REPO_DIR"
  printf '  XUI_DIR=%s\n' "$XUI_DIR"
  printf '  NGINX_REPO_CONF=%s\n' "$NGINX_REPO_CONF"
  printf '  NGINX_SITE_CONF=%s\n' "$NGINX_SITE_CONF"
  printf '  CERTBOT_MODE=%s\n' "$CERTBOT_MODE"
  printf '  OPEN_UFW=%s\n' "$OPEN_UFW"
  printf '  ENABLE_SSH_HARDENING=%s\n' "$ENABLE_SSH_HARDENING"
}

stage_ssh_hardening() {
  log "Запуск этапа SSH-hardening (по docs/01-ssh-hardening.md)"

  if ! is_yes "$ENABLE_SSH_HARDENING"; then
    warn "ENABLE_SSH_HARDENING != yes, этап SSH-hardening пропущен."
    return 0
  fi

  prompt_if_empty SSH_PORT "Порт SSH" "2222"
  prompt_if_empty SSH_NEW_USER "Пользователь для SSH (опционально, оставьте пустым чтобы не создавать)" "" "yes"
  prompt_if_empty SSH_PUBLIC_KEY "Публичный ключ или путь к .pub (опционально)" "" "yes"

  apt update -y
  apt install -y sudo git ufw

  if [ -n "${SSH_NEW_USER:-}" ]; then
    if id "$SSH_NEW_USER" >/dev/null 2>&1; then
      log "Пользователь уже существует: $SSH_NEW_USER"
    else
      log "Создаю пользователя: $SSH_NEW_USER"
      adduser --disabled-password --gecos "" "$SSH_NEW_USER"
    fi
    usermod -aG sudo "$SSH_NEW_USER"
  fi

  if [ -n "${SSH_NEW_USER:-}" ] && [ -n "${SSH_PUBLIC_KEY:-}" ]; then
    local ssh_key_content="$SSH_PUBLIC_KEY"
    if [ -f "$SSH_PUBLIC_KEY" ]; then
      ssh_key_content="$(cat "$SSH_PUBLIC_KEY")"
    fi

    install -d -m 700 "/home/$SSH_NEW_USER/.ssh"
    printf '%s\n' "$ssh_key_content" >"/home/$SSH_NEW_USER/.ssh/authorized_keys"
    chmod 600 "/home/$SSH_NEW_USER/.ssh/authorized_keys"
    chown -R "$SSH_NEW_USER:$SSH_NEW_USER" "/home/$SSH_NEW_USER/.ssh"
    log "Настроен authorized_keys для пользователя: $SSH_NEW_USER"
  fi

  local sshd_config="/etc/ssh/sshd_config"
  [ -f "$sshd_config" ] || die "Файл не найден: $sshd_config"
  cp -a "$sshd_config" "${sshd_config}.bak.$(date +%Y%m%d_%H%M%S)"

  set_sshd_option "Port" "$SSH_PORT" "$sshd_config"
  if is_yes "$SSH_DISABLE_ROOT_LOGIN"; then
    set_sshd_option "PermitRootLogin" "no" "$sshd_config"
  fi
  if is_yes "$SSH_DISABLE_PASSWORD_AUTH"; then
    set_sshd_option "PasswordAuthentication" "no" "$sshd_config"
  fi

  sshd -t

  ufw allow "${SSH_PORT}/tcp" || true
  if ! ufw status | grep -q "Status: active"; then
    if confirm "Включить UFW сейчас?"; then
      ufw --force enable
    fi
  fi

  if systemctl list-unit-files | grep -q '^ssh\.service'; then
    systemctl restart ssh
  else
    systemctl restart sshd
  fi

  warn "Проверьте вход по новому SSH в отдельном терминале, прежде чем закрывать текущую сессию."
}

stage_install_docker() {
  log "Установка Docker Engine (по docs/02-docker-install.md)"

  if is_yes "$DOCKER_REMOVE_CONFLICTING"; then
    log "Удаляю конфликтующие пакеты Docker (опционально)"
    apt remove -y docker.io docker-compose docker-doc podman-docker containerd runc || true
  fi

  apt update -y
  apt install -y ca-certificates curl

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  # shellcheck disable=SC1091
  . /etc/os-release
  cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${VERSION_CODENAME}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  apt update -y
  apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker

  if ! docker run --rm hello-world >/dev/null 2>&1; then
    warn "docker hello-world завершился ошибкой; проверьте сервис docker и сеть"
  fi
  docker compose version || warn "Проверка docker compose plugin завершилась ошибкой"

  if is_yes "$DOCKER_ADD_USER_TO_GROUP"; then
    if [ -n "${DOCKER_GROUP_USER:-}" ]; then
      usermod -aG docker "$DOCKER_GROUP_USER"
      log "Добавлен пользователь '$DOCKER_GROUP_USER' в группу docker"
    else
      warn "DOCKER_ADD_USER_TO_GROUP=yes, но DOCKER_GROUP_USER пуст"
    fi
  fi
}

stage_setup_xui() {
  log "Настройка и запуск контейнера 3x-ui"
  require_cmd docker

  [ -d "$XUI_DIR" ] || die "Каталог 3x-ui не найден: $XUI_DIR"
  [ -f "$XUI_DIR/docker-compose.yml" ] || die "Файл docker-compose.yml не найден в: $XUI_DIR"

  if [ -z "${XUI_HOSTNAME:-}" ]; then
    XUI_HOSTNAME="${DOMAIN:-example.com}"
  fi
  [ -n "${XUI_HOSTNAME:-}" ] || XUI_HOSTNAME="example.com"

  install -d "$XUI_DIR/db" "$XUI_DIR/cert"

  local xui_env_file="$XUI_DIR/.env"
  if [ -f "$xui_env_file" ]; then
    cp -a "$xui_env_file" "${xui_env_file}.bak.$(date +%Y%m%d_%H%M%S)"
  fi

  cat >"$xui_env_file" <<EOF
THREEXUI_IMAGE=${XUI_IMAGE}
THREEXUI_CONTAINER_NAME=${XUI_CONTAINER_NAME}
THREEXUI_HOSTNAME=${XUI_HOSTNAME}
THREEXUI_DB_DIR=${XUI_DB_DIR}
THREEXUI_CERT_DIR=${XUI_CERT_DIR}
EOF

  (
    cd "$XUI_DIR"
    docker compose pull || warn "docker compose pull завершился ошибкой, продолжаю выполнение"
    docker compose up -d
  )

  if docker ps --format '{{.Names}}' | grep -q "^${XUI_CONTAINER_NAME}\$"; then
    log "Контейнер 3x-ui запущен: $XUI_CONTAINER_NAME"
  else
    warn "Контейнер '$XUI_CONTAINER_NAME' не запущен. Проверьте: docker logs $XUI_CONTAINER_NAME"
  fi
}

stage_configure_nginx() {
  log "Установка и настройка Nginx (по docs/03-nginx-tls.md и docs/04-nginx-config-deploy.md)"

  ensure_domain_vars
  normalize_panel_path

  apt update -y
  apt install -y nginx
  systemctl enable --now nginx
  maybe_open_ufw_http_https

  install -d "$(dirname "$NGINX_REPO_CONF")"
  if [ -f "$NGINX_REPO_CONF" ]; then
    cp -a "$NGINX_REPO_CONF" "${NGINX_REPO_CONF}.bak.$(date +%Y%m%d_%H%M%S)"
  fi

  local names
  names="$(server_names)"
  local panel_path_with_slash="${PANEL_PATH}/"

  cat >"$NGINX_REPO_CONF" <<EOF
server {
    listen ${NGINX_PANEL_LISTEN};
    server_name ${names};

    root /var/www/html;
    index index.nginx-debian.html;

    location / {
        try_files \$uri \$uri/ =404;
    }

    add_header Strict-Transport-Security "max-age=63072000" always;

    location = ${PANEL_PATH} {
        return 301 ${panel_path_with_slash};
    }

    location ^~ ${panel_path_with_slash} {
        proxy_pass http://${NGINX_PANEL_UPSTREAM};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}

server {
    listen 80 default_server;
    listen [::]:80 default_server;

    server_name ${names};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF
  log "Шаблон конфига Nginx записан в: $NGINX_REPO_CONF"

  if [ -f "$NGINX_SITE_CONF" ] || [ -L "$NGINX_SITE_CONF" ]; then
    cp -a "$NGINX_SITE_CONF" "${NGINX_SITE_CONF}.bak.$(date +%Y%m%d_%H%M%S)" || true
  fi

  case "$NGINX_DEPLOY_MODE" in
    symlink)
      ln -sfn "$NGINX_REPO_CONF" "$NGINX_SITE_CONF"
      ln -sfn "$NGINX_SITE_CONF" "$NGINX_SITE_ENABLED"
      ;;
    copy)
      cp -a "$NGINX_REPO_CONF" "$NGINX_SITE_CONF"
      ln -sfn "$NGINX_SITE_CONF" "$NGINX_SITE_ENABLED"
      ;;
    *)
      die "NGINX_DEPLOY_MODE должен быть symlink|copy, сейчас: $NGINX_DEPLOY_MODE"
      ;;
  esac

  nginx -t
  systemctl reload nginx
}

stage_setup_certbot() {
  log "Установка Certbot и выпуск сертификата"
  ensure_domain_vars

  apt update -y
  apt install -y certbot python3-certbot-nginx

  if [ "$CERTBOT_MODE" = "nginx" ]; then
    if ss -ltnp 2>/dev/null | grep -E ':443[[:space:]]' | grep -v nginx >/dev/null 2>&1; then
      warn "Порт 443 уже занят процессом, отличным от nginx."
      warn "Переключаю CERTBOT_MODE с nginx на webroot, чтобы избежать конфликта порта."
      CERTBOT_MODE="webroot"
    fi
  fi

  local certbot_args=()
  local domain_args=()
  domain_args+=(-d "$DOMAIN")
  if [ -n "${DOMAIN_WWW:-}" ]; then
    domain_args+=(-d "$DOMAIN_WWW")
  fi

  if [ -n "${CERTBOT_EMAIL:-}" ]; then
    certbot_args+=(--email "$CERTBOT_EMAIL" --agree-tos)
  else
    certbot_args+=(--register-unsafely-without-email --agree-tos)
  fi

  if is_yes "$CERTBOT_STAGING"; then
    certbot_args+=(--staging)
  fi

  if is_yes "$CERTBOT_NON_INTERACTIVE" || is_yes "$NON_INTERACTIVE"; then
    certbot_args+=(--non-interactive)
  fi

  case "$CERTBOT_MODE" in
    nginx)
      certbot --nginx "${certbot_args[@]}" "${domain_args[@]}"
      ;;
    webroot)
      install -d -m 755 /var/www/html
      certbot certonly --webroot -w /var/www/html "${certbot_args[@]}" "${domain_args[@]}"
      ;;
    *)
      die "CERTBOT_MODE должен быть nginx|webroot, сейчас: $CERTBOT_MODE"
      ;;
  esac

  systemctl reload nginx || true

  if ! certbot renew --dry-run; then
    warn "certbot renew --dry-run завершился ошибкой; проверьте DNS и доступность домена"
  fi
}

stage_install_cert_hook() {
  log "Установка deploy-hook сертификата для 3x-ui"

  [ -f "$HOOK_SCRIPT_REPO_PATH" ] || die "Скрипт hook не найден: $HOOK_SCRIPT_REPO_PATH"
  chmod +x "$HOOK_SCRIPT_REPO_PATH"

  install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy

  cat >"$HOOK_ENV_FILE" <<EOF
# Файл создан setup_vds_stack.sh
XUI_CERT_DST=${HOOK_CERT_DST}
XUI_CONTAINER_NAME=${XUI_CONTAINER_NAME}
CERT_DOMAIN=${DOMAIN:-}
EOF
  chmod 600 "$HOOK_ENV_FILE"

  case "$HOOK_INSTALL_MODE" in
    symlink)
      ln -sfn "$HOOK_SCRIPT_REPO_PATH" /etc/letsencrypt/renewal-hooks/deploy/cert-copy-to-3xui.sh
      ;;
    copy)
      install -m 700 "$HOOK_SCRIPT_REPO_PATH" /etc/letsencrypt/renewal-hooks/deploy/cert-copy-to-3xui.sh
      ;;
    *)
      die "HOOK_INSTALL_MODE должен быть symlink|copy, сейчас: $HOOK_INSTALL_MODE"
      ;;
  esac

  if [ -n "${DOMAIN:-}" ] && [ -d "/etc/letsencrypt/live/${DOMAIN}" ]; then
    CERT_DOMAIN="$DOMAIN" "$HOOK_SCRIPT_REPO_PATH" || warn "Тестовый запуск hook завершился ошибкой"
  else
    warn "Пропускаю тест hook: каталог сертификата не найден для DOMAIN='${DOMAIN:-}'"
  fi
}

stage_diagnostics() {
  log "Диагностика"

  echo "---- ОС ----"
  if [ -f /etc/os-release ]; then
    grep -E '^(PRETTY_NAME|ID|VERSION|VERSION_CODENAME)=' /etc/os-release || true
  fi

  echo "---- Сервисы ----"
  systemctl status nginx --no-pager || true
  systemctl status docker --no-pager || true

  echo "---- Проверка конфига Nginx ----"
  nginx -t || true

  echo "---- Слушающие порты ----"
  ss -ltnp | grep -E ':22|:80|:443|:8443|:20530' || true

  echo "---- Контейнеры Docker ----"
  if command -v docker >/dev/null 2>&1; then
    docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true
  fi

  echo "---- Certbot ----"
  if command -v certbot >/dev/null 2>&1; then
    certbot certificates || true
    systemctl list-timers | grep certbot || true
  fi

  echo "---- Deploy-hook ----"
  ls -la /etc/letsencrypt/renewal-hooks/deploy || true
}

CONFIG_FILE=""
STAGE=""
NON_INTERACTIVE="${NON_INTERACTIVE:-no}"

REPO_DIR="${REPO_DIR:-$SCRIPT_DIR}"

DOMAIN="${DOMAIN:-}"
DOMAIN_WWW="${DOMAIN_WWW:-}"
OPEN_UFW="${OPEN_UFW:-ask}"

CERTBOT_EMAIL="${CERTBOT_EMAIL:-}"
CERTBOT_MODE="${CERTBOT_MODE:-nginx}"
CERTBOT_STAGING="${CERTBOT_STAGING:-no}"
CERTBOT_NON_INTERACTIVE="${CERTBOT_NON_INTERACTIVE:-no}"

ENABLE_SSH_HARDENING="${ENABLE_SSH_HARDENING:-no}"
SSH_NEW_USER="${SSH_NEW_USER:-}"
SSH_PORT="${SSH_PORT:-2222}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-}"
SSH_DISABLE_ROOT_LOGIN="${SSH_DISABLE_ROOT_LOGIN:-yes}"
SSH_DISABLE_PASSWORD_AUTH="${SSH_DISABLE_PASSWORD_AUTH:-yes}"

DOCKER_REMOVE_CONFLICTING="${DOCKER_REMOVE_CONFLICTING:-no}"
DOCKER_ADD_USER_TO_GROUP="${DOCKER_ADD_USER_TO_GROUP:-no}"
DOCKER_GROUP_USER="${DOCKER_GROUP_USER:-${SUDO_USER:-}}"

XUI_DIR="${XUI_DIR:-}"
XUI_IMAGE="${XUI_IMAGE:-ghcr.io/mhsanaei/3x-ui:latest}"
XUI_CONTAINER_NAME="${XUI_CONTAINER_NAME:-3xui_app}"
XUI_HOSTNAME="${XUI_HOSTNAME:-}"
XUI_DB_DIR="${XUI_DB_DIR:-./db}"
XUI_CERT_DIR="${XUI_CERT_DIR:-./cert}"

PANEL_PATH="${PANEL_PATH:-/3x-secret}"
NGINX_PANEL_LISTEN="${NGINX_PANEL_LISTEN:-127.0.0.1:8443}"
NGINX_PANEL_UPSTREAM="${NGINX_PANEL_UPSTREAM:-127.0.0.1:20530}"

NGINX_REPO_CONF="${NGINX_REPO_CONF:-}"
NGINX_SITE_CONF="${NGINX_SITE_CONF:-/etc/nginx/sites-available/default}"
NGINX_SITE_ENABLED="${NGINX_SITE_ENABLED:-/etc/nginx/sites-enabled/default}"
NGINX_DEPLOY_MODE="${NGINX_DEPLOY_MODE:-symlink}"

HOOK_SCRIPT_REPO_PATH="${HOOK_SCRIPT_REPO_PATH:-}"
HOOK_INSTALL_MODE="${HOOK_INSTALL_MODE:-symlink}"
HOOK_ENV_FILE="${HOOK_ENV_FILE:-/etc/default/cert-copy-to-3xui}"
HOOK_CERT_DST="${HOOK_CERT_DST:-}"

ARGS=("$@")
i=0
while [ $i -lt $# ]; do
  if [ "${ARGS[$i]}" = "--config" ]; then
    [ $((i + 1)) -lt $# ] || die "Отсутствует значение для --config"
    CONFIG_FILE="${ARGS[$((i + 1))]}"
    break
  fi
  i=$((i + 1))
done

if [ -n "$CONFIG_FILE" ]; then
  load_config_file "$CONFIG_FILE"
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG_FILE="${2:-}"; shift 2 ;;
    --stage) STAGE="${2:-}"; shift 2 ;;
    --non-interactive) NON_INTERACTIVE="yes"; shift ;;

    --repo-dir) REPO_DIR="${2:-}"; shift 2 ;;
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --domain-www) DOMAIN_WWW="${2:-}"; shift 2 ;;
    --open-ufw) OPEN_UFW="${2:-}"; shift 2 ;;

    --cert-email) CERTBOT_EMAIL="${2:-}"; shift 2 ;;
    --cert-mode) CERTBOT_MODE="${2:-}"; shift 2 ;;
    --cert-staging) CERTBOT_STAGING="${2:-}"; shift 2 ;;
    --cert-non-interactive) CERTBOT_NON_INTERACTIVE="${2:-}"; shift 2 ;;

    --enable-ssh-hardening) ENABLE_SSH_HARDENING="${2:-}"; shift 2 ;;
    --ssh-user) SSH_NEW_USER="${2:-}"; shift 2 ;;
    --ssh-port) SSH_PORT="${2:-}"; shift 2 ;;
    --ssh-public-key) SSH_PUBLIC_KEY="${2:-}"; shift 2 ;;
    --ssh-disable-root) SSH_DISABLE_ROOT_LOGIN="${2:-}"; shift 2 ;;
    --ssh-disable-password) SSH_DISABLE_PASSWORD_AUTH="${2:-}"; shift 2 ;;

    -h|--help) usage; exit 0 ;;
    *) die "Неизвестный аргумент: $1 (используйте --help)" ;;
  esac
done

REPO_DIR="${REPO_DIR:-$SCRIPT_DIR}"

if [ -z "${XUI_DIR:-}" ]; then
  XUI_DIR="$REPO_DIR/3x-ui"
fi
if [ -z "${NGINX_REPO_CONF:-}" ]; then
  NGINX_REPO_CONF="$REPO_DIR/nginx/sites-available/default"
fi
if [ -z "${HOOK_SCRIPT_REPO_PATH:-}" ]; then
  HOOK_SCRIPT_REPO_PATH="$REPO_DIR/cert-copy-to-3xui.sh"
fi
if [ -z "${HOOK_CERT_DST:-}" ]; then
  HOOK_CERT_DST="$REPO_DIR/3x-ui/cert"
fi

if [ -z "${STAGE:-}" ]; then
  select_stage_interactive
fi

case "$STAGE" in
  preflight)
    stage_preflight
    ;;
  ssh)
    stage_preflight
    stage_ssh_hardening
    ;;
  docker)
    stage_preflight
    stage_install_docker
    ;;
  xui)
    stage_preflight
    stage_setup_xui
    ;;
  nginx)
    stage_preflight
    stage_configure_nginx
    ;;
  certbot)
    stage_preflight
    stage_setup_certbot
    ;;
  hook)
    stage_preflight
    stage_install_cert_hook
    ;;
  diag)
    stage_preflight
    stage_diagnostics
    ;;
  all)
    stage_preflight
    stage_ssh_hardening
    stage_install_docker
    stage_setup_xui
    stage_configure_nginx
    stage_setup_certbot
    stage_install_cert_hook
    stage_diagnostics
    ;;
  *)
    die "Неизвестный этап: $STAGE (ожидается preflight|ssh|docker|xui|nginx|certbot|hook|diag|all)"
    ;;
esac

log "Готово: этап '$STAGE'"
