# 02. Установка Docker Engine на Debian

Установка через официальный репозиторий Docker.

## Что будет установлено

- `docker-ce`
- `docker-ce-cli`
- `containerd.io`
- `docker-buildx-plugin`
- `docker-compose-plugin`

## 1) (Опционально) удалить конфликтующие пакеты

```bash
sudo apt remove -y docker.io docker-compose docker-doc podman-docker containerd runc || true
```

## 2) Добавить ключ и репозиторий Docker

```bash
sudo apt update
sudo apt install -y ca-certificates curl

sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

sudo tee /etc/apt/sources.list.d/docker.sources > /dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt update
```

## 3) Установить Docker Engine

```bash
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
```

## 4) Проверка

```bash
sudo docker run --rm hello-world
docker compose version
systemctl status docker --no-pager
```

## 5) (Опционально) запуск Docker без `sudo`

```bash
sudo usermod -aG docker $USER
newgrp docker
```

Добавляйте в группу `docker` только доверенных пользователей.

## Важное замечание про UFW

Порты, опубликованные Docker (`-p`), могут быть доступны снаружи независимо от правил UFW.

Для сервисов, которые должны быть доступны только локально (через Nginx на том же хосте), публикуйте порт в loopback:

```yaml
ports:
  - "127.0.0.1:2053:2053"
```

## Автоматизация

Через скрипт проекта:

```bash
sudo bash ./setup_vds_stack.sh --stage docker
```
