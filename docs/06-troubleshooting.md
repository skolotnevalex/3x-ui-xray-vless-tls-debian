# 06. Диагностика и восстановление

Набор команд для быстрой проверки после установки.

## Проверка Nginx

```bash
sudo nginx -t
sudo systemctl status nginx --no-pager
sudo journalctl -u nginx -n 200 --no-pager
sudo ss -ltnp | grep -E ':80|:443|:8443' || true
```

## Проверка Docker и 3x-ui

```bash
sudo systemctl status docker --no-pager
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
docker logs --tail 200 3xui_app
```

## Проверка Certbot

```bash
sudo certbot certificates
systemctl list-timers | grep certbot || true
sudo certbot renew --dry-run
```

## Проверка deploy-hook

```bash
ls -la /etc/letsencrypt/renewal-hooks/deploy
sudo cat /etc/default/cert-copy-to-3xui
```

Ручной тест (если сертификат уже выпущен):

```bash
sudo CERT_DOMAIN=example.com <repo-dir>/cert-copy-to-3xui.sh
```

## Быстрый откат Nginx-конфига

```bash
ls -la /etc/nginx/sites-available/default.bak.* || true
sudo cp -a /etc/nginx/sites-available/default.bak.YYYY-MM-DD_HHMMSS /etc/nginx/sites-available/default
sudo nginx -t && sudo systemctl reload nginx
```

## Диагностика через скрипт

```bash
sudo bash ./setup_vds_stack.sh --stage diag --config ./setup.env --non-interactive
```
