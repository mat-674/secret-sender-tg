#!/bin/bash

# Colors for nice output
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}>>> Starting Secret Sender Bot installer...${NC}"

# 1. Check root privileges
if [ "$EUID" -ne 0 ]; then
  echo "Please run the script with root privileges (or via sudo)"
  exit
fi

# 2. Install Docker (if missing)
if ! command -v docker &> /dev/null; then
    echo "Docker not found, installing..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    rm get-docker.sh
else
    echo "Docker is already installed."
fi

# 3. Create project context
WORKDIR="/opt/secret-bot"
mkdir -p "$WORKDIR"
cd "$WORKDIR"
echo -e "${GREEN}>>> Working directory: $WORKDIR${NC}"

# 4. Create bot.py (embed the bot code directly here)
echo "Creating bot.py file..."
cat << 'EOF' > bot.py
import asyncio
import logging
import sqlite3
import os
from dotenv import load_dotenv # Импортируем загрузчик
from aiogram import Bot, Dispatcher, F
from aiogram.types import Message, CallbackQuery, InlineKeyboardMarkup, InlineKeyboardButton
from aiogram.filters import CommandStart, Command
from aiogram.fsm.state import State, StatesGroup
from aiogram.fsm.context import FSMContext

# --- ЗАГРУЗКА КОНФИГУРАЦИИ ---
load_dotenv() # Читаем файл .env

TOKEN = os.getenv("BOT_TOKEN")
CHANNEL_ID = int(os.getenv("CHANNEL_ID") or 0) # Превращаем строку в число

# Хитрый способ получить список чисел из строки "123,456,789"
admin_ids_str = os.getenv("ADMIN_IDS", "")
ADMIN_IDS = [int(x) for x in admin_ids_str.split(",") if x.strip()]

LANGUAGE = os.getenv("LANGUAGE", "ru").lower()
if LANGUAGE not in ["ru", "en"]:
    LANGUAGE = "ru"

# --- ЛОКАЛИЗАЦИЯ (LOCALES) ---
LOCALES = {
    "ru": {
        "text_start_admin": "Привет, Админ! ID канала: {CHANNEL_ID}",
        "text_start_user": "Присылай контент, я передам админам анонимно.",
        "text_sent_to_mod": "Отправлено на модерацию.",
        "text_mod_error": "Ошибка связи с админами.",
        "text_already_processed": "Этот пост уже обработан!",
        "text_published_alert": "Опубликовано!",
        "text_published_log": "✅ Опубликовано",
        "text_published_reply": "✅ Ты одобрил этот пост.",
        "text_rejected_alert": "Отклонено",
        "text_rejected_log": "❌ Отклонено",
        "text_rejected_reply": "❌ Ты отклонил этот пост.",
        "post_signature": "\n\n<i>~ Анонимно</i>",
        "btn_user_anon": "🥷 Отправить анонимно",
        "btn_user_name": "👁 Показать мое имя",
        "btn_cancel": "❌ Отмена",
        "btn_admin_pub_named": "✅ Опубликовать (С именем)",
        "btn_admin_pub_anon": "✅ Опубликовать (Анон)",
        "btn_admin_reject": "❌ Отклонить",
        "btn_set_start_user": "Приветствие юзера",
        "btn_set_start_admin": "Приветствие админа",
        "btn_set_sent_mod": "Отправлено на модерацию",
        "btn_set_signature": "Подпись к посту (тильда)",
        "btn_set_pub_reply": "Текст: Опубликовано (ответ)",
        "btn_set_rej_reply": "Текст: Отклонено (ответ)",
        "msg_settings_panel": "Панель настроек текстов и подписи:",
        "msg_current_val": "Текущее значение:\n<pre>{current_text}</pre>\n\nОтправьте новый текст для этой настройки (или отправьте /cancel для отмены):",
        "msg_edit_cancel": "Редактирование отменено.",
        "msg_send_text": "Пожалуйста, отправьте текст.",
        "msg_set_updated": "Настройка успешно обновлена!\nНовое значение:\n<pre>{new_text}</pre>",
        "msg_pub_err": "Ошибка публикации:",
        "msg_how_to_send": "Как отправить этот пост?",
        "msg_user_cancel": "Отменено",
        "msg_sig_from": "\n\n<i>~ От: {first_name}</i>",
        "log_admin_err": "Ошибка отправки админу {admin_id}:",
        "log_bot_start": "Бот запущен...",
        "log_bot_stop": "Бот остановлен",
        "err_env": "ОШИБКА: Не заполнен файл .env"
    },
    "en": {
        "text_start_admin": "Hello, Admin! Channel ID: {CHANNEL_ID}",
        "text_start_user": "Send content, I'll forward it to admins anonymously.",
        "text_sent_to_mod": "Sent for moderation.",
        "text_mod_error": "Error communicating with admins.",
        "text_already_processed": "This post has already been processed!",
        "text_published_alert": "Published!",
        "text_published_log": "✅ Published",
        "text_published_reply": "✅ You approved this post.",
        "text_rejected_alert": "Rejected",
        "text_rejected_log": "❌ Rejected",
        "text_rejected_reply": "❌ You rejected this post.",
        "post_signature": "\n\n<i>~ Anonymously</i>",
        "btn_user_anon": "🥷 Send anonymously",
        "btn_user_name": "👁 Show my name",
        "btn_cancel": "❌ Cancel",
        "btn_admin_pub_named": "✅ Publish (Named)",
        "btn_admin_pub_anon": "✅ Publish (Anon)",
        "btn_admin_reject": "❌ Reject",
        "btn_set_start_user": "User greeting",
        "btn_set_start_admin": "Admin greeting",
        "btn_set_sent_mod": "Sent for moderation text",
        "btn_set_signature": "Post signature (tilde)",
        "btn_set_pub_reply": "Text: Published (reply)",
        "btn_set_rej_reply": "Text: Rejected (reply)",
        "msg_settings_panel": "Text and signature settings panel:",
        "msg_current_val": "Current value:\n<pre>{current_text}</pre>\n\nSend new text for this setting (or send /cancel to abort):",
        "msg_edit_cancel": "Editing cancelled.",
        "msg_send_text": "Please send the text.",
        "msg_set_updated": "Setting updated successfully!\nNew value:\n<pre>{new_text}</pre>",
        "msg_pub_err": "Publication error:",
        "msg_how_to_send": "How to send this post?",
        "msg_user_cancel": "Cancelled",
        "msg_sig_from": "\n\n<i>~ From: {first_name}</i>",
        "log_admin_err": "Error sending to admin {admin_id}:",
        "log_bot_start": "Bot started...",
        "log_bot_stop": "Bot stopped",
        "err_env": "ERROR: .env file is missing variables"
    }
}
_ = LOCALES[LANGUAGE]

