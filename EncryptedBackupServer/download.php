<?php
declare(strict_types=1);

require __DIR__ . '/lib.php';
security_headers();

$name = isset($_GET['file']) ? (string) $_GET['file'] : '';
if (!valid_backup_name($name) || basename($name) !== $name) {
    http_response_code(404);
    exit('文件不存在。');
}

try {
    $path = storage_directory() . DIRECTORY_SEPARATOR . $name;
    if (!is_file($path)) {
        http_response_code(404);
        exit('文件不存在。');
    }
    header('Content-Type: application/octet-stream');
    header('Content-Disposition: attachment; filename="' . $name . '"');
    header('Content-Length: ' . filesize($path));
    $handle = fopen($path, 'rb');
    if ($handle === false) {
        throw new RuntimeException('无法打开文件。');
    }
    fpassthru($handle);
    fclose($handle);
} catch (Throwable $error) {
    if (!headers_sent()) {
        http_response_code(500);
    }
}
