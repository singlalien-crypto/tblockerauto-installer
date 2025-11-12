#!/bin/bash
set -e

# === Цветной вывод ===
green="\e[32m"; yellow="\e[33m"; red="\e[31m"; reset="\e[0m"
log() { echo -e "${green}[INFO]${reset} $1"; }
warn() { echo -e "${yellow}[WARN]${reset} $1"; }
err() { echo -e "${red}[ERROR]${reset} $1" >&2; }

# === Проверка прав ===
if [ "$EUID" -ne 0 ]; then
  err "Запусти через sudo!"
  exit 1
fi

echo -e "\n=== 🧠 Установка TBlocker ===\n"

# === Обновление системы и установка пакетов ===
log "Обновление пакетов и установка зависимостей..."
apt update -y
apt install -y python3 python3-pip python3-requests git nano cron curl

# === Установка TBlocker ===
log "Установка TBlocker..."
bash <(curl -fsSL git.new/install)

# === Ввод параметров ===
echo ""
read -p "⏱️  Введите длительность блокировки (в минутах, напр. 720): " BLOCK_DURATION
read -p "📡 Нужно ли настраивать вебхук? (y/n): " ENABLE_WEBHOOK

if [[ "$ENABLE_WEBHOOK" =~ ^[Yy]$ ]]; then
  read -p "Введите Telegram API URL (например, https://api.telegram.org/...): " WEBHOOK_URL
  read -p "Введите chat_id для уведомлений: " CHAT_ID
  read -p "Введите название сервера (например, France 1): " SERVER_NAME
  WEBHOOK_CONFIG=$(cat <<EOF
SendWebhook: true
WebhookURL: "$WEBHOOK_URL"
WebhookHeaders:
  Content-Type: "application/json"
WebhookTemplate: '{"chat_id": "$CHAT_ID", "text": "🚨 Torrent activity detected!\n👤 Server: $SERVER_NAME  User: %s\n🌐 IP: %s\n⚙️ Action: %s\n⏱️ Banned: 12 hours"}'
EOF
)
else
  WEBHOOK_CONFIG="SendWebhook: false"
fi

# === Создание config.yaml ===
log "Создание /opt/tblocker/config.yaml ..."
mkdir -p /opt/tblocker
cat <<EOF >/opt/tblocker/config.yaml
LogFile: "/var/log/remnanode/access.log"
BlockDuration: $BLOCK_DURATION
TorrentTag: "TORRENT"
BlockMode: "nft"
$WEBHOOK_CONFIG
EOF

# === Создание скрипта уведомлений ===
log "Создание /opt/tblocker/send_user_notifications.py ..."
cat <<'PY' >/opt/tblocker/send_user_notifications.py
#!/usr/bin/env python3
import json
import time
from pathlib import Path
import requests
import logging

BLOCKED_FILE = "/opt/tblocker/blocked_ips.json"
NOTIFIED_LOG = "/opt/tblocker/notified_log.json"
USER_BOT_TOKEN = "7658715300:AAHgLpQCoHg6yGgTQXnGW6iiL0PTfiUHDZo"
LOG_RETENTION = 48 * 3600  # 48 часов

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s: %(message)s")

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

def main():
    blocked = load_json(BLOCKED_FILE)
    notified = load_json(NOTIFIED_LOG)
    modified = False
    now = int(time.time())

    removed = [key for key, ts in notified.items() if now - ts > LOG_RETENTION]
    for key in removed:
        logging.info("Удаляем старую запись: %s", key)
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
            logging.warning("Нет chat_id для IP %s", ip)
            continue

        action = rec.get("action", "Blocked")
        key = f"{ip}|{action}"
        if key in notified:
            continue

        text = (
            f"⚠️ Вы были заблокированы на сервере\n"
            f"IP: {ip}\n"
            f"Причина: Torrent\n"
            f"Время блокировки: 12 часов\n"
            f"Поддержка: @torvpn_support\n"
        )

        resp = send_telegram(USER_BOT_TOKEN, chat_id, text)
        if resp.get("ok"):
            logging.info("Уведомление отправлено chat_id=%s о IP %s", chat_id, ip)
            notified[key] = now
            modified = True
        else:
            logging.error("Не удалось уведомить %s: %s", chat_id, resp)

    if modified:
        save_json(NOTIFIED_LOG, notified)
        logging.info("Лог уведомлений обновлён")

if __name__ == "__main__":
    main()
PY

chmod +x /opt/tblocker/send_user_notifications.py

# === Настройка cron ===
read -p "Введите интервал проверки уведомлений (в минутах, например 20): " CRON_INTERVAL
CRON_INTERVAL=${CRON_INTERVAL:-20}

log "Добавление задачи в cron..."
(crontab -l 2>/dev/null; echo "*/$CRON_INTERVAL * * * * /usr/bin/python3 /opt/tblocker/send_user_notifications.py >> /var/log/tblocker_notify.log 2>&1") | crontab -

log "✅ Установка завершена!"
echo "Конфиг: /opt/tblocker/config.yaml"
echo "Cron: каждые $CRON_INTERVAL минут"
echo "Для просмотра логов: tail -f /var/log/tblocker_notify.log"
