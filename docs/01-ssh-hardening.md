# 01. Базовая подготовка сервера и SSH-hardening

Инструкция для нового Debian/Ubuntu-сервера с root-доступом.

## Что делает этот этап

- обновляет пакеты;
- создает отдельного пользователя с `sudo`;
- настраивает SSH-ключи;
- меняет SSH-порт;
- отключает root-логин и вход по паролю;
- включает UFW и открывает новый SSH-порт.

## Предварительные условия

- у вас уже есть рабочий root-доступ по SSH;
- на уровне провайдера/VDS firewall открыт порт, который будете использовать для SSH;
- вы понимаете риск потери доступа при ошибке в `sshd_config`.

## Шаги

### 1) Установить базовые пакеты

```bash
apt update
apt install -y sudo git ufw
```

### 2) Обновить систему

```bash
apt update && apt upgrade -y
```

### 3) Создать отдельного пользователя

```bash
adduser <ssh-user>
usermod -aG sudo <ssh-user>
groups <ssh-user>
```

### 4) Добавить SSH-ключ пользователю

```bash
install -d -m 700 /home/<ssh-user>/.ssh
nano /home/<ssh-user>/.ssh/authorized_keys
chmod 600 /home/<ssh-user>/.ssh/authorized_keys
chown -R <ssh-user>:<ssh-user> /home/<ssh-user>/.ssh
```

### 5) Настроить SSH

Откройте файл:

```bash
nano /etc/ssh/sshd_config
```

Минимальные изменения:

```text
Port 2222
PermitRootLogin no
PasswordAuthentication no
```

### 6) Проверить и применить

```bash
sshd -t
systemctl restart ssh || systemctl restart sshd
```

### 7) Включить UFW

```bash
ufw allow 2222/tcp
ufw enable
ufw status
```

### 8) Проверить новый вход

Откройте новую сессию терминала и проверьте:

```bash
ssh <ssh-user>@SERVER_IP -p 2222
```

Не закрывайте старую root-сессию, пока не убедитесь, что новый вход работает.

## Автоматизация

Те же действия можно запускать через `setup_vds_stack.sh` (`--stage ssh`).

Важно: по умолчанию этот этап выключен в `--stage all`.
