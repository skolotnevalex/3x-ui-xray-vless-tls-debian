#!/usr/bin/env sh
set -eu

# Необязательный env-файл с переопределениями.
# Ожидаемые ключи:
#   XUI_CERT_DST=/path/to/3x-ui/cert
#   XUI_CONTAINER_NAME=3xui_app
#   CERT_DOMAIN=example.com
HOOK_ENV_FILE="${HOOK_ENV_FILE:-/etc/default/cert-copy-to-3xui}"
if [ -f "$HOOK_ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "$HOOK_ENV_FILE"
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
XUI_CERT_DST="${XUI_CERT_DST:-$SCRIPT_DIR/3x-ui/cert}"
XUI_CONTAINER_NAME="${XUI_CONTAINER_NAME:-3xui_app}"
CERT_DOMAIN="${CERT_DOMAIN:-}"
LE_LIVE_DIR="${LE_LIVE_DIR:-/etc/letsencrypt/live}"

# В контексте certbot deploy-hook приоритет у RENEWED_LINEAGE.
if [ -n "${RENEWED_LINEAGE:-}" ]; then
  SRC="$RENEWED_LINEAGE"
elif [ -n "$CERT_DOMAIN" ]; then
  SRC="$LE_LIVE_DIR/$CERT_DOMAIN"
else
  echo "ERROR: CERT_DOMAIN пуст и RENEWED_LINEAGE не задан" >&2
  exit 1
fi

[ -d "$SRC" ] || {
  echo "ERROR: каталог сертификата не найден: $SRC" >&2
  exit 1
}

install -d -m 700 "$XUI_CERT_DST"
install -m 600 "$SRC/privkey.pem" "$XUI_CERT_DST/privkey.pem"
install -m 644 "$SRC/fullchain.pem" "$XUI_CERT_DST/fullchain.pem"

if command -v docker >/dev/null 2>&1; then
  if docker ps -a --format '{{.Names}}' | grep -qx "$XUI_CONTAINER_NAME"; then
    docker restart "$XUI_CONTAINER_NAME" >/dev/null
    echo "OK: сертификаты скопированы, контейнер '$XUI_CONTAINER_NAME' перезапущен"
  else
    echo "WARN: контейнер '$XUI_CONTAINER_NAME' не найден, сертификаты скопированы"
  fi
else
  echo "WARN: команда docker не найдена, сертификаты скопированы"
fi
