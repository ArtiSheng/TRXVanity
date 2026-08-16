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

if (!isset($_SESSION['delete_csrf']) || !is_string($_SESSION['delete_csrf'])) {
    $_SESSION['delete_csrf'] = bin2hex(random_bytes(32));
}
$deleteCsrf = $_SESSION['delete_csrf'];

$deleteToken = request_token();
$canDelete = valid_delete_token($deleteToken);
$tokenSubmitted = $deleteToken !== '';

$deleted = isset($_GET['deleted']) ? (string) $_GET['deleted'] : '';
if (!valid_backup_name($deleted)) {
    $deleted = '';
}

$files = [];
try {
    foreach (new DirectoryIterator(storage_directory()) as $item) {
        if (!$item->isFile() || !valid_backup_name($item->getFilename())) {
            continue;
        }
        $files[] = [
            'name' => $item->getFilename(),
            'size' => $item->getSize(),
            'time' => $item->getMTime(),
        ];
    }
} catch (Throwable $error) {
    http_response_code(500);
}
usort($files, static function (array $left, array $right): int {
    return $right['time'] <=> $left['time'];
});
?>
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>TRX Vanity AES 密文备份</title>
  <style>
    body{margin:0;background:#f7f4ee;color:#18221d;font:15px/1.55 system-ui,"Microsoft YaHei",sans-serif}
    main{max-width:980px;margin:48px auto;padding:0 20px}.card{background:#fff;border:1px solid #ddd9d0;border-radius:12px;padding:24px}
    h1{margin:0 0 6px;font-size:24px}.muted{color:#657169;margin:0 0 24px}table{width:100%;border-collapse:collapse}
    th,td{text-align:left;border-bottom:1px solid #ece8df;padding:12px 8px}th{color:#657169;font-size:13px}
    code{font-size:13px}a{color:#d6402c;text-decoration:none;font-weight:600}.empty{padding:34px 8px;color:#657169;text-align:center}
    .tools{display:flex;gap:14px;align-items:center;flex-wrap:wrap;margin:0 0 22px}.delete-note{margin:18px 0 12px;padding:12px;background:#faf8f3;border-radius:9px}
    .notice{margin:0 0 18px;padding:10px 12px;border-radius:8px;background:#e9f5ed;color:#235b38}
    .error{margin:0 0 18px;padding:10px 12px;border-radius:8px;background:#f8ece9;color:#9b3024}
    .token-form{display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin:0 0 18px}
    .token-form input{border:1px solid #d7d1c6;border-radius:7px;padding:8px 10px;font:inherit;min-width:240px}
    button{border:0;border-radius:7px;background:#b72f20;color:#fff;padding:8px 11px;font:inherit;font-weight:700;cursor:pointer}.danger{color:#9b3024;font-size:13px}
  </style>
</head>
<body><main><section class="card">
  <h1>AES 密文备份</h1>
  <p class="muted">服务器只保存并提供下载，不包含 AES 密钥，也不会解密文件。</p>
  <div class="tools"><a href="TRXVanityBackupDecrypt-macOS.sh" download>下载 macOS 解密脚本</a></div>
  <?php if ($deleted !== ''): ?>
    <p class="notice">已永久删除 <code><?= html($deleted) ?></code></p>
  <?php endif; ?>
  <?php if ($tokenSubmitted && !$canDelete): ?>
    <p class="error">删除令牌错误。</p>
  <?php endif; ?>
  <?php if (!$canDelete): ?>
    <form class="token-form" method="get" action="index.php">
      <label for="delete-token">删除令牌</label>
      <input id="delete-token" type="password" name="token" autocomplete="off" required>
      <button type="submit">解锁删除</button>
    </form>
  <?php endif; ?>
  <?php if (!$files): ?>
    <div class="empty">暂无加密备份文件</div>
  <?php else: ?>
    <?php if ($canDelete): ?>
    <form method="post" action="delete.php">
    <input type="hidden" name="csrf" value="<?= html($deleteCsrf) ?>">
    <input type="hidden" name="token" value="<?= html($deleteToken) ?>">
    <div class="delete-note danger">点击删除后还会进入确认页面；永久删除后无法恢复。</div>
    <?php endif; ?>
    <table><thead><tr><th>密文文件</th><th>上传时间（UTC）</th><th>大小</th><th></th></tr></thead><tbody>
    <?php foreach ($files as $file): ?>
      <tr>
        <td><code><?= html($file['name']) ?></code></td>
        <td><?= html(gmdate('Y-m-d H:i:s', $file['time'])) ?></td>
        <td><?= number_format((int) $file['size']) ?> B</td>
        <td>
          <a href="download.php?file=<?= rawurlencode($file['name']) ?>">下载密文</a>
          <?php if ($canDelete): ?>
            &nbsp;
            <button type="submit" name="file" value="<?= html($file['name']) ?>">删除</button>
          <?php endif; ?>
        </td>
      </tr>
    <?php endforeach; ?>
    </tbody></table>
    <?php if ($canDelete): ?>
    </form>
    <?php endif; ?>
  <?php endif; ?>
</section></main></body>
</html>
