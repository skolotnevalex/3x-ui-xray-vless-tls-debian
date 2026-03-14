# 05. Автоматический установщик `setup_vds_stack.sh`

Скрипт автоматизирует разворачивание всего стека из этого репозитория.

## Что умеет

- запуск по этапам;
- интерактивный ввод значений;
- запуск по конфиг-файлу;
- базовая диагностика;
- установка deploy-hook Certbot для `3x-ui`.

## Этапы

- `preflight` — проверка окружения;
- `ssh` — SSH-hardening (опционально, потенциально рискованный этап);
- `docker` — установка Docker;
- `xui` — запуск `3x-ui`;
- `nginx` — установка и конфиг Nginx;
- `certbot` — выпуск сертификатов;
- `hook` — установка deploy-hook;
- `diag` — диагностика;
- `all` — полный прогон.

## Рекомендуемый способ

### 1) Подготовить конфиг

```bash
cp ./setup.env.example ./setup.env
nano ./setup.env
```

### 2) Полный запуск

```bash
sudo bash ./setup_vds_stack.sh --stage all --config ./setup.env --non-interactive
```

## Интерактивный запуск

```bash
sudo bash ./setup_vds_stack.sh
```

## Частые сценарии

Только Docker:

```bash
sudo bash ./setup_vds_stack.sh --stage docker --config ./setup.env --non-interactive
```

Только Certbot:

```bash
sudo bash ./setup_vds_stack.sh --stage certbot --config ./setup.env --non-interactive
```

Только диагностика:

```bash
sudo bash ./setup_vds_stack.sh --stage diag --config ./setup.env --non-interactive
```

## Важные параметры

- `DOMAIN`, `DOMAIN_WWW`
- `CERTBOT_EMAIL`
- `OPEN_UFW`
- `PANEL_PATH`
- `NGINX_PANEL_LISTEN`
- `NGINX_PANEL_UPSTREAM`
- `XUI_CONTAINER_NAME`
- `ENABLE_SSH_HARDENING`

Полный список смотрите в `setup.env.example`.
