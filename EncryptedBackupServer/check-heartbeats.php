<?php
declare(strict_types=1);

require __DIR__ . '/lib.php';

if (PHP_SAPI !== 'cli') {
    http_response_code(403);
    header('Content-Type: text/plain; charset=utf-8');
    echo "check-heartbeats.php 只能通过服务器本机 PHP 命令行运行。\n";
    exit(1);
}

if (isset($argv[1]) && $argv[1] === '--test-email') {
    $testClient = [
        'client_name' => '服务器邮件测试',
        'client_id' => 'test',
        'run_id' => 'test',
        'state' => 'test',
        'suffix' => '',
        'speed' => 0,
        'attempts' => 0,
        'last_seen' => time(),
    ];
    if (!send_monitor_alert('测试邮件', $testClient, 'TRX Vanity 心跳监控邮件配置有效。')) {
        fwrite(STDERR, "测试邮件发送失败，请检查 config.php 和 PHP 错误日志。\n");
        exit(1);
    }
    echo "测试邮件已发送。\n";
    exit(0);
}

$now = time();
$notices = [];
try {
    update_heartbeat_registry(static function (array &$registry) use ($now, &$notices): void {
        foreach ($registry as $clientId => &$client) {
            if (!is_array($client)) {
                unset($registry[$clientId]);
                continue;
            }
            foreach (heartbeat_alerts($client, $now) as $alert) {
                $notices[] = ['client' => $client, 'title' => $alert['title'], 'detail' => $alert['detail']];
            }
        }
        unset($client);
    });
} catch (Throwable $error) {
    error_log('TRX heartbeat check failed: ' . $error->getMessage());
    fwrite(STDERR, $error->getMessage() . PHP_EOL);
    exit(1);
}

$sent = 0;
foreach ($notices as $notice) {
    if (send_monitor_alert($notice['title'], $notice['client'], $notice['detail'])) {
        $sent++;
    }
}
echo json_encode(
    ['ok' => true, 'alerts' => count($notices), 'sent' => $sent, 'checked_at' => gmdate('c', $now)],
    JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES
) . PHP_EOL;
