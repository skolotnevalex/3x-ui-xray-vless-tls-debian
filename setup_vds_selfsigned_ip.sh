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
  sudo bash ./setup_vds_selfsigned_ip.sh [параметры]

Сценарий:
  - устанавливает Docker Engine из официального репозитория;
  - устанавливает Nginx;
  - генерирует self-signed сертификат для IP-адреса;
  - настраивает Nginx на два HTTPS listener:
    * 20530 -> /3x-secret/ -> локальная панель 3x-ui на 127.0.0.1:2053
    * 8443 -> тестовая nginx-страница
  - поднимает 3x-ui через отдельный docker-compose.

Параметры:
  --repo-dir <path>                   Путь к репозиторию на сервере.
  --server-ip <IPv4>                  IP-адрес сервера для сертификата и server_name.
  --panel-path <path>                 Внешний путь панели в Nginx (по умолчанию: /3x-secret).
  --open-ufw <yes|no|ask>             Открывать 20530/8443 в UFW (по умолчанию: ask).

  --xui-image <image>                 Docker image 3x-ui.
  --xui-container-name <name>         Имя контейнера 3x-ui.
  --xui-hostname <name>               Hostname контейнера 3x-ui.
  --xui-panel-port <port>             Локальный host-порт панели 3x-ui (по умолчанию: 2053).

  --nginx-panel-port <port>           Порт Nginx для панели (по умолчанию: 20530).
  --nginx-test-port <port>            Порт Nginx для тестовой страницы (по умолчанию: 8443).

  --cert-dir <path>                   Каталог для self-signed сертификата.
  --cert-days <days>                  Срок действия сертификата в днях (по умолчанию: 825).

  --compose-file <path>               Отдельный docker-compose файл.
  --compose-env-file <path>           Env-файл для docker compose.
  --nginx-template <path>             Шаблон nginx-конфига из репозитория.
  --nginx-site-conf <path>            Итоговый конфиг сайта в /etc/nginx/sites-available.
  --nginx-site-enabled <path>         Ссылка в /etc/nginx/sites-enabled.

  --non-interactive                   Не задавать вопросы; при нехватке параметров завершиться с ошибкой.
  -h, --help                          Показать справку.

Примеры:
  sudo bash ./setup_vds_selfsigned_ip.sh --server-ip 203.0.113.10
  sudo bash ./setup_vds_selfsigned_ip.sh --server-ip 203.0.113.10 --panel-path /admin
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
  local answer=""

  if is_yes "${NON_INTERACTIVE:-no}"; then
    return 1
  fi

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
  local current_value="${!var_name:-}"

  if [ -n "$current_value" ]; then
    return 0
  fi

  if is_yes "${NON_INTERACTIVE:-no}"; then
    die "В неинтерактивном режиме не задан обязательный параметр: $var_name"
  fi

  local result
  result="$(prompt "$message" "$default_value")"
  printf -v "$var_name" '%s' "$result"

  [ -n "${!var_name:-}" ] || die "Обязательное значение пустое: $var_name"
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "Команда не найдена: $cmd"
}

backup_if_exists() {
  local path="$1"
  if [ -f "$path" ] || [ -L "$path" ]; then
    cp -a "$path" "${path}.bak.$(date +%Y%m%d_%H%M%S)" || true
  fi
}

normalize_panel_path() {
  PANEL_PATH="/${PANEL_PATH#/}"
  PANEL_PATH="${PANEL_PATH%/}"
  [ -n "$PANEL_PATH" ] || PANEL_PATH="/3x-secret"
  [ "$PANEL_PATH" = "/" ] && die "PANEL_PATH не может быть равен '/'. Используйте, например, /3x-secret"
  PANEL_PATH_WITH_SLASH="${PANEL_PATH}/"
}

auto_detect_server_ip() {
  local detected=""

  if command -v ip >/dev/null 2>&1; then
    detected="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1)"
  fi

  if [ -z "$detected" ] && command -v hostname >/dev/null 2>&1; then
    detected="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi

  printf '%s' "$detected"
}

maybe_open_ufw_ports() {
  if ! command -v ufw >/dev/null 2>&1; then
    log "UFW не установлен, этап изменения firewall пропущен"
    return 0
  fi

  case "${OPEN_UFW:-ask}" in
    yes|YES|y|Y)
      log "Открываю в UFW порты ${NGINX_PANEL_PORT}/tcp и ${NGINX_TEST_PORT}/tcp"
      ufw allow "${NGINX_PANEL_PORT}/tcp"
      ufw allow "${NGINX_TEST_PORT}/tcp"
      ;;
    no|NO|n|N)
      log "Оставляю UFW без изменений"
      ;;
    ask|"")
      if confirm "Открыть в UFW порты ${NGINX_PANEL_PORT}/tcp и ${NGINX_TEST_PORT}/tcp?"; then
        ufw allow "${NGINX_PANEL_PORT}/tcp"
        ufw allow "${NGINX_TEST_PORT}/tcp"
      else
        log "Оставляю UFW без изменений"
      fi
      ;;
    *)
      die "OPEN_UFW должен быть yes|no|ask, сейчас: ${OPEN_UFW:-<empty>}"
      ;;
  esac
}

