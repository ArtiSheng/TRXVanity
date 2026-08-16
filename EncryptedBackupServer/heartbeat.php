<?php
declare(strict_types=1);

require __DIR__ . '/lib.php';
security_headers();

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    header('Allow: POST');
    json_error(405, '仅支持 POST。');
}
$config = app_config();
if (!empty($config['require_https']) && !is_https_request()) {
    json_error(400, '必须使用 HTTPS。');
}
$providedToken = isset($_GET['token']) ? (string) $_GET['token'] : '';
if ($providedToken === '' || !hash_equals((string) $config['upload_token'], $providedToken)) {
    json_error(403, '心跳令牌错误。');
}
$declaredLength = isset($_SERVER['CONTENT_LENGTH']) ? (int) $_SERVER['CONTENT_LENGTH'] : 0;
if ($declaredLength <= 0 || $declaredLength > 32768) {
    json_error(413, '心跳数据大小无效。');
}
$raw = file_get_contents('php://input');
$input = is_string($raw) ? json_decode($raw, true) : null;
if (!is_array($input)) {
    json_error(400, '心跳 JSON 无效。');
}
$clientId = clean_status_text($input['client_id'] ?? '', 64);
$runId = clean_status_text($input['run_id'] ?? '', 64);
$state = clean_status_text($input['state'] ?? '', 32);
if (preg_match('/\A[a-f0-9]{32}\z/D', $clientId) !== 1
    || preg_match('/\A[a-f0-9]{32}\z/D', $runId) !== 1
    || !in_array($state, ['starting', 'ready', 'searching', 'result', 'error', 'closing'], true)) {
    json_error(400, '心跳字段无效。');
}
$now = time();
$notices = [];
try {
    update_heartbeat_registry(static function (array &$registry) use ($input, $clientId, $runId, $state, $now, &$notices): void {
        $previous = isset($registry[$clientId]) && is_array($registry[$clientId]) ? $registry[$clientId] : [];
        $newRun = ($previous['run_id'] ?? '') !== $runId;
        if ($newRun && $previous !== [] && empty($previous['closed'])) {
            $notices[] = [
                'title' => '客户端异常重启',
                'detail' => '服务器没有收到上一次运行的正常退出状态；应用、电脑或网络可能曾异常中断。上次心跳（UTC）：'
                    . gmdate('Y-m-d H:i:s', (int) ($previous['last_seen'] ?? $now)),
            ];
        }
        $sequence = max(0, (int) ($input['sequence'] ?? 0));
        if (!$newRun && $sequence <= (int) ($previous['last_sequence'] ?? 0)) {
            // Event packets must still notify even if a later periodic packet
            // reached the server first. They must not overwrite newer state.
            $staleEvent = clean_status_text($input['event'] ?? '', 32);
            $staleEventId = clean_status_text($input['event_id'] ?? '', 64);
            $staleEventTitle = heartbeat_event_title($staleEvent);
            if ($staleEventTitle !== '' && $staleEventId !== ''
                && ($previous['last_event_id'] ?? '') !== $staleEventId) {
                $previous['last_event_id'] = $staleEventId;
                $eventAddress = clean_status_text($input['address'] ?? '', 64);
                if ($eventAddress !== '') {
                    $previous['address'] = $eventAddress;
                }
                $eventDetail = clean_status_text($input['detail'] ?? '', 1000);
                $notices[] = [
                    'title' => $staleEventTitle,
                    'detail' => $eventDetail !== '' ? $eventDetail : $staleEventTitle,
                ];
                $registry[$clientId] = $previous;
            }
            return;
        }
        $previousState = (string) ($previous['state'] ?? '');
        $previousAttempts = (float) ($previous['attempts'] ?? 0);
        $speed = max(0.0, (float) ($input['speed'] ?? 0));
        $attempts = max(0.0, (float) ($input['attempts'] ?? 0));
        $client = $newRun ? [] : $previous;
        $client['client_id'] = $clientId;
        $client['run_id'] = $runId;
        $client['client_name'] = clean_status_text($input['client_name'] ?? '', 128);
        $client['state'] = $state;
        $client['detail'] = clean_status_text($input['detail'] ?? '', 1000);
        $client['suffix'] = clean_status_text($input['suffix'] ?? '', 16);
        $client['address'] = clean_status_text($input['address'] ?? '', 64);
        $client['speed'] = $speed;
        $client['attempts'] = $attempts;
        $client['last_seen'] = $now;
        $client['last_sequence'] = $sequence;
        $client['closed'] = $state === 'closing';
        if ($newRun) {
            $client['started_at'] = $now;
            $client['alerts'] = [];
            $client['last_event_id'] = '';
            $client['peak_speed'] = 0.0;
        }
        if (!isset($client['alerts']) || !is_array($client['alerts'])) {
            $client['alerts'] = [];
        }
        if ($state === 'searching') {
            if ($newRun || $previousState !== 'searching') {
                $client['search_started_at'] = $now;
                $client['last_progress_at'] = $now;
                $client['peak_speed'] = $speed;
                $client['low_speed_since'] = 0;
                $client['alerts']['stale'] = false;
                $client['alerts']['low_speed'] = false;
            } else {
                if ($attempts > $previousAttempts) {
                    $client['last_progress_at'] = $now;
                    $client['alerts']['stale'] = false;
                }
                $client['peak_speed'] = max((float) ($client['peak_speed'] ?? 0), $speed);
                $settings = app_config()['heartbeat'];
                $threshold = max(
                    (float) $settings['minimum_speed'],
                    (float) $client['peak_speed'] * (float) $settings['low_speed_ratio']
                );
                $gracePassed = $now - (int) ($client['search_started_at'] ?? $now)
                    >= (int) $settings['low_speed_grace_seconds'];
                if ($gracePassed && $speed < $threshold) {
                    if (empty($client['low_speed_since'])) {
                        $client['low_speed_since'] = $now;
                    }
                } else {
                    $client['low_speed_since'] = 0;
                    $client['alerts']['low_speed'] = false;
                }
            }
        } else {
            $client['low_speed_since'] = 0;
        }

        $event = clean_status_text($input['event'] ?? '', 32);
        $eventId = clean_status_text($input['event_id'] ?? '', 64);
        $eventTitle = heartbeat_event_title($event);
        if ($eventTitle !== '' && $eventId !== '' && ($client['last_event_id'] ?? '') !== $eventId) {
            $client['last_event_id'] = $eventId;
            $notices[] = [
                'title' => $eventTitle,
                'detail' => $client['detail'] !== '' ? $client['detail'] : $eventTitle,
            ];
        }
        foreach (heartbeat_alerts($client, $now) as $alert) {
            $notices[] = $alert;
        }
        $registry[$clientId] = $client;
    });
} catch (Throwable $error) {
    error_log('TRX heartbeat save failed: ' . $error->getMessage());
    json_error(500, '服务器无法保存心跳。');
}

$sent = 0;
foreach ($notices as $notice) {
    $client = [];
    update_heartbeat_registry(static function (array &$registry) use ($clientId, &$client): void {
        $client = $registry[$clientId] ?? [];
    });
    if ($client && send_monitor_alert($notice['title'], $client, $notice['detail'])) {
        $sent++;
    }
}
header('Content-Type: application/json; charset=utf-8');
echo json_encode(['ok' => true, 'notifications' => $sent], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
