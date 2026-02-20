# Secret Sender Bot (Telegram) 🤖

[🇷🇺 Read in Russian / Читать на русском](README_RU.md)

This bot allows users to anonymously send content (text, photos, videos) to administrators. Administrators can review the proposed posts and either publish them to a channel or reject them with a single button press.

## ✨ Features

* **Anonymity:** Users send content to the bot, and admins only see the content itself (with an option for users to optionally reveal their name).
* **Moderation:** Convenient "✅ Publish" and "❌ Reject" buttons.
* **Media Support:** Works with text and media files.
* **Multi-Admin:** Notifications are sent to all administrators specified in the settings.
* **Synchronization:** If one admin accepts/rejects a post, the keyboard disappears for all others to prevent duplicate actions.
* **Customizability:** Admins can change text greetings and post signatures dynamically via the `/settings` command.
* **Database:** Uses SQLite to store ticket statuses and settings.

## 🛠 Installation and Setup

### Prerequisites
* Python 3.8 or higher
* Bot Token from [@BotFather](https://t.me/BotFather)

### Step 1. Clone the repository
Download the project to a convenient folder.

### Step 2. Create a virtual environment (recommended)
```bash
# Windows
python -m venv venv
venv\Scripts\activate

# Linux / macOS
python3 -m venv venv
source venv/bin/activate
```
### Step 3. Install dependencies
Install required libraries (`aiogram`, `python-dotenv`):
```bash
pip install aiogram python-dotenv
```
### Step 4. Configuration
Rename the `example.env` file to `.env` (or create a new `.env`).
Open `.env` and fill in your details:
```Ini, TOML
BOT_TOKEN=123456:Your-Token-From-BotFather
CHANNEL_ID=-1001234567890  # ID of the channel where posts will be published
ADMIN_IDS=123456789,987654321 # Comma-separated admin IDs
```

**How to get an ID?**

* **ADMIN_IDS:** Send `/start` to your bot (if you have already set a rough ID) or use a third-party bot (e.g., @userinfobot).
* **CHANNEL_ID:** Forward a message from your channel to @getmyid_bot or add this bot to the channel. Channel IDs usually start with -100.

### Step 5. Run the bot
```bash
python bot.py
```
Alternatively, on Linux servers, you can use the provided docker `install.sh` script to quickly deploy the bot in a Docker container.

## 🚀 Usage
* **A user sends a message to the bot (image, text, etc.).**
* **The user decides whether to send it anonymously or with their name.**
* **The bot forwards the message to all Administrators.**
* **An Administrator sees the message with buttons:**
  * **Publish:** The post is instantly sent to the specified channel.
  * **Reject:** The post is marked as rejected and not published anywhere.
* **After pressing a button, the keyboard is removed for all admins to avoid duplicate actions.**

## 📂 Project Structure
`bot.py` — Main bot code.

`bot_database.db` — Database (created automatically on first run).

`.env` — File with confidential settings (do not share publicly!).

`.gitignore` — List of files ignored by Git.

`install.sh` — Script for deploying the bot via Docker.

## 📄 License
This project is licensed under the MIT License. See the LICENSE file for details.
