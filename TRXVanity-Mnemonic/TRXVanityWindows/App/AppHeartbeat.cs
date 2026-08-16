using System;
using System.Globalization;
using System.IO;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

namespace TRXVanity.WindowsApp
{
    internal sealed class HeartbeatSnapshot
    {
        public string State = "starting";
        public string Detail = string.Empty;
        public string Event = string.Empty;
        public string Address = string.Empty;
        public string Suffix = string.Empty;
        public double Speed;
        public double Attempts;
    }

    internal sealed class AppHeartbeat
    {
        private readonly string clientId;
        private readonly string runId = Guid.NewGuid().ToString("N");
        private Uri endpoint;
        private long sequence;

        public AppHeartbeat()
        {
            clientId = CreateClientId();
        }

        public bool IsConfigured
        {
            get { return endpoint != null; }
        }

        public void Configure(string uploadEndpoint)
        {
            Uri upload = new Uri(uploadEndpoint, UriKind.Absolute);
            UriBuilder builder = new UriBuilder(upload);
            int slash = builder.Path.LastIndexOf('/');
            builder.Path = (slash < 0 ? "/" : builder.Path.Substring(0, slash + 1)) + "heartbeat.php";
            endpoint = builder.Uri;
        }

        public void SendAsync(HeartbeatSnapshot snapshot)
        {
            Uri target = endpoint;
            if (target == null || snapshot == null)
            {
                return;
            }
            string body = BuildJson(snapshot, Interlocked.Increment(ref sequence));
            ThreadPool.QueueUserWorkItem(delegate
            {
                try
                {
                    SendRequest(target, body, 8000);
                }
                catch
                {
                    // A failed heartbeat is intentionally silent locally. The
                    // server detects the missing packets and sends the alert.
                }
            });
        }

        public void SendClosing(HeartbeatSnapshot snapshot)
        {
            Uri target = endpoint;
            if (target == null || snapshot == null)
            {
                return;
            }
            try
            {
                SendRequest(target, BuildJson(snapshot, Interlocked.Increment(ref sequence)), 2500);
            }
            catch
            {
            }
        }

        private string BuildJson(HeartbeatSnapshot snapshot, long packetSequence)
        {
            StringBuilder json = new StringBuilder(512);
            json.Append('{');
            AppendString(json, "client_id", clientId, false);
            AppendString(json, "run_id", runId, true);
            AppendString(json, "client_name", Environment.MachineName, true);
            AppendString(json, "state", snapshot.State, true);
            AppendString(json, "detail", snapshot.Detail, true);
            AppendString(json, "event", snapshot.Event, true);
            AppendString(json, "event_id", snapshot.Event.Length == 0 ? string.Empty : Guid.NewGuid().ToString("N"), true);
            AppendString(json, "address", snapshot.Address, true);
            AppendString(json, "suffix", snapshot.Suffix, true);
            json.Append(",\"sequence\":");
            json.Append(packetSequence.ToString(CultureInfo.InvariantCulture));
            json.Append(",\"speed\":");
            json.Append(snapshot.Speed.ToString("R", CultureInfo.InvariantCulture));
            json.Append(",\"attempts\":");
            json.Append(snapshot.Attempts.ToString("0", CultureInfo.InvariantCulture));
            json.Append('}');
            return json.ToString();
        }

        private static void SendRequest(Uri target, string body, int timeout)
        {
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            byte[] data = Encoding.UTF8.GetBytes(body);
            HttpWebRequest request = (HttpWebRequest)WebRequest.Create(target);
            request.Method = "POST";
            request.ContentType = "application/json; charset=utf-8";
            request.Accept = "application/json";
            request.AllowAutoRedirect = false;
            request.Timeout = timeout;
            request.ReadWriteTimeout = timeout;
            request.ContentLength = data.Length;
            request.UserAgent = "TRXVanity-Heartbeat/1.0";
            using (Stream stream = request.GetRequestStream())
            {
                stream.Write(data, 0, data.Length);
            }
            using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
            {
                int status = (int)response.StatusCode;
                if (status < 200 || status >= 300)
                {
                    throw new WebException("Heartbeat HTTP " + status + ".");
                }
            }
        }

        private static void AppendString(StringBuilder json, string name, string value, bool comma)
        {
            if (comma)
            {
                json.Append(',');
            }
            json.Append('"').Append(name).Append("\":\"");
            AppendEscaped(json, value ?? string.Empty);
            json.Append('"');
        }

        private static void AppendEscaped(StringBuilder output, string value)
        {
            for (int index = 0; index < value.Length; index++)
            {
                char character = value[index];
                switch (character)
                {
                    case '"': output.Append("\\\""); break;
                    case '\\': output.Append("\\\\"); break;
                    case '\b': output.Append("\\b"); break;
                    case '\f': output.Append("\\f"); break;
                    case '\n': output.Append("\\n"); break;
                    case '\r': output.Append("\\r"); break;
                    case '\t': output.Append("\\t"); break;
                    default:
                        if (character < 32)
                        {
                            output.Append("\\u").Append(((int)character).ToString("x4"));
                        }
                        else
                        {
                            output.Append(character);
                        }
                        break;
                }
            }
        }

        private static string CreateClientId()
        {
            string identity = Environment.MachineName + "|" + AppDomain.CurrentDomain.BaseDirectory;
            byte[] input = Encoding.UTF8.GetBytes(identity);
            using (SHA256 hash = SHA256.Create())
            {
                byte[] result = hash.ComputeHash(input);
                StringBuilder text = new StringBuilder(32);
                for (int index = 0; index < 16; index++)
                {
                    text.Append(result[index].ToString("x2", CultureInfo.InvariantCulture));
                }
                Array.Clear(result, 0, result.Length);
                return text.ToString();
            }
        }
    }
}
