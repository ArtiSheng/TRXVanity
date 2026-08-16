using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace TRXVanity.WindowsApp
{
    internal sealed class HistoryRecord
    {
        public Guid Id;
        public string Address;
        public string Mnemonic;
        public string DerivationPath;
        public DateTime CreatedUtc;
        public string Prefix;
        public string Suffix;
    }

    internal sealed class HistoryStore
    {
        private const string Format = "TRXVanityMnemonicHistory";
        private static readonly byte[] Entropy = Encoding.UTF8.GetBytes(
            "TRXVanity.Windows.MnemonicHistory.local-only");

        private readonly string directory;
        private readonly string path;

        public HistoryStore()
        {
            directory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "TRXVanity");
            path = Path.Combine(directory, "mnemonic-history.dat");
        }

        public List<HistoryRecord> Load()
        {
            List<HistoryRecord> records = new List<HistoryRecord>();
            if (!File.Exists(path))
            {
                return records;
            }

            byte[] encrypted = File.ReadAllBytes(path);
            byte[] clear = null;
            try
            {
                clear = ProtectedData.Unprotect(
                    encrypted,
                    Entropy,
                    DataProtectionScope.CurrentUser);
                using (MemoryStream stream = new MemoryStream(clear, false))
                using (BinaryReader reader = new BinaryReader(stream, Encoding.UTF8))
                {
                    if (!string.Equals(reader.ReadString(), Format, StringComparison.Ordinal))
                    {
                        throw new InvalidDataException("不是当前助记词历史记录格式。");
                    }

                    int count = reader.ReadInt32();
                    if (count < 0 || count > 100000)
                    {
                        throw new InvalidDataException("历史记录数量无效。");
                    }

                    for (int index = 0; index < count; index++)
                    {
                        HistoryRecord record = new HistoryRecord();
                        byte[] identifier = reader.ReadBytes(16);
                        if (identifier.Length != 16)
                        {
                            throw new EndOfStreamException("历史记录不完整。");
                        }
                        record.Id = new Guid(identifier);
                        record.Address = reader.ReadString();
                        record.Mnemonic = reader.ReadString();
                        record.DerivationPath = reader.ReadString();
                        record.CreatedUtc = new DateTime(reader.ReadInt64(), DateTimeKind.Utc);
                        record.Prefix = reader.ReadString();
                        record.Suffix = reader.ReadString();
                        records.Add(record);
                    }

                    if (stream.Position != stream.Length)
                    {
                        throw new InvalidDataException("历史记录包含多余数据。");
                    }
                }
            }
            finally
            {
                Array.Clear(encrypted, 0, encrypted.Length);
                if (clear != null)
                {
                    Array.Clear(clear, 0, clear.Length);
                }
            }

            records.Sort(delegate(HistoryRecord left, HistoryRecord right)
            {
                return right.CreatedUtc.CompareTo(left.CreatedUtc);
            });
            return records;
        }

        public void Save(IList<HistoryRecord> records)
        {
            Directory.CreateDirectory(directory);
            byte[] clear;
            using (MemoryStream stream = new MemoryStream())
            {
                using (BinaryWriter writer = new BinaryWriter(stream, Encoding.UTF8, true))
                {
                    writer.Write(Format);
                    writer.Write(records.Count);
                    for (int index = 0; index < records.Count; index++)
                    {
                        HistoryRecord record = records[index];
                        writer.Write(record.Id.ToByteArray());
                        writer.Write(record.Address ?? string.Empty);
                        writer.Write(record.Mnemonic ?? string.Empty);
                        writer.Write(record.DerivationPath ?? string.Empty);
                        writer.Write(record.CreatedUtc.ToUniversalTime().Ticks);
                        writer.Write(record.Prefix ?? string.Empty);
                        writer.Write(record.Suffix ?? string.Empty);
                    }
                }
                clear = stream.ToArray();
            }

            byte[] encrypted = null;
            string temporary = path + ".new";
            try
            {
                encrypted = ProtectedData.Protect(
                    clear,
                    Entropy,
                    DataProtectionScope.CurrentUser);
                File.WriteAllBytes(temporary, encrypted);
                if (File.Exists(path))
                {
                    File.Replace(temporary, path, null);
                }
                else
                {
                    File.Move(temporary, path);
                }
            }
            finally
            {
                Array.Clear(clear, 0, clear.Length);
                if (encrypted != null)
                {
                    Array.Clear(encrypted, 0, encrypted.Length);
                }
                if (File.Exists(temporary))
                {
                    File.Delete(temporary);
                }
            }
        }
    }
}
