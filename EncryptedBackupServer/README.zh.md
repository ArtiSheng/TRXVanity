# TRX Vanity AES 密文服务器

[English](README.md)

这个目录可直接部署到支持 PHP 7.4+ 的 HTTPS 站点。服务器只接收、保存、列出、下载和删除 `.trxv` 密文，不包含 AES 密钥，也不会在服务器上解密。

## 先配置 `config.php`

仓库里的 `config.php` 全是 `demotext` 占位符，**不改不能用于生产**。部署前请至少改这些项：

| 项 | 说明 |
|---|---|
| `upload_token` | 上传和心跳用的令牌，换成一段随机字符串 |
| `delete_token` | 后台删除密文用的令牌，必须和上传令牌不同，不要写进客户端 |
| `mail.enabled` | 配好邮箱后再改为 `true` |
| `mail.to` / `mail.from` | 收件人、发件人 |
| `mail.smtp_*` | SMTP 主机、端口、加密方式和授权码 |

生成两段不同的随机令牌：

```bash
python3 -c "import secrets; [print(secrets.token_hex(32)) for _ in range(2)]"
```

客户端上传地址填：

```text
https://你的域名/upload.php?token=你在config.php里设置的upload_token
```

上传令牌只用于防止陌生人向接口写入垃圾文件，不是 AES 密钥。删除密文必须使用单独的 `delete_token`：在首页输入该令牌并点“解锁删除”，或直接打开：

```text
https://你的域名/index.php?token=你在config.php里设置的delete_token
```

解锁后才能看到删除按钮；下一页再次确认后才会永久删除。页面仍会使用浏览器会话校验防止跨站请求。没有正确删除令牌时，`delete.php` 会拒绝删除。

## 部署

1. 改好 `config.php` 后，把整个 `EncryptedBackupServer` 目录上传到 PHP 网站。
2. 确保 PHP 进程可写 `storage/`，并确认站点已启用 HTTPS。
3. 浏览 `index.php` 可查看和下载密文，也可下载 macOS 解密脚本。删除前先在页面输入 `delete_token`，或在地址栏带上 `?token=删除令牌`。

Nginx 部署时应额外禁止访问 `config.php`、`lib.php`、`check-heartbeats.php` 和 `storage/`；Apache 会读取本目录自带的 `.htaccess`。升级已有服务器时，上传新的 `index.php`、`delete.php`、`lib.php`、`check-heartbeats.php`，并在服务器现有 `config.php` 里删掉已无用的 `monitor_token`；**不要整文件覆盖已经改好的 `config.php` 和 `storage/`**。删除令牌不要和使用上传功能的客户端共享。建议再在 Nginx、宝塔或 Cloudflare 上为后台增加登录保护或访问白名单。

## 心跳和邮件通知

客户端应用 AES 设置后，会自动复用 `upload.php?token=...` 的地址和令牌，每 15 秒向同目录的 `heartbeat.php` 上报状态。心跳包含客户端名称、运行状态、搜索后缀、速度、尝试次数、错误信息和命中的公开地址；不包含助记词或 AES 密钥。

服务器会立即处理以下事件并发送邮件：

- 搜索命中（只在邮件中包含公开地址）
- 应用或 GPU 引擎错误、引擎异常退出
- 本机历史保存失败、AES 加密或密文上传失败
- 搜索进度长期不增长、速度持续异常偏低

“程序卡死、电脑掉电或断网”发生后，客户端已经无法请求服务器，因此需要服务器每分钟主动运行一次 `check-heartbeats.php`。默认连续 90 秒收不到心跳就只告警一次；客户端恢复上报后会自动解除该告警状态。

### 1. 配置邮箱

编辑 `config.php` 的 `mail` 部分，填写收件人和发件人，并把 `enabled` 改为 `true`。

如果服务器本身已经配置 PHP 发信，使用：

```php
'driver' => 'mail',
```

如果使用邮箱 SMTP，示例：

```php
'enabled' => true,
'to' => '收件邮箱@example.com',
'from' => '发件邮箱@example.com',
'driver' => 'smtp',
'smtp_host' => 'smtp.example.com',
'smtp_port' => 465,
'smtp_encryption' => 'ssl',
'smtp_username' => '发件邮箱@example.com',
'smtp_password' => '邮箱的 SMTP 授权码',
```

465 端口通常使用 `ssl`；587 端口通常使用 `starttls`。应填写邮箱服务商提供的 SMTP 授权码，不要填写网页登录密码。

配置后先发送一封测试邮件（把路径换成你的网站目录）：

```bash
/usr/bin/php /www/wwwroot/你的域名/check-heartbeats.php --test-email
```

看到“测试邮件已发送”并收到邮件后，再添加下面的每分钟计划任务。

### 2. 添加每分钟计划任务

首选服务器本机 PHP 命令行。先确认 PHP 路径和网站绝对路径：

```bash
which php
realpath /www/wwwroot/你的域名/check-heartbeats.php
```

Linux Crontab 每分钟执行：

```cron
* * * * * /usr/bin/php /www/wwwroot/你的域名/check-heartbeats.php >/dev/null 2>&1
```

宝塔面板：进入“计划任务”→“Shell 脚本”→执行周期选“每分钟”，脚本填写：

```bash
/www/server/php/82/bin/php /www/wwwroot/你的域名/check-heartbeats.php
```

PHP 版本路径按服务器实际版本修改，例如 PHP 8.2 常见路径为 `/www/server/php/82/bin/php`。

`check-heartbeats.php` 只能用本机 PHP 命令行运行，浏览器或 WebCron 访问会被拒绝。宝塔已经自带计划任务，用上面的每分钟 Shell 即可。

### 3. 调整判定时间

`config.php` 的 `heartbeat` 部分可调整：

- `offline_after_seconds`：多久没收到心跳判定断联，默认 90 秒。
- `progress_stale_seconds`：搜索尝试次数多久不增长判定异常，默认 90 秒。
- `low_speed_grace_seconds`：开始搜索多久后才检测低速，默认 180 秒。
- `low_speed_for_seconds`：低速持续多久才告警，默认 180 秒。
- `low_speed_ratio`：低于本次搜索峰值的比例，默认 20%。

## 解密

请查看 `AES-Decrypt/README.zh.md`。
