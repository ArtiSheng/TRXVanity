<?php
declare(strict_types=1);

function app_config(): array
{
    static $config;
    if ($config === null) {
        $config = require __DIR__ . '/config.php';
    }
    return $config;
}

function security_headers(): void
{
    header('X-Content-Type-Options: nosniff');
    header('X-Frame-Options: DENY');
    header('Referrer-Policy: no-referrer');
    header("Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'");
    header('Cache-Control: no-store');
}

function is_https_request(): bool
{
    if (!empty($_SERVER['HTTPS']) && strtolower((string) $_SERVER['HTTPS']) !== 'off') {
        return true;
    }
    return isset($_SERVER['HTTP_X_FORWARDED_PROTO'])
        && strtolower(trim(explode(',', (string) $_SERVER['HTTP_X_FORWARDED_PROTO'])[0])) === 'https';
}

function storage_directory(): string
{
    $directory = (string) app_config()['storage_dir'];
    if (!is_dir($directory) && !mkdir($directory, 0700, true) && !is_dir($directory)) {
        throw new RuntimeException('无法创建密文存储目录。');
    }
    return $directory;
}

function valid_backup_name(string $name): bool
{
    return preg_match('/\Abackup_[0-9]{8}_[0-9]{6}_[a-f0-9]{16}\.trxv\z/D', $name) === 1;
}

