# 07. 3x-ui по IP + self-signed TLS

Отдельный сценарий для второй машины, где нет доменного имени и доступ нужен по IP-адресу.

Этот вариант подготовлен под схему:

- `nginx:20530` — self-signed HTTPS для панели `3x-ui` по пути `/3x-secret/`;
- `nginx:8443` — self-signed HTTPS с тестовой nginx-страницей;
- `3x-ui` слушает только локально на `127.0.0.1:2053`;
- позже можно повесить `xray` на `443` и настроить fallback на `8443`.

## Что делает сценарий

- устанавливает Docker Engine;
- устанавливает Nginx;
- генерирует self-signed сертификат для IP-адреса;
- подключает сертификат в два nginx listener: `20530` и `8443`;
- запускает `3x-ui` через отдельный compose-файл `3x-ui/docker-compose.selfsigned.yml`.

## Файлы сценария

- `setup_vds_selfsigned_ip.sh` — standalone-скрипт установки;
- `3x-ui/docker-compose.selfsigned.yml` — отдельный compose для панели;
- `nginx/sites-available/selfsigned-ip.conf` — шаблон nginx-конфига.

## Быстрый запуск

На второй машине:

```bash
git clone <repo-url>
cd 3x-ui-xray-vless-tls-debian
sudo bash ./setup_vds_selfsigned_ip.sh --server-ip <SERVER_IP>
```

После выполнения будут доступны два адреса:

```text
https://<SERVER_IP>:20530/3x-secret/
https://<SERVER_IP>:8443/
```

## Если нужен другой путь панели

Можно заменить `/3x-secret` на свой путь:

```bash
sudo bash ./setup_vds_selfsigned_ip.sh --server-ip <SERVER_IP> --panel-path /my-secret
```

Тогда адрес панели будет таким:

```text
https://<SERVER_IP>:20530/my-secret/
```

Важно: если потом в самой `3x-ui` меняете `webBasePath` или аналогичный путь панели, держите его таким же, как `--panel-path` в Nginx.

## Порты и трафик

### Панель 3x-ui

Compose публикует панель только в loopback хоста:

```text
127.0.0.1:2053 -> container:2053
```

То есть снаружи порт `2053` не торчит, а наружу панель отдает только Nginx через:

```text
https://<SERVER_IP>:20530/3x-secret/
```

### Тестовый Nginx listener

Nginx также поднимает отдельный HTTPS listener:

```text
https://<SERVER_IP>:8443/
```

Это удобно как промежуточная точка перед схемой `xray:443 -> fallback -> nginx:8443`.

## Self-signed сертификат

Сертификат создается в каталоге:

```text
/etc/ssl/3x-ui-selfsigned
```

Файлы:

- `/etc/ssl/3x-ui-selfsigned/fullchain.pem`
- `/etc/ssl/3x-ui-selfsigned/privkey.pem`

Сертификат выпускается с `subjectAltName = IP:<SERVER_IP>` и используется одновременно для `20530` и `8443`.

## Полезные параметры

```bash
sudo bash ./setup_vds_selfsigned_ip.sh \
  --server-ip <SERVER_IP> \
  --panel-path /3x-secret \
  --xui-panel-port 2053 \
  --nginx-panel-port 20530 \
  --nginx-test-port 8443 \
  --open-ufw yes
```

Дополнительные параметры:

- `--repo-dir` — если репозиторий лежит не рядом со скриптом;
- `--cert-dir` — другой каталог для сертификатов;
- `--cert-days` — срок действия сертификата;
- `--xui-image` — другой образ `3x-ui`;
- `--xui-container-name` — имя контейнера;
- `--non-interactive` — не задавать вопросы.

## Проверка после установки

```bash
docker ps
docker compose -f 3x-ui/docker-compose.selfsigned.yml --env-file 3x-ui/.env.selfsigned ps
sudo nginx -t
systemctl status nginx --no-pager
systemctl status docker --no-pager
ss -ltnp | grep -E ':2053|:20530|:8443'
curl -k https://<SERVER_IP>:20530/3x-secret/
curl -k https://<SERVER_IP>:8443/
```

## Что важно понимать

- браузер все равно будет показывать предупреждение, пока сертификат не добавлен в доверенные;
- self-signed сертификат подходит для админ-панели и тестового listener, но не заменяет нормальный публичный TLS;
- этот сценарий не использует Certbot и не требует домена.

## Обновление сертификата

Так как сертификат self-signed, автопродления через Certbot здесь нет.

Чтобы перевыпустить сертификат, достаточно заново запустить тот же скрипт:

```bash
sudo bash ./setup_vds_selfsigned_ip.sh --server-ip <SERVER_IP>
```

Старые `fullchain.pem` и `privkey.pem` перед перезаписью бэкапятся.