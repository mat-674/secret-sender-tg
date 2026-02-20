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
CHANNEL_ID = int(os.getenv("CHANNEL_ID")) # Превращаем строку в число

# Хитрый способ получить список чисел из строки "123,456,789"
admin_ids_str = os.getenv("ADMIN_IDS", "")
ADMIN_IDS = [int(x) for x in admin_ids_str.split(",") if x.strip()]

# Проверка, что данные загрузились
if not TOKEN or not ADMIN_IDS:
    print("ERROR: .env file is missing variables")
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
        [InlineKeyboardButton(text="🥷 Send anonymously", callback_data=f"send_anon_{msg_id}")],
        [InlineKeyboardButton(text="👁 Show my name", callback_data=f"send_name_{msg_id}")],
        [InlineKeyboardButton(text="❌ Cancel", callback_data=f"send_cancel_{msg_id}")]
    ]
    return InlineKeyboardMarkup(inline_keyboard=buttons)

def get_admin_keyboard(ticket_id, is_named=False):
    btn_text = "✅ Publish (Named)" if is_named else "✅ Publish (Anon)"
    buttons = [
        [
            InlineKeyboardButton(text=btn_text, callback_data=f"approve_{ticket_id}"),
            InlineKeyboardButton(text="❌ Reject", callback_data=f"reject_{ticket_id}")
        ]
    ]
    return InlineKeyboardMarkup(inline_keyboard=buttons)

def get_settings_keyboard():
    buttons = [
        [InlineKeyboardButton(text="User greeting", callback_data="settings_edit_text_start_user")],
        [InlineKeyboardButton(text="Admin greeting", callback_data="settings_edit_text_start_admin")],
        [InlineKeyboardButton(text="Sent for moderation text", callback_data="settings_edit_text_sent_to_mod")],
        [InlineKeyboardButton(text="Post signature (tilde)", callback_data="settings_edit_post_signature")],
        [InlineKeyboardButton(text="Text: Published (reply)", callback_data="settings_edit_text_published_reply")],
        [InlineKeyboardButton(text="Text: Rejected (reply)", callback_data="settings_edit_text_rejected_reply")],
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
            logging.error(f"Failed to update message for admin {admin_id}: {e}")

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
    await message.answer("Text and signature settings panel:", reply_markup=get_settings_keyboard())

@dp.callback_query(F.data.startswith("settings_edit_"))
async def process_settings_edit(callback: CallbackQuery, state: FSMContext):
    if callback.from_user.id not in ADMIN_IDS:
        return
    
    key = callback.data.replace("settings_edit_", "")
    current_text = get_setting(key)
    
    await state.update_data(setting_key=key)
    await state.set_state(SettingsState.waiting_for_text)
    
    await callback.message.answer(f"Current value:\n<pre>{current_text}</pre>\n\nSend new text for this setting (or send /cancel to abort):", parse_mode="HTML")
    await callback.answer()

@dp.message(Command("cancel"))
async def cmd_cancel(message: Message, state: FSMContext):
    current_state = await state.get_state()
    if current_state is None:
        return
    await state.clear()
    await message.answer("Editing cancelled.")

@dp.message(SettingsState.waiting_for_text)
async def process_new_setting_text(message: Message, state: FSMContext):
    data = await state.get_data()
    key = data.get("setting_key")
    
    new_text = message.text if message.text else message.caption
    if not new_text:
        await message.answer("Please send the text.")
        return
        
    set_setting(key, new_text)
    await state.clear()
    await message.answer(f"Setting updated successfully!\nNew value:\n<pre>{new_text}</pre>", parse_mode="HTML", reply_markup=get_settings_keyboard())

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
            await callback.answer(f"Publication error: {e}", show_alert=True)

    elif action == "reject":
        await callback.answer(get_setting("text_rejected_alert"))
        await close_ticket(ticket_id, get_setting("text_rejected_log"))
        await callback.message.reply(get_setting("text_rejected_reply"))

@dp.message()
async def handle_content(message: Message):
    if message.from_user.id in ADMIN_IDS:
        return

    await message.reply(
        "How to send this post?", 
        reply_markup=get_user_choice_keyboard(message.message_id)
    )

@dp.callback_query(F.data.startswith(("send_anon_", "send_name_", "send_cancel_")))
async def process_user_send_choice(callback: CallbackQuery):
    action, msg_id = callback.data.split("_", 2)[1:]
    msg_id = int(msg_id)
    
    if action == "cancel":
        await callback.message.delete()
        await callback.answer("Cancelled")
        return
        
    await callback.message.delete()
    
    user_id = callback.from_user.id
    custom_signature = None
    is_named = False
    
    if action == "name":
        is_named = True
        import html
        first_name = html.escape(callback.from_user.first_name)
        custom_signature = f'\n\n<i>~ From: {first_name}</i>'
        
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
                logging.error(f"Error sending to admin {admin_id}: {e}")
        conn.commit()

    if successful_sends > 0:
        await callback.message.answer(get_setting("text_sent_to_mod"))
    else:
        await callback.message.answer(get_setting("text_mod_error"))

async def main():
    init_db()
    print("Bot started...")
    await bot.delete_webhook(drop_pending_updates=True)
    await dp.start_polling(bot)

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:

        print("Bot stopped")
