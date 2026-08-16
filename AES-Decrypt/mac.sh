#!/bin/sh

# TRX Vanity .trxv decryptor for macOS.
# Plaintext is kept in memory and is never written to a file.

set -u
umask 077

AES_KEY=''
AUTH_KEY=''
PLAINTEXT=''
STTY_STATE=''

cleanup() {
    if [ -n "$STTY_STATE" ]; then
        stty "$STTY_STATE" 2>/dev/null || true
        STTY_STATE=''
    fi
    AES_KEY=''
    AUTH_KEY=''
    PLAINTEXT=''
}

fail() {
    printf '\n错误：%s\n' "$1" >&2
    exit 1
}

trap cleanup EXIT
trap 'exit 130' HUP INT TERM

OPENSSL_BIN=''
for candidate in \
    /opt/homebrew/opt/openssl@3/bin/openssl \
    /usr/local/opt/openssl@3/bin/openssl \
    /opt/homebrew/bin/openssl \
    /usr/local/bin/openssl \
    /usr/bin/openssl
do
    if [ -x "$candidate" ]; then
        OPENSSL_BIN=$candidate
        break
    fi
done
if [ -z "$OPENSSL_BIN" ]; then
    OPENSSL_BIN=$(command -v openssl 2>/dev/null || true)
fi
if [ -z "$OPENSSL_BIN" ]; then
    fail '没有找到 OpenSSL。请先执行 brew install openssl@3。'
fi

printf '\nTRX Vanity AES 备份解密（macOS）\n'
printf '明文不会写入磁盘；助记词会显示在当前终端中。\n\n'
printf '请把 .trxv AES 备份文件拖入此窗口，然后按回车：\n> '

# Deliberately omit read -r: Terminal represents a dragged path containing
# spaces with backslash escapes, which POSIX read decodes safely without eval.
# Keep the default IFS so Terminal's trailing separator is removed while
# spaces inside the path remain intact when reading into a single variable.
# shellcheck disable=SC2162
read BACKUP_FILE || fail '没有读到备份文件路径。'

case "$BACKUP_FILE" in
    \"*\") BACKUP_FILE=$(printf '%s' "$BACKUP_FILE" | sed 's/^"//;s/"$//') ;;
    \'*\') BACKUP_FILE=$(printf '%s' "$BACKUP_FILE" | sed "s/^'//;s/'$//") ;;
esac

if [ ! -f "$BACKUP_FILE" ]; then
    fail '找不到该文件，请重新运行脚本并再次拖入文件。'
fi

FILE_SIZE=$(wc -c < "$BACKUP_FILE" | tr -d '[:space:]')
case "$FILE_SIZE" in
    ''|*[!0-9]*) fail '无法读取备份文件大小。' ;;
esac
if [ "$FILE_SIZE" -lt 76 ]; then
    fail '文件太短，不是有效的 TRX Vanity AES 备份。'
fi

MAGIC=$(dd if="$BACKUP_FILE" bs=1 count=8 2>/dev/null)
if [ "$MAGIC" != 'TRXMNEMO' ]; then
    fail '文件头不正确，不是当前助记词版 TRX Vanity AES 备份。'
fi

LENGTH_BYTES=$(od -An -tu1 -j 24 -N 4 "$BACKUP_FILE" 2>/dev/null)
# od emits exactly four decimal bytes separated by whitespace. Splitting here
# is intentional, and its numeric output cannot expand to path globs.
# shellcheck disable=SC2086
set -- $LENGTH_BYTES
if [ "$#" -ne 4 ]; then
    fail '无法读取密文长度。'
fi
CIPHER_LENGTH=$(( $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 ))
EXPECTED_SIZE=$(( 28 + CIPHER_LENGTH + 32 ))
if [ "$CIPHER_LENGTH" -lt 16 ] \
    || [ $(( CIPHER_LENGTH % 16 )) -ne 0 ] \
    || [ "$FILE_SIZE" -ne "$EXPECTED_SIZE" ]; then
    fail '密文长度不正确，文件可能不完整或已损坏。'
fi

IV_HEX=$(od -An -tx1 -j 8 -N 16 "$BACKUP_FILE" 2>/dev/null | tr -d '[:space:]')
if [ "${#IV_HEX}" -ne 32 ]; then
    fail '无法读取 AES 初始化向量。'
