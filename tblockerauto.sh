#!/bin/bash

#================================================================================
# Интерактивный установщик tblocker (с принудительным вводом)
#================================================================================

# Выход при любой ошибке
set -e

# Проверка, что скрипт запущен от имени root
if [[ $EUID -ne 0 ]]; then
   echo "Этот скрипт необходимо запустить с правами root или через sudo." 
   exit 1
fi

clear
echo "Добро пожаловать в интерактивный установщик tblocker."
echo "Пожалуйста, введите все необходимые значения. Пустой ввод не допускается."
echo ""

# --- 1. СБОР ДАННЫХ ---
# Мы будем запрашивать ввод в цикле, пока он не перестанет быть пустым.

BLOCK_DURATION=""
while [ -z "$BLOCK_DURATION" ]; do
  read -p "Введите время блокировки (в минутах): " BLOCK_DURATION
  if [ -z "$BLOCK_DURATION" ]; then
    echo "Ошибка: Поле не может быть пустым. Пожалуйста, введите значение."
  fi
done

ADMIN_WEBHOOK_URL=""
while [ -z "$ADMIN_WEBHOOK_URL" ]; do
  read -p "Введите URL админ-вебхука (Bot API): " ADMIN_WEBHOOK_URL
  if [ -z "$ADMIN_WEBHOOK_URL" ]; then
    echo "Ошибка: Поле не может быть пустым. Пожалуйста, введите значение."
  fi
done

ADMIN_CHAT_ID=""
while [ -z "$ADMIN_CHAT_ID" ]; do
  read -p "Введите ID чата Telegram администратора: " ADMIN_CHAT_ID
  if [ -z "$ADMIN_CHAT_ID" ]; then
    echo "Ошибка: Поле не может быть пустым. Пожалуйста, введите значение."
  fi
done

SERVER_NAME=""
while [ -z "$SERVER_NAME" ]; do
  read -p "Введите имя этого сервера (для уведомлений): " SERVER_NAME
  if [ -z "$SERVER_NAME" ]; then
    echo "Ошибка: Поле не может быть пустым. Пожалуйста, введите значение."
  fi
done

USER_BOT_TOKEN=""
while [ -z "$USER_BOT_TOKEN" ]; do
  read -p "Введите токен бота для уведомления *пользователей*: " USER_BOT_TOKEN
  if [ -z "$USER_BOT_TOKEN" ]; then
    echo "Ошибка: Поле не может быть пустым. Пожалуйста, введите значение."
  fi
done

CRON_SCHEDULE=""
while [ -z "$CRON_SCHEDULE" ]; do
  echo "Введите расписание Cron для скрипта уведомлений (например: */20 * * * * )"
  read -p "> " CRON_SCHEDULE
  if [ -z "$CRON_SCHEDULE" ]; then
    echo "Ошибка: Поле не может быть пустым. Пожалуйста, введите значение."
  fi
done

# --- 2. ПОДТВЕРЖДЕНИЕ ---

echo ""
echo "---"
echo "Пожалуйста, проверьте введенные данные:"
echo "----------------------------------------"
echo "Время блокировки:    ${BLOCK_DURATION} минут"
echo "URL админ-вебхука:   ${ADMIN_WEBHOOK_URL}"
echo "ID админ-чата:       ${ADMIN_CHAT_ID}"
echo "Имя сервера:         ${SERVER_NAME}"
echo "Токен user-бота:     ${USER_BOT_TOKEN}"
echo "Расписание Cron:     ${CRON_SCHEDULE}"
echo "----------------------------------------"
echo ""

read -p "Все верно? Начать установку? (y/n): " confirm
if [[ "$confirm" != [yY] ]]; then
    echo "Установка отменена."
    exit 1
fi

# --- 3. УСТАНОВКА ---

echo ""
echo "### 1. Обновление пакетов и установка зависимостей... ###"
apt update > /dev/null 2>&1
apt install -y nano cron curl python3 python3-requests > /dev/null 2>&1
echo "Зависимости установлены."
echo "----------------------------------------"

echo "### 2. Установка tblocker... ###"
if [ -d "/opt/tblocker" ]; then
    echo "Папка /opt/tblocker уже существует. Пропускаем скачивание."
else
    # Запускаем установщик tblocker
    bash <(curl -fsSL git.new/install)
    echo "tblocker установлен."
fi
echo "----------------------------------------"

echo "### 3. Создание файла конфигурации tblocker (config.yaml)... ###"
# Используем Heredoc для создания файла
cat << EOF > /opt/tblocker/config.yaml
LogFile: "/var/log/remnanode/access.log"
BlockDuration: ${BLOCK_DURATION}
TorrentTag: "TORRENT"
BlockMode: "nft"
SendWebhook: true
WebhookURL: "${ADMIN_WEBHOOK_URL}"
WebhookHeaders:
  Content-Type: "application/json"
WebhookTemplate: '{"chat_id": "${ADMIN_CHAT_ID}", "text": "🚨 Torrent activity detected!\n👤 Server: ${SERVER_NAME}  User: %s\n🌐 IP: %s\n⚙️ Action: %s\n⏱️ Banned: 12 hours"}'
EOF
echo "config.yaml создан."
echo "----------------------------------------"