# Проверка, что данные загрузились
if not TOKEN or not ADMIN_IDS:
    print(_["err_env"])
    exit()

logging.basicConfig(level=logging.INFO)
bot = Bot(token=TOKEN)
dp = Dispatcher()

# --- РАБОТА С БАЗОЙ ДАННЫХ ---
def init_db():
    with sqlite3.connect("bot_database.db") as conn:
        cursor = conn.cursor()
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS tickets (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id INTEGER,
                status TEXT DEFAULT 'pending' 
            )
        """)
        
        # Пытаемся добавить колонку для подписи (если её еще нет)
        try:
            cursor.execute("ALTER TABLE tickets ADD COLUMN custom_signature TEXT")
        except sqlite3.OperationalError:
            pass
            
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS admin_messages (
                ticket_id INTEGER,
                admin_id INTEGER,
                message_id INTEGER,
                FOREIGN KEY(ticket_id) REFERENCES tickets(id)
            )
        """)
        
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY,
                value TEXT
            )
        """)
        
        # Заполняем дефолтные настройки
        default_settings = {
            "text_start_admin": _["text_start_admin"],
            "text_start_user": _["text_start_user"],
            "text_sent_to_mod": _["text_sent_to_mod"],
            "text_mod_error": _["text_mod_error"],
            "text_already_processed": _["text_already_processed"],
            "text_published_alert": _["text_published_alert"],
            "text_published_log": _["text_published_log"],
            "text_published_reply": _["text_published_reply"],
            "text_rejected_alert": _["text_rejected_alert"],
            "text_rejected_log": _["text_rejected_log"],
            "text_rejected_reply": _["text_rejected_reply"],
            "post_signature": _["post_signature"],
        }
        
        for key, value in default_settings.items():
            cursor.execute("INSERT OR IGNORE INTO settings (key, value) VALUES (?, ?)", (key, value))
            
        conn.commit()

# --- НАСТРОЙКИ ---
def get_setting(key: str) -> str:
    with sqlite3.connect("bot_database.db") as conn:
        cursor = conn.cursor()
        cursor.execute("SELECT value FROM settings WHERE key = ?", (key,))
        result = cursor.fetchone()
        return result[0] if result else ""

def set_setting(key: str, value: str):
    with sqlite3.connect("bot_database.db") as conn:
        cursor = conn.cursor()
        cursor.execute("UPDATE settings SET value = ? WHERE key = ?", (value, key))
        conn.commit()

# --- FSM СОСТОЯНИЯ ---
class SettingsState(StatesGroup):
    waiting_for_text = State()

# --- КЛАВИАТУРА ---
def get_user_choice_keyboard(msg_id):
    buttons = [
        [InlineKeyboardButton(text=_["btn_user_anon"], callback_data=f"send_anon_{msg_id}")],
        [InlineKeyboardButton(text=_["btn_user_name"], callback_data=f"send_name_{msg_id}")],
        [InlineKeyboardButton(text=_["btn_cancel"], callback_data=f"send_cancel_{msg_id}")]
    ]
    return InlineKeyboardMarkup(inline_keyboard=buttons)

def get_admin_keyboard(ticket_id, is_named=False):
    btn_text = _["btn_admin_pub_named"] if is_named else _["btn_admin_pub_anon"]
    buttons = [
        [
            InlineKeyboardButton(text=btn_text, callback_data=f"approve_{ticket_id}"),
            InlineKeyboardButton(text=_["btn_admin_reject"], callback_data=f"reject_{ticket_id}")
        ]
    ]
    return InlineKeyboardMarkup(inline_keyboard=buttons)

def get_settings_keyboard():
    buttons = [
        [InlineKeyboardButton(text=_["btn_set_start_user"], callback_data="settings_edit_text_start_user")],
        [InlineKeyboardButton(text=_["btn_set_start_admin"], callback_data="settings_edit_text_start_admin")],
        [InlineKeyboardButton(text=_["btn_set_sent_mod"], callback_data="settings_edit_text_sent_to_mod")],
        [InlineKeyboardButton(text=_["btn_set_signature"], callback_data="settings_edit_post_signature")],
        [InlineKeyboardButton(text=_["btn_set_pub_reply"], callback_data="settings_edit_text_published_reply")],
        [InlineKeyboardButton(text=_["btn_set_rej_reply"], callback_data="settings_edit_text_rejected_reply")],
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
            logging.error(f"{_['log_admin_err']} {e}")

# --- ОБРАБОТЧИКИ ---

@dp.message(CommandStart())
async def cmd_start(message: Message):
    if message.from_user.id in ADMIN_IDS:
        text = get_setting("text_start_admin").replace("{CHANNEL_ID}", str(CHANNEL_ID))
        await message.answer(text)
    else:
        await message.answer(get_setting("text_start_user"))

@dp.message(Command("settings"))
async def cmd_settings(message: Message):
    if message.from_user.id not in ADMIN_IDS:
        return
    await message.answer(_["msg_settings_panel"], reply_markup=get_settings_keyboard())

@dp.callback_query(F.data.startswith("settings_edit_"))
async def process_settings_edit(callback: CallbackQuery, state: FSMContext):
    if callback.from_user.id not in ADMIN_IDS:
        return
    
    key = callback.data.replace("settings_edit_", "")
    current_text = get_setting(key)
    
    await state.update_data(setting_key=key)
    await state.set_state(SettingsState.waiting_for_text)
    
    msg_text = _["msg_current_val"].replace("{current_text}", current_text)
    await callback.message.answer(msg_text, parse_mode="HTML")
    await callback.answer()

@dp.message(Command("cancel"))
async def cmd_cancel(message: Message, state: FSMContext):
    current_state = await state.get_state()
    if current_state is None:
        return
    await state.clear()
    await message.answer(_["msg_edit_cancel"])

@dp.message(SettingsState.waiting_for_text)
async def process_new_setting_text(message: Message, state: FSMContext):
    data = await state.get_data()
    key = data.get("setting_key")
    
    new_text = message.text if message.text else message.caption
    if not new_text:
        await message.answer(_["msg_send_text"])
        return
        
    set_setting(key, new_text)
    await state.clear()
    msg_text = _["msg_set_updated"].replace("{new_text}", new_text)
    await message.answer(msg_text, parse_mode="HTML", reply_markup=get_settings_keyboard())

@dp.callback_query(F.data.startswith(("approve_", "reject_")))
async def process_decision(callback: CallbackQuery):
    action, ticket_id = callback.data.split("_")
    ticket_id = int(ticket_id)

    with sqlite3.connect("bot_database.db") as conn:
        cursor = conn.cursor()
        cursor.execute("SELECT status, custom_signature FROM tickets WHERE id = ?", (ticket_id,))
        result = cursor.fetchone()

    if not result or result[0] != 'pending':
        await callback.answer(get_setting("text_already_processed"), show_alert=True)
        await callback.message.edit_reply_markup(reply_markup=None)
        return

    custom_sig = result[1]

    if action == "approve":
        try:
            signature = custom_sig if custom_sig else get_setting("post_signature")
            
            if callback.message.text:
                new_text = callback.message.text + signature
                await bot.send_message(chat_id=CHANNEL_ID, text=new_text, parse_mode="HTML")
            elif callback.message.caption is not None:
                new_caption = callback.message.caption + signature
                await callback.message.copy_to(chat_id=CHANNEL_ID, caption=new_caption, parse_mode="HTML")
            else:
                await callback.message.copy_to(chat_id=CHANNEL_ID, caption=signature, parse_mode="HTML")

            await callback.answer(get_setting("text_published_alert"))
            await close_ticket(ticket_id, get_setting("text_published_log"))
            await callback.message.reply(get_setting("text_published_reply"))
        except Exception as e:
            await callback.answer(f"{_['msg_pub_err']} {e}", show_alert=True)

    elif action == "reject":
        await callback.answer(get_setting("text_rejected_alert"))
        await close_ticket(ticket_id, get_setting("text_rejected_log"))
        await callback.message.reply(get_setting("text_rejected_reply"))

@dp.message()
async def handle_content(message: Message):
    if message.from_user.id in ADMIN_IDS:
        return

    await message.reply(
        _["msg_how_to_send"], 
        reply_markup=get_user_choice_keyboard(message.message_id)
    )

@dp.callback_query(F.data.startswith(("send_anon_", "send_name_", "send_cancel_")))
async def process_user_send_choice(callback: CallbackQuery):
    action, msg_id = callback.data.split("_", 2)[1:]
    msg_id = int(msg_id)
    
    if action == "cancel":
        await callback.message.delete()
        await callback.answer(_["msg_user_cancel"])
        return
        
    await callback.message.delete()
    
    user_id = callback.from_user.id
    custom_signature = None
    is_named = False
    
    if action == "name":
        is_named = True
        import html
        first_name = html.escape(callback.from_user.first_name)
        custom_signature = _["msg_sig_from"].replace("{first_name}", first_name)
        
    with sqlite3.connect("bot_database.db") as conn:
        cursor = conn.cursor()
        cursor.execute("INSERT INTO tickets (user_id, custom_signature) VALUES (?, ?)", (user_id, custom_signature))
        ticket_id = cursor.lastrowid
        conn.commit()

    successful_sends = 0
    with sqlite3.connect("bot_database.db") as conn:
        cursor = conn.cursor()
        for admin_id in ADMIN_IDS:
            try:
                sent_msg = await bot.copy_message(
                    chat_id=admin_id,
                    from_chat_id=callback.message.chat.id,
                    message_id=msg_id,
                    reply_markup=get_admin_keyboard(ticket_id, is_named)
                )
                cursor.execute("INSERT INTO admin_messages (ticket_id, admin_id, message_id) VALUES (?, ?, ?)",
                               (ticket_id, admin_id, sent_msg.message_id))
                successful_sends += 1
            except Exception as e:
                logging.error(f"{_['log_admin_err']} {e}")
        conn.commit()

    if successful_sends > 0:
        await callback.message.answer(get_setting("text_sent_to_mod"))
    else:
        await callback.message.answer(get_setting("text_mod_error"))

async def main():
    init_db()
    print(_["log_bot_start"])
    await bot.delete_webhook(drop_pending_updates=True)
    await dp.start_polling(bot)

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:

        print(_["log_bot_stop"])
EOF

# 5. Interactive settings input
echo -e "${GREEN}>>> Bot Configuration${NC}"
read -p "Enter BOT_TOKEN (from BotFather): " INPUT_TOKEN
read -p "Enter CHANNEL_ID (where to post, e.g. -100...): " INPUT_CHANNEL
read -p "Enter ADMIN_IDS (comma-separated): " INPUT_ADMINS
read -p "Choose language / Выберите язык [ru/en]: " INPUT_LANG

# Define fallback for lang
if [ -z "$INPUT_LANG" ]; then
    INPUT_LANG="ru"
fi

# Save .env
cat << EOF > .env
BOT_TOKEN=$INPUT_TOKEN
CHANNEL_ID=$INPUT_CHANNEL
ADMIN_IDS=$INPUT_ADMINS
LANGUAGE=$INPUT_LANG
EOF

# 6. Create Dockerfile
echo "Creating Dockerfile..."
cat << EOF > Dockerfile
FROM python:3.9-slim
WORKDIR /app
# Install dependencies in one layer
RUN pip install --no-cache-dir aiogram python-dotenv
# Copy code and config
COPY bot.py .
COPY .env .
# Run
CMD ["python", "bot.py"]
EOF

# 7. Create docker-compose.yml
# Database is kept inside the container, no volumes.
echo "Creating docker-compose.yml..."
cat << EOF > docker-compose.yml
version: '3.8'
services:
  bot:
    build: .
    restart: always
    container_name: secret_bot
EOF

# 8. Run
echo -e "${GREEN}>>> Building and starting...${NC}"
docker compose up -d --build

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Done! Bot is running.${NC}"
    echo "View logs: docker logs -f secret_bot"
else
    echo "❌ Error during startup."
fi