fi

printf '\n请输入 64 位 HEX AES 密钥（输入不会显示），然后按回车：\n> '
STTY_STATE=$(stty -g 2>/dev/null || true)
if [ -n "$STTY_STATE" ]; then
    stty -echo
fi
IFS= read -r AES_KEY || fail '没有读到 AES 密钥。'
if [ -n "$STTY_STATE" ]; then
    stty "$STTY_STATE" 2>/dev/null || true
    STTY_STATE=''
fi
printf '\n'

if [ "${#AES_KEY}" -ne 64 ]; then
    fail 'AES 密钥必须正好是 64 位 HEX 字符。'
fi
case "$AES_KEY" in
    *[!0-9a-fA-F]*) fail 'AES 密钥只能包含 0-9、a-f 或 A-F。' ;;
esac

AUTH_LABEL='TRXVanity mnemonic backup authentication'
AUTH_KEY=$(
    printf '%s' "$AUTH_LABEL" \
        | "$OPENSSL_BIN" dgst -sha256 -mac HMAC \
            -macopt "hexkey:$AES_KEY" -binary 2>/dev/null \
        | od -An -tx1 \
        | tr -d '[:space:]'
)
if [ "${#AUTH_KEY}" -ne 64 ]; then
    fail '当前 OpenSSL 不支持所需的 HMAC 参数；请执行 brew install openssl@3。'
fi

TAG_OFFSET=$(( 28 + CIPHER_LENGTH ))
EXPECTED_TAG=$(od -An -tx1 -j "$TAG_OFFSET" -N 32 "$BACKUP_FILE" 2>/dev/null | tr -d '[:space:]')
CALCULATED_TAG=$(
    dd if="$BACKUP_FILE" bs=1 count="$TAG_OFFSET" 2>/dev/null \
        | "$OPENSSL_BIN" dgst -sha256 -mac HMAC \
            -macopt "hexkey:$AUTH_KEY" -binary 2>/dev/null \
        | od -An -tx1 \
        | tr -d '[:space:]'
)
if [ "${#EXPECTED_TAG}" -ne 64 ] \
    || [ "${#CALCULATED_TAG}" -ne 64 ] \
    || [ "$EXPECTED_TAG" != "$CALCULATED_TAG" ]; then
    fail 'AES 密钥错误，或者备份文件已被修改。'
fi

if ! PLAINTEXT=$(
    dd if="$BACKUP_FILE" bs=1 skip=28 count="$CIPHER_LENGTH" 2>/dev/null \
        | "$OPENSSL_BIN" enc -d -aes-256-cbc \
            -K "$AES_KEY" -iv "$IV_HEX" 2>/dev/null
); then
    fail 'AES 解密失败。'
fi

FORMAT=$(printf '%s\n' "$PLAINTEXT" | sed -n 's/.*"format"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n '1p')
ADDRESS=$(printf '%s\n' "$PLAINTEXT" | sed -n 's/.*"address"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n '1p')
MNEMONIC=$(printf '%s\n' "$PLAINTEXT" | sed -n 's/.*"mnemonic"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n '1p')

if [ "$FORMAT" != 'trx-vanity-mnemonic-backup' ] || [ -z "$MNEMONIC" ]; then
    fail '密文已通过认证，但其中不包含有效的助记词记录。'
fi
if ! printf '%s\n' "$MNEMONIC" | LC_ALL=C grep -Eq '^[a-z]+( [a-z]+){11}$'; then
    fail '解密记录中的助记词格式无效。'
fi
if [ -n "$ADDRESS" ] \
    && ! printf '%s\n' "$ADDRESS" | LC_ALL=C grep -Eq '^T[1-9A-HJ-NP-Za-km-z]{33}$'; then
    ADDRESS=''
fi

printf '\n解密成功。\n'
if [ -n "$ADDRESS" ]; then
    printf '地址：%s\n' "$ADDRESS"
fi
printf '\n助记词：\n%s\n\n' "$MNEMONIC"
printf '请勿截图、复制到聊天软件或保存到联网云盘；关闭窗口后仍应清理终端滚动记录。\n'
