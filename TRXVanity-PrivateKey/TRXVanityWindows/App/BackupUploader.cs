using System;
using System.IO;
using System.Net;
using System.Text;
using System.Threading;

namespace TRXVanity.WindowsApp
{
    internal sealed class BackupOptions
    {
        public bool Enabled;
        public string Endpoint = string.Empty;
        public string KeyHex = string.Empty;

        public BackupOptions Copy()
        {
            BackupOptions copy = new BackupOptions();
            copy.Enabled = Enabled;
            copy.Endpoint = Endpoint;
            copy.KeyHex = KeyHex;
            return copy;
        }

        public void Clear()
        {
            Enabled = false;
            Endpoint = string.Empty;
            KeyHex = string.Empty;
        }
    }

    internal sealed class BackupUploadResult
    {
        public bool Success;
        public string Message;
    }

    internal static class BackupUploader
    {
        public static bool TryValidateEndpoint(string value, out Uri endpoint, out string error)
        {
            endpoint = null;
            error = string.Empty;
            Uri parsed;
            if (!Uri.TryCreate(value, UriKind.Absolute, out parsed))
            {
                error = "请输入完整的上传地址。";
                return false;
            }
            bool secure = string.Equals(parsed.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase);
            bool localHttp = string.Equals(parsed.Scheme, Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase)
                && parsed.IsLoopback;
            if (!secure && !localHttp)
            {
                error = "上传地址必须使用 HTTPS；仅本机测试可使用 HTTP。";
                return false;
            }
            if (parsed.UserInfo.Length != 0 || parsed.Fragment.Length != 0)
            {
                error = "上传地址不能包含用户名、密码或片段。";
                return false;
            }
            endpoint = parsed;
            return true;
        }

        public static void UploadAsync(
            string endpointValue,
            byte[] encryptedFile,
            Action<BackupUploadResult> completed)
        {
            ThreadPool.QueueUserWorkItem(delegate
            {
                BackupUploadResult result = new BackupUploadResult();
                try
                {
                    Uri endpoint;
                    string validationError;
                    if (!TryValidateEndpoint(endpointValue, out endpoint, out validationError))
                    {
                        throw new InvalidOperationException(validationError);
                    }
                    // csc.exe from .NET Framework 4.x targets legacy network
                    // defaults even when the runtime is 4.8.  Explicitly add
                    // TLS 1.2 so modern HTTPS-only servers can negotiate.
                    ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
                    HttpWebRequest request = (HttpWebRequest)WebRequest.Create(endpoint);
                    request.Method = "POST";
                    request.ContentType = "application/octet-stream";
                    request.Accept = "application/json";
                    request.AllowAutoRedirect = false;
                    request.Timeout = 20000;
                    request.ReadWriteTimeout = 20000;
                    request.ContentLength = encryptedFile.Length;
                    request.UserAgent = "TRXVanity-EncryptedBackup/1.0";
                    using (Stream requestStream = request.GetRequestStream())
                    {
                        requestStream.Write(encryptedFile, 0, encryptedFile.Length);
                    }
                    using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
                    {
                        int status = (int)response.StatusCode;
                        if (status < 200 || status >= 300)
                        {
                            throw new WebException("服务器返回 HTTP " + status + "。");
                        }
                        result.Success = true;
                        result.Message = "密文备份已上传";
                    }
                }
                catch (WebException exception)
                {
                    result.Success = false;
                    result.Message = DescribeWebException(exception);
                }
                catch (Exception exception)
                {
                    result.Success = false;
                    result.Message = exception.Message;
                }
                finally
                {
                    Array.Clear(encryptedFile, 0, encryptedFile.Length);
                }

                if (completed != null)
                {
                    completed(result);
                }
            });
        }

        private static string DescribeWebException(WebException exception)
        {
            HttpWebResponse response = exception.Response as HttpWebResponse;
            if (response == null)
            {
                return exception.Message;
            }
            using (response)
            {
                string detail = string.Empty;
                try
                {
                    using (Stream stream = response.GetResponseStream())
                    using (StreamReader reader = new StreamReader(stream, Encoding.UTF8))
                    {
                        char[] buffer = new char[512];
                        int count = reader.Read(buffer, 0, buffer.Length);
                        detail = new string(buffer, 0, count).Trim();
                    }
                }
                catch
                {
                }
                return "服务器返回 HTTP " + (int)response.StatusCode
                    + (detail.Length == 0 ? "。" : "：" + detail);
            }
        }
    }
}
