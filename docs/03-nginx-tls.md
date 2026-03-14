# 03. Nginx + TLS (Let's Encrypt)

Установка Nginx, настройка домена и выпуск TLS-сертификата.

## Требования

- Debian/Ubuntu;
- домен(ы) уже указывает(ют) на IP сервера;
- входящие `80/tcp` и `443/tcp` открыты на уровне VDS/firewall.

## Переменные

- `DOMAIN` — основной домен (например, `example.com`)
- `DOMAIN_WWW` — дополнительный домен (например, `www.example.com`, опционально)

## 1) Установить Nginx

```bash
sudo apt update
sudo apt install -y nginx
sudo systemctl enable --now nginx
```

## 2) Настроить конфиг сайта

Базовый путь на Debian:

```text
/etc/nginx/sites-available/default
```

Пример server-блока для HTTP:

```nginx
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    server_name DOMAIN DOMAIN_WWW;

    root /var/www/html;
    index index.nginx-debian.html;

    location / {
        try_files $uri $uri/ =404;
    }
}
```

Проверка:

```bash
sudo nginx -t
sudo systemctl reload nginx
```

## 3) Установить Certbot

```bash
sudo apt update
sudo apt install -y certbot python3-certbot-nginx
```

## 4) Выпустить сертификат

```bash
sudo certbot --nginx -d DOMAIN -d DOMAIN_WWW
```

Если `DOMAIN_WWW` не нужен, используйте только один `-d`.

## 5) Проверить автопродление

```bash
systemctl list-timers | grep certbot || true
sudo certbot renew --dry-run
```

## 6) Установить deploy-hook для 3x-ui

```bash
sudo install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
sudo ln -sfn <repo-dir>/cert-copy-to-3xui.sh /etc/letsencrypt/renewal-hooks/deploy/cert-copy-to-3xui.sh
sudo chmod +x <repo-dir>/cert-copy-to-3xui.sh
```

## Автоматизация

Полный этап через скрипт:

```bash
sudo bash ./setup_vds_stack.sh --stage nginx
sudo bash ./setup_vds_stack.sh --stage certbot
sudo bash ./setup_vds_stack.sh --stage hook
```
