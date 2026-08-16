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
    json_error(403, '上传令牌错误。');
}

$maximum = (int) $config['max_upload_bytes'];
$declaredLength = isset($_SERVER['CONTENT_LENGTH']) ? (int) $_SERVER['CONTENT_LENGTH'] : 0;
if ($declaredLength <= 0 || $declaredLength > $maximum) {
    json_error(413, '文件大小无效。');
}

$data = file_get_contents('php://input');
if ($data === false) {
    json_error(400, '无法读取上传内容。');
}
$size = strlen($data);
if ($size < 76 || $size > $maximum || substr($data, 0, 8) !== 'TRXMNEMO') {
    json_error(400, '不是有效的 TRX Vanity AES 密文文件。');
}
$lengthField = unpack('Nlength', substr($data, 24, 4));
$cipherLength = (int) $lengthField['length'];
if ($cipherLength < 16 || $cipherLength % 16 !== 0 || $size !== 28 + $cipherLength + 32) {
    json_error(400, '密文文件长度无效。');
}

try {
    $directory = storage_directory();
    $name = 'backup_' . gmdate('Ymd_His') . '_' . bin2hex(random_bytes(8)) . '.trxv';
    $path = $directory . DIRECTORY_SEPARATOR . $name;
    $handle = fopen($path, 'xb');
    if ($handle === false) {
        throw new RuntimeException('无法创建密文文件。');
    }
    try {
        if (!flock($handle, LOCK_EX)) {
            throw new RuntimeException('无法锁定密文文件。');
        }
        $written = 0;
        while ($written < $size) {
            $count = fwrite($handle, substr($data, $written));
            if ($count === false || $count === 0) {
                throw new RuntimeException('密文写入不完整。');
            }
            $written += $count;
        }
        fflush($handle);
    } finally {
        fclose($handle);
    }
    @chmod($path, 0600);
} catch (Throwable $error) {
    error_log('TRX encrypted backup upload failed: ' . $error->getMessage());
    json_error(500, '服务器无法保存密文文件。');
}

http_response_code(201);
header('Content-Type: application/json; charset=utf-8');
echo json_encode(
    ['ok' => true, 'file' => $name, 'bytes' => $size],
    JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES
);
