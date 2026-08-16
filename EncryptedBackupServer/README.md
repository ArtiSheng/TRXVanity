# TRX Vanity AES Ciphertext Server

[中文说明](README.zh.md)

This directory can be deployed to any HTTPS site that supports PHP 7.4+. The server only receives, stores, lists, downloads, and deletes `.trxv` ciphertext. It does not contain the AES key and never decrypts files on the server.

## Configure `config.php` first

The `config.php` in this repository is filled with `demotext` placeholders. **Do not use it in production until you change it.** Before deploy, update at least these items:

| Key | Purpose |
|---|---|
| `upload_token` | Token for uploads and heartbeats. Replace it with a random string. |
| `delete_token` | Token for deleting ciphertext in the admin page. It must differ from the upload token. Do not put it in clients. |
| `mail.enabled` | Set to `true` after the mailbox is configured. |
| `mail.to` / `mail.from` | Recipient and sender |
| `mail.smtp_*` | SMTP host, port, encryption, and authorization code |

Generate two different random tokens:

```bash
python3 -c "import secrets; [print(secrets.token_hex(32)) for _ in range(2)]"
```

The client upload URL is:

```text
https://your-domain/upload.php?token=the_upload_token_from_config.php
```

The upload token only stops strangers from writing junk files. It is not the AES key. Deleting ciphertext requires the separate `delete_token`. Enter that token on the home page and click “Unlock delete”, or open:

```text
https://your-domain/index.php?token=the_delete_token_from_config.php
```

The delete button appears only after unlock. A second confirmation page is required before permanent deletion. The page still uses the browser session to block cross-site requests. Without the correct delete token, `delete.php` refuses the request.

## Deploy

1. After editing `config.php`, upload the entire `EncryptedBackupServer` directory to the PHP site.
2. Make sure the PHP process can write `storage/`, and that the site uses HTTPS.
3. Open `index.php` to view and download ciphertext, or to download the macOS decrypt script. To delete, enter `delete_token` on the page, or add `?token=delete-token` to the URL.

On Nginx, also block access to `config.php`, `lib.php`, `check-heartbeats.php`, and `storage/`. Apache reads the `.htaccess` in this directory. When upgrading an existing server, upload the new `index.php`, `delete.php`, `lib.php`, and `check-heartbeats.php`, and remove the unused `monitor_token` from the live `config.php`. **Do not overwrite a finished `config.php` or `storage/` with the whole directory.** Do not share the delete token with clients that only upload. Add login protection or an allowlist for the admin page on Nginx, BaoTa, or Cloudflare.

## Heartbeats and email alerts

After the client applies AES settings, it reuses the `upload.php?token=...` URL and token, and reports status to `heartbeat.php` in the same directory every 15 seconds. A heartbeat includes the client name, run state, search suffix, speed, attempt count, errors, and hit public addresses. It does not include the mnemonic or AES key.

The server handles these events immediately and sends email:

- Search hit (public address only in the email)
- App or GPU engine error, or abnormal engine exit
- Local history save failure, AES encryption failure, or ciphertext upload failure
- Search progress stuck for a long time, or speed staying abnormally low

After a freeze, power loss, or network drop, the client can no longer reach the server, so the server must run `check-heartbeats.php` once a minute. By default it alerts once after 90 seconds without a heartbeat. The alert clears automatically when the client reports again.

### 1. Configure email

Edit the `mail` section in `config.php`, fill in the recipient and sender, and set `enabled` to `true`.

If the server already has PHP mail configured, use:

```php
'driver' => 'mail',
```

SMTP example:

```php
'enabled' => true,
'to' => 'recipient@example.com',
'from' => 'sender@example.com',
'driver' => 'smtp',
'smtp_host' => 'smtp.example.com',
'smtp_port' => 465,
'smtp_encryption' => 'ssl',
'smtp_username' => 'sender@example.com',
'smtp_password' => 'SMTP authorization code',
```

Port 465 usually uses `ssl`. Port 587 usually uses `starttls`. Use the SMTP authorization code from the mail provider, not the web login password.

Send a test email first (replace the path with your site directory):

```bash
/usr/bin/php /www/wwwroot/your-domain/check-heartbeats.php --test-email
```

After you see “test email sent” and receive the message, add the per-minute scheduled task below.

### 2. Add a per-minute scheduled task

Prefer the server’s local PHP CLI. Confirm the PHP path and the absolute path of the site:

```bash
which php
realpath /www/wwwroot/your-domain/check-heartbeats.php
```

Linux crontab, every minute:

```cron
* * * * * /usr/bin/php /www/wwwroot/your-domain/check-heartbeats.php >/dev/null 2>&1
```

BaoTa panel: Scheduled Tasks → Shell script → every minute, with:

```bash
/www/server/php/82/bin/php /www/wwwroot/your-domain/check-heartbeats.php
```

Change the PHP path to match the server, for example `/www/server/php/82/bin/php` for PHP 8.2.

`check-heartbeats.php` must run from the local PHP CLI. Browser or WebCron access is rejected. BaoTa already has scheduled tasks, so the per-minute Shell above is enough.

### 3. Tune the thresholds

The `heartbeat` section in `config.php` can adjust:

- `offline_after_seconds`: seconds without a heartbeat before offline. Default 90.
- `progress_stale_seconds`: seconds without an increasing attempt count before a stall alert. Default 90.
- `low_speed_grace_seconds`: seconds after search start before low-speed checks. Default 180.
- `low_speed_for_seconds`: how long low speed must last before an alert. Default 180.
- `low_speed_ratio`: fraction of this search’s peak speed. Default 20%.

## Decrypt

See `AES-Decrypt/README.md`.
