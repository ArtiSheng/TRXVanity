<?php
declare(strict_types=1);

return [
    // 部署前请把两段令牌都改成互不相同的随机字符串。客户端上传地址：/upload.php?token=下面这段内容
    'upload_token' => 'demotext',
    'storage_dir' => __DIR__ . '/storage',
    'max_upload_bytes' => 1048576,
    'require_https' => true,

    // 后台删除令牌：打开 index.php?token=下面这段内容后才能删除密文。
    // 必须和 upload_token 不同，不要写进客户端。
    'delete_token' => 'demotext',
    'heartbeat' => [
        'offline_after_seconds' => 90,
        'progress_stale_seconds' => 90,
        'low_speed_grace_seconds' => 180,
        'low_speed_for_seconds' => 180,
        'low_speed_ratio' => 0.20,
        'minimum_speed' => 1.0,
    ],

    // 邮件默认关闭。填写真实收件人、发件人和 SMTP 后改为 true。
    'mail' => [
        'enabled' => false,
        'to' => 'demotext@example.com',
        'from' => 'demotext@example.com',
        'driver' => 'smtp', // mail 或 smtp
        'smtp_host' => 'demotext.example.com',
        'smtp_port' => 465,
        'smtp_encryption' => 'ssl', // ssl、starttls 或 none
        'smtp_username' => 'demotext@example.com',
        'smtp_password' => 'demotext',
    ],
];
