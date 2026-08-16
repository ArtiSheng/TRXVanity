using System;
using System.IO;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;

namespace TRXVanity.WindowsApp
{
    internal static class BackupDecryptProgram
    {
        private static int Main(string[] args)
        {
            try
            {
                if (args.Length == 1 && args[0] == "--self-test")
                {
                    return SelfTest();
                }

                string input = args.Length > 0 ? args[0] : Prompt("加密文件路径: ");
                input = input.Trim().Trim('"');
                if (!File.Exists(input))
                {
                    throw new FileNotFoundException("找不到加密备份文件。", input);
                }
                if (new FileInfo(input).Length > 1024 * 1024)
                {
                    throw new InvalidDataException("加密备份文件过大。");
                }

                Console.Write("AES 密钥（输入时不显示）: ");
                string key = ReadHiddenLine();
                byte[] encrypted = File.ReadAllBytes(input);
                string json;
                try
                {
                    json = BackupCrypto.Decrypt(encrypted, key.Trim());
                }
                finally
                {
                    Array.Clear(encrypted, 0, encrypted.Length);
                    key = string.Empty;
                }

                string output = args.Length > 1
                    ? args[1]
                    : Path.Combine(
                        Path.GetDirectoryName(Path.GetFullPath(input)),
                        Path.GetFileNameWithoutExtension(input) + ".json");
                if (File.Exists(output))
                {
                    throw new IOException("输出文件已存在，未覆盖：" + output);
                }
                File.WriteAllText(output, json, new UTF8Encoding(false));
                RestrictFileToCurrentUser(output);
                Console.WriteLine("已解密到：" + Path.GetFullPath(output));
                Console.WriteLine("警告：该 JSON 包含明文私钥，请妥善保管。");
                return 0;
            }
            catch (Exception exception)
            {
                Console.Error.WriteLine("解密失败：" + exception.Message);
                return 1;
            }
        }

        private static int SelfTest()
        {
            const string key = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
            byte[] encrypted = BackupCrypto.Encrypt(
                "TMVQGm1qAQYVdetCeGRRkTWYYrLXuHK2HC",
                "0000000000000000000000000000000000000000000000000000000000000001",
                new DateTime(2026, 1, 2, 3, 4, 5, DateTimeKind.Utc),
                string.Empty,
                "TEST",
                key);
            string clear = BackupCrypto.Decrypt(encrypted, key);
            if (clear.IndexOf("TMVQGm1qAQYVdetCeGRRkTWYYrLXuHK2HC", StringComparison.Ordinal) < 0
                || clear.IndexOf("0000000000000000000000000000000000000000000000000000000000000001", StringComparison.Ordinal) < 0)
            {
                Console.Error.WriteLine("AES round-trip self-test failed.");
                return 1;
            }
            encrypted[encrypted.Length - 1] ^= 1;
            try
            {
                BackupCrypto.Decrypt(encrypted, key);
                Console.Error.WriteLine("AES tamper self-test failed.");
                return 1;
            }
            catch (System.Security.Cryptography.CryptographicException)
            {
            }
            finally
            {
                Array.Clear(encrypted, 0, encrypted.Length);
            }
            Console.WriteLine("AES backup self-test passed.");
            return 0;
        }

        private static string Prompt(string label)
        {
            Console.Write(label);
            return Console.ReadLine() ?? string.Empty;
        }

        private static string ReadHiddenLine()
        {
            if (Console.IsInputRedirected)
            {
                return Console.ReadLine() ?? string.Empty;
            }
            StringBuilder value = new StringBuilder(64);
            while (true)
            {
                ConsoleKeyInfo key = Console.ReadKey(true);
                if (key.Key == ConsoleKey.Enter)
                {
                    Console.WriteLine();
                    return value.ToString();
                }
                if (key.Key == ConsoleKey.Backspace)
                {
                    if (value.Length > 0)
                    {
                        value.Length--;
                    }
                    continue;
                }
                if (!char.IsControl(key.KeyChar) && value.Length < 128)
                {
                    value.Append(key.KeyChar);
                }
            }
        }

        private static void RestrictFileToCurrentUser(string path)
        {
            try
            {
                SecurityIdentifier user = WindowsIdentity.GetCurrent().User;
                FileSecurity security = new FileSecurity();
                security.SetOwner(user);
                security.SetAccessRuleProtection(true, false);
                security.AddAccessRule(new FileSystemAccessRule(
                    user,
                    FileSystemRights.FullControl,
                    AccessControlType.Allow));
                File.SetAccessControl(path, security);
            }
            catch
            {
            }
        }
    }
}
