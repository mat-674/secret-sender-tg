#!/bin/bash

# Цвета для красоты
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}>>> Запуск установщика Secret Sender Bot...${NC}"

# 1. Проверка root прав
if [ "$EUID" -ne 0 ]; then
  echo "Пожалуйста, запустите скрипт с правами root (или через sudo)"
  exit
fi

# 2. Установка Docker (если нет)
if ! command -v docker &> /dev/null; then
    echo "Docker не найден, устанавливаем..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    rm get-docker.sh
else
    echo "Docker уже установлен."
fi

# 3. Создание папки проекта
WORKDIR="/opt/secret-bot"
mkdir -p "$WORKDIR"
cd "$WORKDIR"
echo -e "${GREEN}>>> Рабочая папка: $WORKDIR${NC}"

# 4. Создаем bot.py (код бота вшиваем прямо сюда)
echo "Создаем файл bot.py..."
cat << 'EOF' > bot.py
import asyncio
import logging
import sqlite3
import os
from dotenv import load_dotenv
from aiogram import Bot, Dispatcher, F
from aiogram.types import Message, CallbackQuery, InlineKeyboardMarkup, InlineKeyboardButton
from aiogram.filters import CommandStart

# --- ЗАГРУЗКА КОНФИГУРАЦИИ ---
load_dotenv()

TOKEN = os.getenv("BOT_TOKEN")
try:
    chan_id_raw = os.getenv("CHANNEL_ID")
    CHANNEL_ID = int(chan_id_raw) if chan_id_raw else 0
except ValueError:
    print("Error: CHANNEL_ID must be an integer")
    exit(1)

admin_ids_str = os.getenv("ADMIN_IDS", "")
ADMIN_IDS = [int(x) for x in admin_ids_str.split(",") if x.strip()]

if not TOKEN or not ADMIN_IDS:
    print("ОШИБКА: Не заполнен файл .env или переменные окружения")
    exit()

logging.basicConfig(level=logging.INFO)
bot = Bot(token=TOKEN)
dp = Dispatcher()

# --- РАБОТА С БАЗОЙ ДАННЫХ ---
def init_db():
    # База создается в корне контейнера, как и просили - просто файл
    with sqlite3.connect("bot_database.db") as conn:
        cursor = conn.cursor()
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS tickets (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id INTEGER,
                status TEXT DEFAULT 'pending' 
            )
        """)
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS admin_messages (
                ticket_id INTEGER,
                admin_id INTEGER,
                message_id INTEGER,
                FOREIGN KEY(ticket_id) REFERENCES tickets(id)
            )
        """)
        conn.commit()

# --- КЛАВИАТУРА ---
def get_admin_keyboard(ticket_id):
    buttons = [
        [
            InlineKeyboardButton(text="✅ Опубликовать", callback_data=f"approve_{ticket_id}"),
            InlineKeyboardButton(text="❌ Отклонить", callback_data=f"reject_{ticket_id}")
        ]
    ]
    return InlineKeyboardMarkup(inline_keyboard=buttons)

# --- ЛОГИКА ОБНОВЛЕНИЯ СООБЩЕНИЙ ---
async def close_ticket(ticket_id, decision_text):
    with sqlite3.connect("bot_database.db") as conn:
        cursor = conn.cursor()
        cursor.execute("UPDATE tickets SET status = 'closed' WHERE id = ?", (ticket_id,))
        cursor.execute("SELECT admin_id, message_id FROM admin_messages WHERE ticket_id = ?", (ticket_id,))
        messages_to_edit = cursor.fetchall()
        conn.commit()

    for admin_id, msg_id in messages_to_edit:
        try:
            await bot.edit_message_reply_markup(chat_id=admin_id, message_id=msg_id, reply_markup=None)
        except Exception as e:
            logging.error(f"Не удалось обновить сообщение у админа {admin_id}: {e}")

# --- ОБРАБОТЧИКИ ---

@dp.message(CommandStart())
async def cmd_start(message: Message):
    if message.from_user.id in ADMIN_IDS:
        await message.answer(f"Привет, Админ! ID канала: {CHANNEL_ID}")
    else:
        await message.answer("Присылай контент, я передам админам анонимно.")

