using System;
using System.Drawing;
using System.Windows.Forms;

namespace TRXVanity.WindowsApp
{
    internal sealed class BackupSettingsForm : Form
    {
        private readonly TextBox endpointBox = new TextBox();
        private readonly TextBox keyBox = new TextBox();
        private readonly CheckBox showKeyBox = new CheckBox();

        public BackupSettingsForm(BackupOptions current)
        {
            Text = "AES 加密备份设置";
            StartPosition = FormStartPosition.CenterParent;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            ShowInTaskbar = false;
            ClientSize = new Size(650, 352);
            Font = new Font("Microsoft YaHei UI", 9F);

            TableLayoutPanel layout = new TableLayoutPanel();
            layout.Dock = DockStyle.Fill;
            layout.Padding = new Padding(22, 18, 22, 18);
            layout.ColumnCount = 1;
            layout.RowCount = 8;
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 54F));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 25F));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 38F));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 25F));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 38F));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 35F));
            layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 42F));

            Label warning = NewLabel(
                "AES 密钥只保留在本次运行的内存中，不会保存或上传。请自行离线备份密钥，丢失后服务器上的文件无法恢复。",
                Color.FromArgb(180, 60, 40));
            layout.Controls.Add(warning, 0, 0);

            layout.Controls.Add(NewLabel("PHP 上传地址（完整 upload.php 地址）", Color.FromArgb(70, 78, 73)), 0, 1);
            endpointBox.Text = current.Endpoint;
            endpointBox.Dock = DockStyle.Fill;
            endpointBox.Font = new Font("Consolas", 9.5F);
            layout.Controls.Add(endpointBox, 0, 2);

            layout.Controls.Add(NewLabel("AES-256 密钥（64 位 HEX）", Color.FromArgb(70, 78, 73)), 0, 3);
            keyBox.Text = current.KeyHex;
            keyBox.Dock = DockStyle.Fill;
            keyBox.Font = new Font("Consolas", 10F);
            keyBox.UseSystemPasswordChar = true;
            keyBox.MaxLength = 64;
            layout.Controls.Add(keyBox, 0, 4);

            showKeyBox.Text = "显示 AES 密钥";
            showKeyBox.Dock = DockStyle.Fill;
            showKeyBox.CheckedChanged += delegate
            {
                keyBox.UseSystemPasswordChar = !showKeyBox.Checked;
            };
            layout.Controls.Add(showKeyBox, 0, 5);

            Label note = NewLabel(
                "应用后自动启用密文上传和状态心跳；心跳不含助记词或 AES 密钥。关闭程序会清空设置。",
                Color.FromArgb(100, 110, 104));
            layout.Controls.Add(note, 0, 6);

            FlowLayoutPanel buttons = new FlowLayoutPanel();
            buttons.Dock = DockStyle.Fill;
            buttons.FlowDirection = FlowDirection.RightToLeft;
            Button save = new Button();
            save.Text = "应用";
            save.Width = 92;
            save.Height = 32;
            save.Click += SaveClick;
            Button cancel = new Button();
            cancel.Text = "取消";
            cancel.Width = 92;
            cancel.Height = 32;
            cancel.DialogResult = DialogResult.Cancel;
            buttons.Controls.Add(save);
            buttons.Controls.Add(cancel);
            layout.Controls.Add(buttons, 0, 7);

            AcceptButton = save;
            CancelButton = cancel;
            Controls.Add(layout);
        }

        public BackupOptions Options { get; private set; }

        private void SaveClick(object sender, EventArgs args)
        {
            BackupOptions options = new BackupOptions();
            options.Enabled = true;
            Uri endpoint;
            string error;
            if (!BackupUploader.TryValidateEndpoint(endpointBox.Text.Trim(), out endpoint, out error))
            {
                MessageBox.Show(this, error, "上传地址", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                endpointBox.Focus();
                return;
            }
            if (!BackupCrypto.IsValidKey(keyBox.Text.Trim()))
            {
                MessageBox.Show(
                    this,
                    "AES 密钥必须正好是 64 位十六进制字符（0-9、A-F）。",
                    "AES 密钥",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Warning);
                keyBox.Focus();
                return;
            }
            options.Endpoint = endpoint.AbsoluteUri;
            options.KeyHex = keyBox.Text.Trim();
            Options = options;
            DialogResult = DialogResult.OK;
            Close();
        }

        private static Label NewLabel(string text, Color color)
        {
            Label label = new Label();
            label.Text = text;
            label.ForeColor = color;
            label.Dock = DockStyle.Fill;
            label.TextAlign = ContentAlignment.MiddleLeft;
            return label;
        }
    }
}
