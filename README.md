# VDS VPN (Debian): Nginx + 3x-ui/Xray + TLS

Репозиторий с конфигами и инструкциями для разворачивания VPN-стека на Debian:

- подготовка сервера и SSH-hardening;
- установка Docker Engine;
- запуск `3x-ui` (Xray) через Docker Compose;
- настройка Nginx как reverse-proxy;
- выпуск и продление TLS-сертификатов (Certbot);
- автоматическое копирование сертификата в `3x-ui`.

## Быстрый старт

```bash
cp ./setup.env.example ./setup.env
nano ./setup.env
sudo bash ./setup_vds_stack.sh --stage all --config ./setup.env --non-interactive
```

Интерактивный запуск:

```bash
sudo bash ./setup_vds_stack.sh
```

## Структура документации

Основные инструкции вынесены в каталог `docs/`:

- `docs/01-ssh-hardening.md` — безопасная базовая настройка SSH;
- `docs/02-docker-install.md` — установка Docker Engine и Compose plugin;
- `docs/03-nginx-tls.md` — установка Nginx и TLS через Certbot;
- `docs/04-nginx-config-deploy.md` — как подключать nginx-конфиг из репозитория;
- `docs/05-automation-script.md` — подробное использование `setup_vds_stack.sh`;
- `docs/06-troubleshooting.md` — типовая диагностика и быстрый откат.

## Важные файлы проекта

- `setup_vds_stack.sh` — единый сценарий установки и диагностики;
- `setup.env.example` — шаблон переменных для неинтерактивного запуска;
- `3x-ui/docker-compose.yml` — compose-конфиг `3x-ui`;
- `nginx/sites-available/default` — nginx-конфиг из репозитория;
- `cert-copy-to-3xui.sh` — deploy-hook для Certbot.

## Обратная совместимость

Старые файлы `Docker.md`, `NGINX.md`, `NGINX_CONFIG_DEPLOY.md` сохранены и указывают на актуальные документы в `docs/`.