echo "### 4. Создание Python-скрипта уведомлений... ###"
# Используем 'EOF' в кавычках, чтобы переменные внутри Python не раскрывались
cat << 'EOF' > /opt/tblocker/send_user_notifications.py
#!/usr/bin/env python3
# /opt/tblocker/send_user_notifications.py
import json
import time
from pathlib import Path
import requests
import logging

# Настройки
BLOCKED_FILE = "/opt/tblocker/blocked_ips.json"
NOTIFIED_LOG = "/opt/tblocker/notified_log.json"
USER_BOT_TOKEN = "!!!USER_TOKEN_PLACEHOLDER!!!"
LOG_RETENTION = 48 * 3600  # 48 часов в секундах

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s: %(message)s")

# --- Работа с JSON ---
def load_json(path):
    p = Path(path)
    if not p.exists():
        return {}
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception as e:
        logging.error("Ошибка чтения JSON %s: %s", path, e)
        return {}

def save_json(path, data):
    Path(path).write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")

# --- Telegram ---
def send_telegram(token, chat_id, text):
    url = f"https://api.telegram.org/bot{token}/sendMessage"
    payload = {"chat_id": str(chat_id), "text": text}
    try:
        r = requests.post(url, json=payload, timeout=10)
        r.raise_for_status()
        return r.json()
    except Exception as e:
        logging.exception("Ошибка отправки Telegram:")
        return {"ok": False, "error": str(e)}

# --- Основная логика ---
def main():
    blocked = load_json(BLOCKED_FILE)
    notified = load_json(NOTIFIED_LOG)
    modified = False
    now = int(time.time())

    # --- Очистка старых записей ---
    removed = [key for key, ts in notified.items() if now - ts > LOG_RETENTION]
    for key in removed:
        logging.info("Удаляем старую запись из лога уведомлений: %s", key)
        del notified[key]
        modified = True

    if not blocked:
        logging.info("Нет данных для обработки.")
        if modified:
            save_json(NOTIFIED_LOG, notified)
        return

    for ip, rec in blocked.items():
        chat_id = rec.get("username")
        if not chat_id:
            logging.warning("Нет chat_id для IP %s, пропускаем", ip)
            continue

        action = rec.get("action", "Blocked")

        # уникальный ключ для каждой блокировки: IP + action
        key = f"{ip}|{action}"

        if key in notified:
            logging.debug("Уведомление для IP %s уже отправлено", ip)
            continue

        text = (
            f"⚠️ Вы были заблокированы на сервере\n"
            f"IP: {ip}\n"
            f"Причина: Использование Torrent протокола\n"
            f"Время блокировки: 12 часов\n"
            f"Если вы считаете, что блокировка была произведена по ошибке,\n "
            f"обратитесь в поддержку - @torvpn_support\n"
        )

        resp = send_telegram(USER_BOT_TOKEN, chat_id, text)
        if resp.get("ok"):
            logging.info("Уведомление отправлено пользователю chat_id=%s о IP %s", chat_id, ip)
            notified[key] = now
            modified = True
        else:
            logging.error("Не удалось уведомить chat_id=%s: %s", chat_id, resp)

    if modified:
        save_json(NOTIFIED_LOG, notified)
        logging.info("Лог уведомлений обновлён")

if __name__ == "__main__":
    main()
EOF

# Теперь безопасно заменяем плейсхолдер на реальный токен
sed -i "s|!!!USER_TOKEN_PLACEHOLDER!!!|${USER_BOT_TOKEN}|g" /opt/tblocker/send_user_notifications.py

echo "Python-скрипт создан."
echo "----------------------------------------"

echo "### 5. Установка прав на выполнение скрипта... ###"
chmod +x /opt/tblocker/send_user_notifications.py
echo "Права установлены."
echo "----------------------------------------"

echo "### 6. Добавление задания в Cron... ###"
# Находим полный путь к python3
PYTHON_PATH=$(which python3)
if [ -z "$PYTHON_PATH" ]; then
    echo "Ошибка: не удалось найти python3. Установите его и попробуйте снова."
    exit 1
fi

CRON_JOB_COMMAND="${PYTHON_PATH} /opt/tblocker/send_user_notifications.py >> /var/log/tblocker_notify.log 2>&1"
CRON_JOB_ENTRY="${CRON_SCHEDULE} ${CRON_JOB_COMMAND}"

# Добавляем cron-задание, избегая дубликатов
(crontab -l 2>/dev/null | grep -v -F "${CRON_JOB_COMMAND}" || true) | { cat; echo "${CRON_JOB_ENTRY}"; } | crontab -

echo "Cron-задание успешно добавлено/обновлено:"
crontab -l | grep tblocker_notify
echo "----------------------------------------"

echo "### 7. Перезапуск tblocker и проверка статуса... ###"
echo "Перезапускаем tblocker, чтобы применить config.yaml..."
systemctl restart tblocker

echo "Пауза 3 секунды, чтобы сервис успел запуститься..."
sleep 3

echo "Вывод статуса tblocker:"
# --no-pager - выводит статус прямо в консоль, не открывая 'less'
# -l - показывает полный вывод, не обрезая строки
systemctl status tblocker --no-pager -l
echo "----------------------------------------"


echo "========================================"
echo "✅ Установка и настройка завершены!"
echo "========================================"