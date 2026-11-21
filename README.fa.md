[README.fa.md](https://github.com/user-attachments/files/35216071/README.fa.md)
<div align="center">

# ⚡ NXT-BM

### منیجر ربات NexusNet

**نصب · آپدیت · بکاپ · انتقال · امنیت** — همه با یک دستور.

![version](https://img.shields.io/badge/version-1.5.0-00b4d8?style=for-the-badge)
![shell](https://img.shields.io/badge/bash-5%2B-4eaa25?style=for-the-badge&logo=gnubash&logoColor=white)
![os](https://img.shields.io/badge/Ubuntu%20%7C%20Debian-supported-e95420?style=for-the-badge&logo=ubuntu&logoColor=white)

[English](README.md) · [فارسی](README.fa.md)

</div>

---

<div dir="rtl">

## ✨ قابلیت‌ها

- 🚀 **انتقال کامل NexusNet به VPS جدید** — سورس بات و وب‌سایت (Frontend/Backend و فایل‌های static)، دیتابیس، کلیدها و تنظیمات از طریق SSH منتقل می‌شوند. هنگام Import امکان ساخت خودکار Nginx reverse proxy و صدور SSL پس از آماده بودن DNS وجود دارد.
- 🔄 **آپدیت امن** — از روی ZIP محلی؛ `.env`، دیتابیس و کلیدهای لایسنس هرگز دست نمی‌خورند. بکاپ خودکار + برگشت (Rollback).
- 🔐 **مرکز کلید و لایسنس** — تغییر توکن، ادمین‌ها، کلید رمزنگاری، لایسنس یا ساخت جفت‌کلید جدید از داخل منو.
- 💾 **بکاپ سازگار** — بکاپ SQLite در حین اجرای ربات.
- 🧩 **رفع وابستگی Async** — نصب و تست `greenlet` برای SQLAlchemy asyncio، حتی اگر از requirements جا افتاده باشد.
- 🛑 **Preflight اجباری** — در نصب، آپدیت و مهاجرت، اگر تست‌های حیاتی شکست بخورند سرویس اجرا نمی‌شود.
- 🛡️ **حفاظت فایل‌ها** — فایل‌های ناشناخته هنگام Deploy به Snapshot زمان‌دار منتقل می‌شوند و بی‌صدا حذف نمی‌شوند.
- 🩺 **عیب‌یابی** — بررسی `.env`، کلید Fernet، سلامت دیتابیس، توکن تلگرام، وبهوک و تداخل توکن.

## 📦 نصب

</div>

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/SiNaKeEn/NexusNet-Bot/Manager/install.sh)
nxt-bm
```

<div dir="rtl">

> نیازی به نوشتن `sudo` نیست. دستور قدیمی `nexusnetmanager` هم همچنان کار می‌کند.

## 🚚 انتقال به سرور جدید

### خودکار (پیشنهادی)

روی **سرور قدیمی**:

</div>

```bash
nxt-bm     # ← [8] Migrate VPS ← [2] Push to new server
```

<div dir="rtl">

آی‌پی، پورت و کاربر SSH سرور جدید را بده؛ بقیه‌اش (خروجی گرفتن، ارسال، نصب، ایمپورت) خودکار انجام می‌شود. فقط به یک VPS تمیز اوبونتو/دبیان با دسترسی SSH نیاز داری.

### دستی

</div>

```bash
# سرور قدیمی
nxt-bm migrate-export
scp /root/nexusnet-migrate/nexusnet-migrate-* root@NEW_IP:/root/

# سرور جدید
bash <(curl -fsSL https://raw.githubusercontent.com/SiNaKeEn/NexusNet-Bot/Manager/install.sh)
nxt-bm migrate-import /root/nexusnet-migrate-XXXX.tar.gz
nxt-bm doctor
```

<div dir="rtl">

**داخل پکیج:** `.env`، دیتابیس، پوشه `data`، فایل‌های `license_*.pem`، یک نسخه از کد ربات (روی سرور جدید ZIP لازم نیست)، سرویس systemd و کرون‌ها. بعد از ایمپورت، چک‌سام، سلامت دیتابیس، توکن تلگرام، وبهوک و تداخل بررسی می‌شود.

> ⚠️ **ربات را هرگز با یک توکن روی دو سرور همزمان اجرا نکن.** بعد از انتقال، سرویس سرور قدیمی غیرفعال می‌شود.
> سایت داخل همان سرویس NexusNet و به‌صورت پیش‌فرض روی `127.0.0.1:8090` اجرا می‌شود. هنگام Import دامنه را وارد کن تا Nginx ساخته شود؛ صدور SSL فقط وقتی DNS به IP جدید اشاره کند انجام می‌شود. اگر Nginx از قبل برای دامنه کانفیگ داشته باشد، Manager آن را بازنویسی نمی‌کند.
> پکیج شامل اطلاعات حساس است؛ بعد از استفاده پاکش کن.

## 🔐 کلید و لایسنس

دستور `nxt-bm keys` یا گزینه **۱۲** منو:

| مورد | کار |
|------|-----|
| `BOT_TOKEN` | بررسی فرمت + تأیید با تلگرام |
| `ADMIN_IDS` و `BOT_OWNER_ID` | اعتبارسنجی آیدی عددی |
| `CREDENTIAL_ENCRYPTION_KEY` | وارد کردن کلید قبلی یا ساخت کلید جدید (کلید جدید = رمز پنل‌های ذخیره‌شده خوانا نمی‌شود؛ تایپ `ROTATE` لازم است) |
| `LICENSE_KEY` | فعال‌سازی با اسکریپت پروژه یا نوشتن مستقیم |
| جفت‌کلید لایسنس | اجرای `generate_license_keys.py`، نوشتن `LICENSE_SIGNING_PRIVATE_KEY` در `.env` و چاپ خط `LICENSE_VERIFY_PUBLIC_KEY` برای مشتری (تایپ `NEW-KEYS` لازم است) |
| هر متغیر دیگر | مثل `REDIS_URL` و `WEBHOOK_*` |

قبل از هر تغییر، از `.env` بکاپ گرفته می‌شود. فایل `license_private.pem` را فقط روی سرور اصلی نگه دار و هرگز به مشتری نده.

## 🔄 آپدیت ربات

</div>

```bash
scp NexusNet-V1_9_8.zip root@SERVER:/root/
nxt-bm     # ← [5] Update Bot
```

<div dir="rtl">

ورودی‌های قابل قبول: `1.9.8` ، `V1_9_8` ، `NexusNet-V1_9_8.zip` یا مسیر کامل. اگر آپدیت خراب شد، پیشنهاد برگشت می‌دهد؛ بعداً هم با گزینه **۱۳** می‌شود برگشت.

## ⌨️ دستورها

</div>

```text
nxt-bm                          منوی تعاملی
nxt-bm install | update | rollback
nxt-bm backup [full|db]         nxt-bm restore [archive]
nxt-bm migrate-export | migrate-push | migrate-import <package>
nxt-bm keys                     nxt-bm env-set KEY VALUE
nxt-bm start | stop | restart | status | logs [n]
nxt-bm doctor | telegram | repair-deps        nxt-bm update-manager
```

<div dir="rtl">

## 📁 مسیرها

| مورد | مسیر |
|------|------|
| منیجر | `/usr/local/bin/nxt-bm` |
| ربات | `/opt/nexusnet` |
| بکاپ‌ها | `/root/nexusnet-backups` |
| پکیج‌های انتقال | `/root/nexusnet-migrate` |

</div>

---

<div align="center">

Developed by **SiNa (KeEn)** · NXT-BM v1.5.0

</div>