@dp.callback_query(F.data.startswith(("approve_", "reject_")))
async def process_decision(callback: CallbackQuery):
    action, ticket_id = callback.data.split("_")
    ticket_id = int(ticket_id)

    with sqlite3.connect("bot_database.db") as conn:
        cursor = conn.cursor()
        cursor.execute("SELECT status FROM tickets WHERE id = ?", (ticket_id,))
        result = cursor.fetchone()

    if not result or result[0] != 'pending':
        await callback.answer("Этот пост уже обработан!", show_alert=True)
        await callback.message.edit_reply_markup(reply_markup=None)
        return

    if action == "approve":
        try:
            await callback.message.forward(chat_id=CHANNEL_ID)
            await callback.answer("Опубликовано!")
            await close_ticket(ticket_id, "✅ Опубликовано")
            await callback.message.reply("✅ Ты одобрил этот пост.")
        except Exception as e:
            await callback.answer(f"Ошибка публикации: {e}", show_alert=True)

    elif action == "reject":
        await callback.answer("Отклонено")
        await close_ticket(ticket_id, "❌ Отклонено")
        await callback.message.reply("❌ Ты отклонил этот пост.")

@dp.message()
async def handle_content(message: Message):
    if message.from_user.id in ADMIN_IDS:
        return

    with sqlite3.connect("bot_database.db") as conn:
        cursor = conn.cursor()
        cursor.execute("INSERT INTO tickets (user_id) VALUES (?)", (message.from_user.id,))
        ticket_id = cursor.lastrowid
        conn.commit()

    successful_sends = 0
    with sqlite3.connect("bot_database.db") as conn:
        cursor = conn.cursor()
        for admin_id in ADMIN_IDS:
            try:
                sent_msg = await message.copy_to(
                    chat_id=admin_id,
                    reply_markup=get_admin_keyboard(ticket_id),
                    caption=message.caption or message.text
                )
                cursor.execute("INSERT INTO admin_messages (ticket_id, admin_id, message_id) VALUES (?, ?, ?)",
                               (ticket_id, admin_id, sent_msg.message_id))
                successful_sends += 1
            except Exception as e:
                logging.error(f"Ошибка отправки админу {admin_id}: {e}")
        conn.commit()

    if successful_sends > 0:
        await message.answer("Отправлено на модерацию.")
    else:
        await message.answer("Ошибка связи с админами.")

async def main():
    init_db()
    print("Бот запущен...")
    await bot.delete_webhook(drop_pending_updates=True)
    await dp.start_polling(bot)

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("Бот остановлен")
EOF

# 5. Интерактивный ввод настроек
echo -e "${GREEN}>>> Настройка бота${NC}"
read -p "Введи BOT_TOKEN (от BotFather): " INPUT_TOKEN
read -p "Введи CHANNEL_ID (куда постить, например -100...): " INPUT_CHANNEL
read -p "Введи ADMIN_IDS (через запятую): " INPUT_ADMINS

# Сохраняем .env
cat << EOF > .env
BOT_TOKEN=$INPUT_TOKEN
CHANNEL_ID=$INPUT_CHANNEL
ADMIN_IDS=$INPUT_ADMINS
EOF

# 6. Создаем Dockerfile
echo "Создаем Dockerfile..."
cat << EOF > Dockerfile
FROM python:3.9-slim
WORKDIR /app
# Устанавливаем зависимости одной командой
RUN pip install --no-cache-dir aiogram python-dotenv
# Копируем код и конфиг
COPY bot.py .
COPY .env .
# Запускаем
CMD ["python", "bot.py"]
EOF

# 7. Создаем docker-compose.yml
# Раз база не важна, volumes не прописываем - всё хранится внутри контейнера.
echo "Создаем docker-compose.yml..."
cat << EOF > docker-compose.yml
version: '3.8'
services:
  bot:
    build: .
    restart: always
    container_name: secret_bot
EOF

# 8. Запуск
echo -e "${GREEN}>>> Сборка и запуск...${NC}"
docker compose up -d --build

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Готово! Бот работает.${NC}"
    echo "Посмотреть логи: docker logs -f secret_bot"
else
    echo "❌ Ошибка при запуске."
fi
