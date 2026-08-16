using System;
using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace TRXVanity.WindowsApp
{
    internal static class BackupCrypto
    {
        private static readonly byte[] Magic = Encoding.ASCII.GetBytes("TRXVAE01");
        private static readonly byte[] AuthenticationLabel =
            Encoding.ASCII.GetBytes("TRXVanity backup authentication v1");
        private const int HeaderLength = 8 + 16 + 4;
        private const int TagLength = 32;

        public static bool IsValidKey(string keyHex)
        {
            byte[] key;
            if (!TryParseKey(keyHex, out key))
            {
                return false;
            }
            Array.Clear(key, 0, key.Length);
            return true;
        }

        public static byte[] Encrypt(
            string address,
            string privateKey,
            DateTime createdUtc,
            string prefix,
            string suffix,
            string keyHex)
        {
            byte[] key;
            if (!TryParseKey(keyHex, out key))
            {
                throw new ArgumentException("AES 密钥必须是 64 位十六进制字符。", "keyHex");
            }

            byte[] clear = Encoding.UTF8.GetBytes(BuildJson(
                address,
                privateKey,
                createdUtc,
                prefix,
                suffix));
            byte[] iv = new byte[16];
            byte[] cipher = null;
            byte[] authenticationKey = null;
            try
            {
                using (RandomNumberGenerator random = RandomNumberGenerator.Create())
                {
                    random.GetBytes(iv);
                }
                using (Aes aes = Aes.Create())
                {
                    aes.KeySize = 256;
                    aes.BlockSize = 128;
                    aes.Mode = CipherMode.CBC;
                    aes.Padding = PaddingMode.PKCS7;
                    aes.Key = key;
                    aes.IV = iv;
                    using (ICryptoTransform encryptor = aes.CreateEncryptor())
                    {
                        cipher = encryptor.TransformFinalBlock(clear, 0, clear.Length);
                    }
                }

                byte[] envelope = new byte[HeaderLength + cipher.Length + TagLength];
                Buffer.BlockCopy(Magic, 0, envelope, 0, Magic.Length);
                Buffer.BlockCopy(iv, 0, envelope, Magic.Length, iv.Length);
                WriteUInt32BigEndian(envelope, Magic.Length + iv.Length, (uint)cipher.Length);
                Buffer.BlockCopy(cipher, 0, envelope, HeaderLength, cipher.Length);

                authenticationKey = DeriveAuthenticationKey(key);
                byte[] tag;
                using (HMACSHA256 hmac = new HMACSHA256(authenticationKey))
                using (MemoryStream stream = new MemoryStream(envelope, 0, HeaderLength + cipher.Length, false))
                {
                    tag = hmac.ComputeHash(stream);
                }
                Buffer.BlockCopy(tag, 0, envelope, HeaderLength + cipher.Length, tag.Length);
                Array.Clear(tag, 0, tag.Length);
                return envelope;
            }
            finally
            {
                Array.Clear(key, 0, key.Length);
                Array.Clear(clear, 0, clear.Length);
                Array.Clear(iv, 0, iv.Length);
                if (cipher != null)
                {
                    Array.Clear(cipher, 0, cipher.Length);
                }
                if (authenticationKey != null)
                {
                    Array.Clear(authenticationKey, 0, authenticationKey.Length);
                }
            }
        }

        public static string Decrypt(byte[] envelope, string keyHex)
        {
            if (envelope == null || envelope.Length < HeaderLength + 16 + TagLength)
            {
                throw new InvalidDataException("不是有效的 TRX Vanity 加密备份文件。");
            }
            for (int index = 0; index < Magic.Length; index++)
            {
                if (envelope[index] != Magic[index])
                {
                    throw new InvalidDataException("不支持的加密备份文件格式。");
                }
            }

            uint cipherLengthValue = ReadUInt32BigEndian(envelope, Magic.Length + 16);
            if (cipherLengthValue > int.MaxValue)
            {
                throw new InvalidDataException("加密备份文件长度无效。");
            }
            int cipherLength = (int)cipherLengthValue;
            if (cipherLength < 16
                || cipherLength % 16 != 0
                || envelope.Length != HeaderLength + cipherLength + TagLength)
            {
                throw new InvalidDataException("加密备份文件长度无效。");
            }

            byte[] key;
            if (!TryParseKey(keyHex, out key))
            {
                throw new ArgumentException("AES 密钥必须是 64 位十六进制字符。", "keyHex");
            }
            byte[] authenticationKey = null;
            byte[] expectedTag = null;
            byte[] cipher = new byte[cipherLength];
            byte[] iv = new byte[16];
            byte[] clear = null;
            try
            {
                Buffer.BlockCopy(envelope, Magic.Length, iv, 0, iv.Length);
                Buffer.BlockCopy(envelope, HeaderLength, cipher, 0, cipher.Length);
                authenticationKey = DeriveAuthenticationKey(key);
                using (HMACSHA256 hmac = new HMACSHA256(authenticationKey))
                using (MemoryStream stream = new MemoryStream(envelope, 0, HeaderLength + cipherLength, false))
                {
                    expectedTag = hmac.ComputeHash(stream);
                }
                int difference = 0;
                int tagOffset = HeaderLength + cipherLength;
                for (int index = 0; index < TagLength; index++)
                {
                    difference |= expectedTag[index] ^ envelope[tagOffset + index];
                }
                if (difference != 0)
                {
                    throw new CryptographicException("AES 密钥错误或文件已被修改。");
                }

                using (Aes aes = Aes.Create())
                {
                    aes.KeySize = 256;
                    aes.BlockSize = 128;
                    aes.Mode = CipherMode.CBC;
                    aes.Padding = PaddingMode.PKCS7;
                    aes.Key = key;
                    aes.IV = iv;
                    using (ICryptoTransform decryptor = aes.CreateDecryptor())
                    {
                        clear = decryptor.TransformFinalBlock(cipher, 0, cipher.Length);
                    }
                }
                return Encoding.UTF8.GetString(clear);
            }
            finally
            {
                Array.Clear(key, 0, key.Length);
                Array.Clear(cipher, 0, cipher.Length);
                Array.Clear(iv, 0, iv.Length);
                if (authenticationKey != null)
                {
                    Array.Clear(authenticationKey, 0, authenticationKey.Length);
                }
                if (expectedTag != null)
                {
                    Array.Clear(expectedTag, 0, expectedTag.Length);
                }
                if (clear != null)
                {
                    Array.Clear(clear, 0, clear.Length);
                }
            }
        }

        private static byte[] DeriveAuthenticationKey(byte[] key)
        {
            using (HMACSHA256 hmac = new HMACSHA256(key))
            {
                return hmac.ComputeHash(AuthenticationLabel);
            }
        }

        private static bool TryParseKey(string value, out byte[] key)
        {
            key = null;
            if (value == null || value.Length != 64)
            {
                return false;
            }
            byte[] parsed = new byte[32];
            for (int index = 0; index < parsed.Length; index++)
            {
                int high = HexValue(value[index * 2]);
                int low = HexValue(value[index * 2 + 1]);
                if (high < 0 || low < 0)
                {
                    Array.Clear(parsed, 0, parsed.Length);
                    return false;
                }
                parsed[index] = (byte)((high << 4) | low);
            }
            key = parsed;
            return true;
        }

        private static int HexValue(char value)
        {
            if (value >= '0' && value <= '9')
            {
                return value - '0';
            }
            if (value >= 'a' && value <= 'f')
            {
                return value - 'a' + 10;
            }
            if (value >= 'A' && value <= 'F')
            {
                return value - 'A' + 10;
            }
            return -1;
        }

        private static void WriteUInt32BigEndian(byte[] output, int offset, uint value)
        {
            output[offset] = (byte)(value >> 24);
            output[offset + 1] = (byte)(value >> 16);
            output[offset + 2] = (byte)(value >> 8);
            output[offset + 3] = (byte)value;
        }

        private static uint ReadUInt32BigEndian(byte[] input, int offset)
        {
            return ((uint)input[offset] << 24)
                | ((uint)input[offset + 1] << 16)
                | ((uint)input[offset + 2] << 8)
                | input[offset + 3];
        }

        private static string BuildJson(
            string address,
            string privateKey,
            DateTime createdUtc,
            string prefix,
            string suffix)
        {
            StringBuilder result = new StringBuilder(320);
            result.Append("{\r\n  \"format\": \"trx-vanity-aes-backup\",\r\n  \"version\": 1,\r\n");
            AppendJsonProperty(result, "address", address, true);
            AppendJsonProperty(result, "privateKey", privateKey, true);
            AppendJsonProperty(
                result,
                "createdUtc",
                createdUtc.ToUniversalTime().ToString("o", CultureInfo.InvariantCulture),
                true);
            AppendJsonProperty(result, "prefix", prefix, true);
            AppendJsonProperty(result, "suffix", suffix, false);
            result.Append("}\r\n");
            return result.ToString();
        }

        private static void AppendJsonProperty(
            StringBuilder output,
            string name,
            string value,
            bool comma)
        {
            output.Append("  ");
            AppendJsonString(output, name);
            output.Append(": ");
            AppendJsonString(output, value ?? string.Empty);
            output.Append(comma ? ",\r\n" : "\r\n");
        }

        private static void AppendJsonString(StringBuilder output, string value)
        {
            output.Append('"');
            for (int index = 0; index < value.Length; index++)
            {
                char current = value[index];
                switch (current)
                {
                    case '"': output.Append("\\\""); break;
                    case '\\': output.Append("\\\\"); break;
                    case '\b': output.Append("\\b"); break;
                    case '\f': output.Append("\\f"); break;
                    case '\n': output.Append("\\n"); break;
                    case '\r': output.Append("\\r"); break;
                    case '\t': output.Append("\\t"); break;
                    default:
                        if (current < 32)
                        {
                            output.Append("\\u");
                            output.Append(((int)current).ToString("x4", CultureInfo.InvariantCulture));
                        }
                        else
                        {
                            output.Append(current);
                        }
                        break;
                }
            }
            output.Append('"');
        }
    }
}