install_docker() {
  log "Установка Docker Engine"

  apt update -y
  apt remove -y docker.io docker-compose docker-doc podman-docker containerd runc || true
  apt install -y ca-certificates curl

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  apt update -y
  apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}

install_nginx() {
  log "Установка Nginx"

  apt update -y
  apt install -y nginx openssl
  systemctl enable --now nginx
  maybe_open_ufw_ports
}

generate_self_signed_cert() {
  log "Генерация self-signed сертификата для IP ${SERVER_IP}"

  install -d -m 700 "$CERT_DIR"
  backup_if_exists "$CERT_FULLCHAIN"
  backup_if_exists "$CERT_PRIVKEY"

  openssl req \
    -x509 \
    -nodes \
    -newkey rsa:4096 \
    -keyout "$CERT_PRIVKEY" \
    -out "$CERT_FULLCHAIN" \
    -days "$CERT_DAYS" \
    -subj "/CN=${SERVER_IP}" \
    -addext "subjectAltName = IP:${SERVER_IP}" \
    -addext "keyUsage = digitalSignature, keyEncipherment" \
    -addext "extendedKeyUsage = serverAuth"

  chmod 600 "$CERT_PRIVKEY"
  chmod 644 "$CERT_FULLCHAIN"
}

write_compose_env() {
  log "Подготовка env-файла для docker compose"

  install -d "$XUI_DIR" "$XUI_DB_DIR"
  backup_if_exists "$COMPOSE_ENV_FILE"

  cat >"$COMPOSE_ENV_FILE" <<EOF
THREEXUI_IMAGE=${XUI_IMAGE}
THREEXUI_CONTAINER_NAME=${XUI_CONTAINER_NAME}
THREEXUI_HOSTNAME=${XUI_HOSTNAME}
THREEXUI_DB_DIR=${XUI_DB_DIR_REL}
THREEXUI_PANEL_BIND=127.0.0.1
THREEXUI_PANEL_PORT=${XUI_PANEL_PORT}
EOF
}

deploy_nginx_config() {
  log "Рендеринг nginx-конфига"

  [ -f "$NGINX_TEMPLATE" ] || die "Шаблон nginx не найден: $NGINX_TEMPLATE"

  install -d "$(dirname "$NGINX_SITE_CONF")" "$(dirname "$NGINX_SITE_ENABLED")"
  backup_if_exists "$NGINX_SITE_CONF"

  sed \
    -e "s|__SERVER_IP__|$SERVER_IP|g" \
    -e "s|__PANEL_PATH__|$PANEL_PATH|g" \
    -e "s|__PANEL_PATH_WITH_SLASH__|$PANEL_PATH_WITH_SLASH|g" \
    -e "s|__PANEL_UPSTREAM__|127.0.0.1:$XUI_PANEL_PORT|g" \
    -e "s|__SSL_CERT__|$CERT_FULLCHAIN|g" \
    -e "s|__SSL_KEY__|$CERT_PRIVKEY|g" \
    -e "s|__NGINX_PANEL_PORT__|$NGINX_PANEL_PORT|g" \
    -e "s|__NGINX_TEST_PORT__|$NGINX_TEST_PORT|g" \
    "$NGINX_TEMPLATE" >"$NGINX_SITE_CONF"

  ln -sfn "$NGINX_SITE_CONF" "$NGINX_SITE_ENABLED"
  nginx -t
  systemctl reload nginx
}

start_xui() {
  log "Запуск контейнера 3x-ui"

  [ -f "$COMPOSE_FILE" ] || die "Compose-файл не найден: $COMPOSE_FILE"
  (
    cd "$XUI_DIR"
    docker compose --env-file "$COMPOSE_ENV_FILE" -f "$COMPOSE_FILE" pull || warn "docker compose pull завершился с ошибкой, продолжаю"
    docker compose --env-file "$COMPOSE_ENV_FILE" -f "$COMPOSE_FILE" up -d
  )

  docker ps --format '{{.Names}}' | grep -q "^${XUI_CONTAINER_NAME}\$" \
    || warn "Контейнер $XUI_CONTAINER_NAME не найден в списке docker ps"
}