function html(string $value): string
{
    return htmlspecialchars($value, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

function request_token(): string
{
    if (isset($_POST['token']) && is_string($_POST['token'])) {
        return $_POST['token'];
    }
    if (isset($_GET['token']) && is_string($_GET['token'])) {
        return $_GET['token'];
    }
    return '';
}

function valid_configured_token(string $configKey, string $provided): bool
{
    $expected = (string) (app_config()[$configKey] ?? '');
    return $provided !== '' && $expected !== '' && hash_equals($expected, $provided);
}

function valid_delete_token(string $provided = ''): bool
{
    if ($provided === '') {
        $provided = request_token();
    }
    return valid_configured_token('delete_token', $provided);
}

function json_error(int $status, string $message): void
{
    http_response_code($status);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode(['ok' => false, 'error' => $message], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}

function heartbeat_state_path(): string
{
    return storage_directory() . DIRECTORY_SEPARATOR . 'heartbeat-state.json';
}

function update_heartbeat_registry(callable $callback)
{
    $path = heartbeat_state_path();
    $handle = fopen($path, 'c+b');
    if ($handle === false) {
        throw new RuntimeException('无法打开心跳状态文件。');
    }
    try {
        if (!flock($handle, LOCK_EX)) {
            throw new RuntimeException('无法锁定心跳状态文件。');
        }
        rewind($handle);
        $raw = stream_get_contents($handle);
        $registry = [];
        if (is_string($raw) && trim($raw) !== '') {
            $decoded = json_decode($raw, true);
            if (is_array($decoded)) {
                $registry = $decoded;
            }
        }
        $result = $callback($registry);
        $encoded = json_encode($registry, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_PRETTY_PRINT);
        if ($encoded === false) {
            throw new RuntimeException('无法编码心跳状态。');
        }
        rewind($handle);
        if (!ftruncate($handle, 0) || fwrite($handle, $encoded . "\n") === false) {
            throw new RuntimeException('无法保存心跳状态。');
        }
        fflush($handle);
        @chmod($path, 0600);
        return $result;
    } finally {
        flock($handle, LOCK_UN);
        fclose($handle);
    }
}

function clean_status_text($value, int $maximum): string
{
    if (!is_string($value)) {
        return '';
    }
    $value = str_replace(["\0", "\r", "\n"], ['', '', ' '], trim($value));
    return strlen($value) <= $maximum ? $value : substr($value, 0, $maximum);
}

function heartbeat_event_title(string $event): string
{
    $titles = [
        'result' => '搜索到地址',
        'error' => '应用或 GPU 引擎错误',
        'engine_exit' => 'GPU 引擎异常退出',
        'backup_error' => 'AES 密文备份失败',
    ];
    return $titles[$event] ?? '';
}

function heartbeat_alerts(array &$client, int $now): array
{
    $alerts = [];
    if (!empty($client['closed'])) {
        return $alerts;
    }
    $settings = app_config()['heartbeat'];
    $lastSeen = (int) ($client['last_seen'] ?? 0);
    if ($lastSeen > 0 && $now - $lastSeen >= (int) $settings['offline_after_seconds']) {
        if (empty($client['alerts']['offline'])) {
            $client['alerts']['offline'] = true;
            $alerts[] = [
                'title' => '客户端心跳中断',
                'detail' => '服务器已 ' . ($now - $lastSeen) . ' 秒未收到心跳，应用可能卡死、退出、断网或电脑掉电。',
            ];
        }
        return $alerts;
    }
    $client['alerts']['offline'] = false;

    if (($client['state'] ?? '') !== 'searching') {
        $client['alerts']['stale'] = false;
        $client['alerts']['low_speed'] = false;
        return $alerts;
    }

    $lastProgress = (int) ($client['last_progress_at'] ?? $lastSeen);
    if ($lastProgress > 0 && $now - $lastProgress >= (int) $settings['progress_stale_seconds']) {
        if (empty($client['alerts']['stale'])) {
            $client['alerts']['stale'] = true;
            $alerts[] = [
                'title' => 'GPU 搜索进度异常',
                'detail' => '客户端仍有心跳，但搜索尝试次数已 ' . ($now - $lastProgress) . ' 秒没有增长，GPU 引擎可能卡住。',
            ];
        }
    } else {
        $client['alerts']['stale'] = false;
    }

    $lowSince = (int) ($client['low_speed_since'] ?? 0);
    if ($lowSince > 0 && $now - $lowSince >= (int) $settings['low_speed_for_seconds']) {
        if (empty($client['alerts']['low_speed'])) {
            $client['alerts']['low_speed'] = true;
            $alerts[] = [
                'title' => 'GPU 搜索速度异常',
                'detail' => '当前速度 ' . number_format((float) ($client['speed'] ?? 0), 0)
                    . '/s，持续低于本次搜索正常峰值的 '
                    . number_format((float) $settings['low_speed_ratio'] * 100, 0) . '%。',
            ];
        }
    } else {
        $client['alerts']['low_speed'] = false;
    }
    return $alerts;
}

function send_monitor_alert(string $title, array $client, string $detail): bool
{
    $mail = app_config()['mail'];
    if (empty($mail['enabled'])) {
        error_log('TRX monitor alert (mail disabled): ' . $title . ' - ' . $detail);
        return false;
    }
    $subject = '[TRX Vanity] ' . $title . ' - ' . ($client['client_name'] ?? '未知客户端');
    $lines = [
        'TRX Vanity 状态通知',
        '',
        '事件：' . $title,
        '客户端：' . ($client['client_name'] ?? ''),
        '客户端 ID：' . ($client['client_id'] ?? ''),
        '运行 ID：' . ($client['run_id'] ?? ''),
        '状态：' . ($client['state'] ?? ''),
        '说明：' . $detail,
        '搜索后缀：' . ($client['suffix'] ?? ''),
        '当前速度：' . number_format((float) ($client['speed'] ?? 0), 0) . '/s',
        '已尝试：' . number_format((float) ($client['attempts'] ?? 0), 0),
        '最后心跳（UTC）：' . gmdate('Y-m-d H:i:s', (int) ($client['last_seen'] ?? time())),
    ];
    if (!empty($client['address'])) {
        $lines[] = '命中地址：' . $client['address'];
    }
    $body = implode("\r\n", $lines) . "\r\n";
    try {
        if (($mail['driver'] ?? 'mail') === 'smtp') {
            smtp_send_message($mail, $subject, $body);
            return true;
        }
        $encodedSubject = '=?UTF-8?B?' . base64_encode($subject) . '?=';
        $headers = [
            'From: ' . safe_mailbox((string) $mail['from']),
            'MIME-Version: 1.0',
            'Content-Type: text/plain; charset=UTF-8',
            'Content-Transfer-Encoding: 8bit',
        ];
        if (!mail(safe_mailbox((string) $mail['to']), $encodedSubject, $body, implode("\r\n", $headers))) {
            throw new RuntimeException('PHP mail() 返回失败。');
        }
        return true;
    } catch (Throwable $error) {
        error_log('TRX monitor mail failed: ' . $error->getMessage());
        return false;
    }
}

function safe_mailbox(string $value): string
{
    $value = trim($value);
    if (preg_match('/[\r\n]/', $value) || !filter_var($value, FILTER_VALIDATE_EMAIL)) {
        throw new RuntimeException('邮件地址配置无效。');
    }
    return $value;
}

function smtp_send_message(array $mail, string $subject, string $body): void
{
    $host = (string) $mail['smtp_host'];
    $port = (int) $mail['smtp_port'];
    $encryption = strtolower((string) ($mail['smtp_encryption'] ?? 'ssl'));
    $target = ($encryption === 'ssl' ? 'ssl://' : 'tcp://') . $host . ':' . $port;
    $socket = stream_socket_client($target, $errorNumber, $errorMessage, 15, STREAM_CLIENT_CONNECT);
    if ($socket === false) {
        throw new RuntimeException('SMTP 连接失败：' . $errorMessage . ' (' . $errorNumber . ')');
    }
    stream_set_timeout($socket, 15);
    try {
        smtp_expect($socket, [220]);
        smtp_command($socket, 'EHLO ' . (gethostname() ?: 'localhost'), [250]);
        if ($encryption === 'starttls') {
            smtp_command($socket, 'STARTTLS', [220]);
            if (!stream_socket_enable_crypto($socket, true, STREAM_CRYPTO_METHOD_TLS_CLIENT)) {
                throw new RuntimeException('SMTP STARTTLS 协商失败。');
            }
            smtp_command($socket, 'EHLO ' . (gethostname() ?: 'localhost'), [250]);
        }
        $username = (string) ($mail['smtp_username'] ?? '');
        if ($username !== '') {
            smtp_command($socket, 'AUTH LOGIN', [334]);
            smtp_command($socket, base64_encode($username), [334]);
            smtp_command($socket, base64_encode((string) $mail['smtp_password']), [235]);
        }
        $from = safe_mailbox((string) $mail['from']);
        $to = safe_mailbox((string) $mail['to']);
        smtp_command($socket, 'MAIL FROM:<' . $from . '>', [250]);
        smtp_command($socket, 'RCPT TO:<' . $to . '>', [250, 251]);
        smtp_command($socket, 'DATA', [354]);
        $headers = [
            'From: <' . $from . '>',
            'To: <' . $to . '>',
            'Subject: =?UTF-8?B?' . base64_encode($subject) . '?=',
            'Date: ' . date(DATE_RFC2822),
            'Message-ID: <' . bin2hex(random_bytes(12)) . '@' . preg_replace('/[^A-Za-z0-9.-]/', '', $host) . '>',
            'MIME-Version: 1.0',
            'Content-Type: text/plain; charset=UTF-8',
            'Content-Transfer-Encoding: 8bit',
        ];
        $message = implode("\r\n", $headers) . "\r\n\r\n" . $body;
        $message = preg_replace('/(?m)^\./', '..', $message);
        fwrite($socket, $message . "\r\n.\r\n");
        smtp_expect($socket, [250]);
        smtp_command($socket, 'QUIT', [221]);
    } finally {
        fclose($socket);
    }
}

function smtp_command($socket, string $command, array $expected): string
{
    if (fwrite($socket, $command . "\r\n") === false) {
        throw new RuntimeException('SMTP 写入失败。');
    }
    return smtp_expect($socket, $expected);
}

function smtp_expect($socket, array $expected): string
{
    $response = '';
    do {
        $line = fgets($socket, 2048);
        if ($line === false) {
            throw new RuntimeException('SMTP 响应超时。');
        }
        $response .= $line;
    } while (strlen($line) >= 4 && $line[3] === '-');
    $code = (int) substr($response, 0, 3);
    if (!in_array($code, $expected, true)) {
        throw new RuntimeException('SMTP 返回错误：' . trim($response));
    }
    return $response;
}
