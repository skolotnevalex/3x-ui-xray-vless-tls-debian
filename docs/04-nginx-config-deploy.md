# 04. Деплой nginx-конфига из репозитория

Рекомендуемый подход: хранить «источник правды» в Git и подключать его в `/etc/nginx` через симлинк.

## Источник конфига

```text
<repo-dir>/nginx/sites-available/default
```

## Вариант A (рекомендуется): `sites-available` -> `sites-enabled`

### 1) Обновить репозиторий

```bash
cd <repo-dir>
git pull
```

### 2) Бэкап текущего файла

```bash
sudo cp -a /etc/nginx/sites-available/default /etc/nginx/sites-available/default.bak.$(date +%F_%H%M%S) || true
```

### 3) Подключить файл из репозитория

```bash
sudo ln -sfn <repo-dir>/nginx/sites-available/default /etc/nginx/sites-available/default
sudo ln -sfn /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
```

### 4) Проверить и применить

```bash
sudo nginx -t
sudo systemctl reload nginx
```

## Вариант B: прямой симлинк в `sites-enabled`

```bash
sudo ln -sfn <repo-dir>/nginx/sites-available/default /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx
```

## Типовой цикл обновления

```bash
cd <repo-dir>
git pull
sudo nginx -t && sudo systemctl reload nginx
```

## Быстрый откат

```bash
ls -la /etc/nginx/sites-available/default.bak.* || true
sudo cp -a /etc/nginx/sites-available/default.bak.YYYY-MM-DD_HHMMSS /etc/nginx/sites-available/default
sudo nginx -t && sudo systemctl reload nginx
```
