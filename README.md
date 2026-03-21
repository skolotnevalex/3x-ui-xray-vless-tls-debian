# VDS (Debian): Nginx + 3x-ui/Xray + TLS

Репозиторий с конфигами и инструкциями для разворачивания 3x-ui, xray, vless-tls стека на Debian:

- подготовка сервера и SSH-hardening;
- установка Docker Engine;
- запуск `3x-ui` (Xray) через Docker Compose;
- настройка Nginx как reverse-proxy;
- выпуск и продление TLS-сертификатов (Certbot);
- автоматическое копирование сертификата в `3x-ui`;
- отдельный сценарий для машины без домена: `IP + self-signed TLS`.

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
- `docs/06-troubleshooting.md` — типовая диагностика и быстрый откат;
- `docs/07-self-signed-ip.md` — отдельный сценарий: `nginx:20530` для панели и `nginx:8443` для тестовой страницы.

## Важные файлы проекта

- `setup_vds_stack.sh` — единый сценарий установки и диагностики;
- `setup_vds_selfsigned_ip.sh` — отдельный сценарий для машины без домена;
- `setup.env.example` — шаблон переменных для неинтерактивного запуска;
- `3x-ui/docker-compose.yml` — compose-конфиг `3x-ui`;
- `3x-ui/docker-compose.selfsigned.yml` — отдельный compose для `IP + self-signed`;
- `nginx/sites-available/default` — nginx-конфиг из репозитория;
- `nginx/sites-available/selfsigned-ip.conf` — nginx-шаблон для `IP + self-signed`;
- `cert-copy-to-3xui.sh` — deploy-hook для Certbot.

## Обратная совместимость

Старые файлы `Docker.md`, `NGINX.md`, `NGINX_CONFIG_DEPLOY.md` сохранены и указывают на актуальные документы в `docs/`.
