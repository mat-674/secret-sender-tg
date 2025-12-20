import asyncio
import logging
import sqlite3
import os
from dotenv import load_dotenv # Импортируем загрузчик
from aiogram import Bot, Dispatcher, F
from aiogram.types import Message, CallbackQuery, InlineKeyboardMarkup, InlineKeyboardButton
from aiogram.filters import CommandStart

# --- ЗАГРУЗКА КОНФИГУРАЦИИ ---
load_dotenv() # Читаем файл .env

TOKEN = os.getenv("BOT_TOKEN")
CHANNEL_ID = int(os.getenv("CHANNEL_ID")) # Превращаем строку в число

# Хитрый способ получить список чисел из строки "123,456,789"
admin_ids_str = os.getenv("ADMIN_IDS", "")
ADMIN_IDS = [int(x) for x in admin_ids_str.split(",") if x.strip()]

# Проверка, что данные загрузились
if not TOKEN or not ADMIN_IDS:
    print("ОШИБКА: Не заполнен файл .env")
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
