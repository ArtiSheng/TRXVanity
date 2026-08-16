<?php
declare(strict_types=1);

require __DIR__ . '/lib.php';
session_name('trxvanity_admin');
session_set_cookie_params([
    'lifetime' => 0,
    'path' => '/',
    'secure' => is_https_request(),
    'httponly' => true,
    'samesite' => 'Strict',
]);
session_start();
security_headers();

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    header('Allow: POST');
    http_response_code(405);
    exit('仅支持 POST。');
}

$config = app_config();
if (!empty($config['require_https']) && !is_https_request()) {
    http_response_code(400);
    exit('必须使用 HTTPS。');
}

$providedCsrf = isset($_POST['csrf']) ? (string) $_POST['csrf'] : '';
$expectedCsrf = isset($_SESSION['delete_csrf']) && is_string($_SESSION['delete_csrf'])
    ? $_SESSION['delete_csrf']
    : '';
if ($providedCsrf === '' || $expectedCsrf === '' || !hash_equals($expectedCsrf, $providedCsrf)) {
    http_response_code(403);
    exit('页面已过期，请返回备份列表后重试。');
}

$deleteToken = request_token();
if (!valid_delete_token($deleteToken)) {
    http_response_code(403);
    exit('删除令牌错误。');
}

$name = isset($_POST['file']) ? (string) $_POST['file'] : '';
if (!valid_backup_name($name) || basename($name) !== $name) {
    http_response_code(404);
    exit('文件不存在。');
}

try {
    $directory = storage_directory();
    $directoryPath = realpath($directory);
    $candidate = $directory . DIRECTORY_SEPARATOR . $name;
    $filePath = realpath($candidate);
    if ($directoryPath === false
        || $filePath === false
        || dirname($filePath) !== $directoryPath
        || !is_file($filePath)
        || is_link($candidate)) {
        http_response_code(404);
        exit('文件不存在。');
    }

    if (($_POST['confirm'] ?? '') !== 'yes') {
        ?>
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>确认删除 AES 密文</title>
  <style>
    body{margin:0;background:#f7f4ee;color:#18221d;font:15px/1.55 system-ui,"Microsoft YaHei",sans-serif}
    main{max-width:660px;margin:64px auto;padding:0 20px}.card{background:#fff;border:1px solid #ddd9d0;border-radius:12px;padding:26px}
    h1{margin:0 0 12px;font-size:23px}code{word-break:break-all}.warning{color:#a72d1d}.actions{display:flex;gap:12px;margin-top:24px;align-items:center}
    button{border:0;border-radius:8px;background:#b72f20;color:#fff;padding:10px 16px;font:inherit;font-weight:700;cursor:pointer}
    a{color:#496059;text-decoration:none;font-weight:650}
  </style>
</head>
<body><main><section class="card">
  <h1>确认永久删除</h1>
  <p>即将删除：<code><?= html($name) ?></code></p>
  <p class="warning">删除后服务器无法恢复。请先确认已经下载并验证过该 AES 密文。</p>
  <form method="post" action="delete.php">
    <input type="hidden" name="file" value="<?= html($name) ?>">
    <input type="hidden" name="csrf" value="<?= html($providedCsrf) ?>">
    <input type="hidden" name="token" value="<?= html($deleteToken) ?>">
    <input type="hidden" name="confirm" value="yes">
    <div class="actions">
      <button type="submit">确认永久删除</button>
      <a href="index.php?token=<?= rawurlencode($deleteToken) ?>">取消并返回</a>
    </div>
  </form>
</section></main></body>
</html>
        <?php
        exit;
    }

    if (!unlink($filePath)) {
        throw new RuntimeException('无法删除密文文件。');
    }
    $_SESSION['delete_csrf'] = bin2hex(random_bytes(32));
    header(
        'Location: index.php?token=' . rawurlencode($deleteToken) . '&deleted=' . rawurlencode($name),
        true,
        303
    );
    exit;
} catch (Throwable $error) {
    error_log('TRX encrypted backup deletion failed: ' . $error->getMessage());
    http_response_code(500);
    exit('服务器无法删除密文文件。');
}