main() {
  NON_INTERACTIVE="no"
  REPO_DIR="$SCRIPT_DIR"
  OPEN_UFW="ask"

  XUI_IMAGE="ghcr.io/mhsanaei/3x-ui:latest"
  XUI_CONTAINER_NAME="3xui_selfsigned"
  XUI_HOSTNAME="3x-ui-selfsigned"
  XUI_PANEL_PORT="2053"
  PANEL_PATH="/3x-secret"

  NGINX_PANEL_PORT="20530"
  NGINX_TEST_PORT="8443"

  CERT_DIR="/etc/ssl/3x-ui-selfsigned"
  CERT_DAYS="825"

  while [ $# -gt 0 ]; do
    case "$1" in
      --repo-dir)
        REPO_DIR="$2"
        shift 2
        ;;
      --server-ip)
        SERVER_IP="$2"
        shift 2
        ;;
      --panel-path)
        PANEL_PATH="$2"
        shift 2
        ;;
      --open-ufw)
        OPEN_UFW="$2"
        shift 2
        ;;
      --xui-image)
        XUI_IMAGE="$2"
        shift 2
        ;;
      --xui-container-name)
        XUI_CONTAINER_NAME="$2"
        shift 2
        ;;
      --xui-hostname)
        XUI_HOSTNAME="$2"
        shift 2
        ;;
      --xui-panel-port)
        XUI_PANEL_PORT="$2"
        shift 2
        ;;
      --nginx-panel-port)
        NGINX_PANEL_PORT="$2"
        shift 2
        ;;
      --nginx-test-port)
        NGINX_TEST_PORT="$2"
        shift 2
        ;;
      --cert-dir)
        CERT_DIR="$2"
        shift 2
        ;;
      --cert-days)
        CERT_DAYS="$2"
        shift 2
        ;;
      --compose-file)
        COMPOSE_FILE="$2"
        shift 2
        ;;
      --compose-env-file)
        COMPOSE_ENV_FILE="$2"
        shift 2
        ;;
      --nginx-template)
        NGINX_TEMPLATE="$2"
        shift 2
        ;;
      --nginx-site-conf)
        NGINX_SITE_CONF="$2"
        shift 2
        ;;
      --nginx-site-enabled)
        NGINX_SITE_ENABLED="$2"
        shift 2
        ;;
      --non-interactive)
        NON_INTERACTIVE="yes"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Неизвестный параметр: $1"
        ;;
    esac
  done

  [ "${EUID:-$(id -u)}" -eq 0 ] || die "Запустите от root: sudo bash ./$SCRIPT_NAME ..."

  require_cmd apt
  require_cmd systemctl
  require_cmd sed
  require_cmd grep

  REPO_DIR="$(cd "$REPO_DIR" && pwd -P)"
  XUI_DIR="$REPO_DIR/3x-ui"
  XUI_DB_DIR="$XUI_DIR/db-selfsigned"
  XUI_DB_DIR_REL="./db-selfsigned"

  COMPOSE_FILE="${COMPOSE_FILE:-$XUI_DIR/docker-compose.selfsigned.yml}"
  COMPOSE_ENV_FILE="${COMPOSE_ENV_FILE:-$XUI_DIR/.env.selfsigned}"
  NGINX_TEMPLATE="${NGINX_TEMPLATE:-$REPO_DIR/nginx/sites-available/selfsigned-ip.conf}"
  NGINX_SITE_CONF="${NGINX_SITE_CONF:-/etc/nginx/sites-available/3x-ui-selfsigned}"
  NGINX_SITE_ENABLED="${NGINX_SITE_ENABLED:-/etc/nginx/sites-enabled/3x-ui-selfsigned}"
  CERT_FULLCHAIN="$CERT_DIR/fullchain.pem"
  CERT_PRIVKEY="$CERT_DIR/privkey.pem"

  normalize_panel_path

  SERVER_IP="${SERVER_IP:-$(auto_detect_server_ip)}"
  prompt_if_empty SERVER_IP "IP-адрес сервера для сертификата и доступа к панели"

  log "Сводка параметров"
  printf '  REPO_DIR=%s\n' "$REPO_DIR"
  printf '  SERVER_IP=%s\n' "$SERVER_IP"
  printf '  PANEL_PATH=%s\n' "$PANEL_PATH"
  printf '  XUI_PANEL_PORT=%s\n' "$XUI_PANEL_PORT"
  printf '  NGINX_PANEL_PORT=%s\n' "$NGINX_PANEL_PORT"
  printf '  NGINX_TEST_PORT=%s\n' "$NGINX_TEST_PORT"
  printf '  CERT_DIR=%s\n' "$CERT_DIR"

  install_docker
  install_nginx
  generate_self_signed_cert
  write_compose_env
  start_xui
  deploy_nginx_config

  log "Готово"
  printf 'Панель: https://%s:%s%s\n' "$SERVER_IP" "$NGINX_PANEL_PORT" "$PANEL_PATH_WITH_SLASH"
  printf 'Тестовый Nginx: https://%s:%s/\n' "$SERVER_IP" "$NGINX_TEST_PORT"
  printf 'В браузере будет предупреждение, пока self-signed сертификат не добавлен в доверенные.\n'
}

main "$@"