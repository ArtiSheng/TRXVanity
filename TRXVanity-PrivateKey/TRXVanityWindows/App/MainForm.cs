using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

namespace TRXVanity.WindowsApp
{
    internal sealed class MainForm : Form
    {
        private static readonly Color Canvas = Color.FromArgb(247, 244, 238);
        private static readonly Color Card = Color.FromArgb(255, 255, 253);
        private static readonly Color Ink = Color.FromArgb(24, 34, 29);
        private static readonly Color Muted = Color.FromArgb(101, 113, 105);
        private static readonly Color Accent = Color.FromArgb(232, 75, 48);
        private static readonly Color Success = Color.FromArgb(34, 139, 94);
        private static readonly Color Line = Color.FromArgb(221, 218, 210);
        private const string Base58Alphabet =
            "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
        private static float layoutScale = 1F;

        private readonly HistoryStore historyStore = new HistoryStore();
        private readonly List<HistoryRecord> history = new List<HistoryRecord>();
        private readonly StringBuilder engineErrorLog = new StringBuilder();
        private readonly AppHeartbeat appHeartbeat = new AppHeartbeat();

        private TextBox suffixText;
        private Label difficultyLabel;
        private Button startButton;

        private Label gpuLabel;
        private Label engineStatusLabel;
        private ProgressBar engineProgress;
        private Label attemptsValue;
        private Label speedValue;
        private Label elapsedValue;
        private Label estimatedTotalValue;
        private Label estimatedRemainingValue;
        private Label scanPercentValue;
        private ProgressBar scanProgress;

        private TextBox addressText;
        private TextBox privateKeyText;
        private Button revealButton;
        private Button copyAddressButton;
        private Button copyPrivateButton;
        private Button backupSettingsButton;

        private DataGridView historyGrid;
        private Label historyCountLabel;

        private BackupOptions backupOptions = new BackupOptions();

        private Process engineProcess;
        private StreamWriter engineInput;
        private bool engineReady;
        private bool running;
        private double currentSpeed;
        private double currentAttempts;
        private string activeSuffix = string.Empty;
        private string heartbeatState = "starting";
        private string heartbeatDetail = "应用正在启动";
        private bool closingApplication;

        private readonly Timer clipboardTimer = new Timer();
        private readonly Timer heartbeatTimer = new Timer();
        private string clipboardValue = string.Empty;

        public MainForm()
        {
            // Font point sizes already follow monitor DPI, while pixel-based
            // programmatic WinForms layouts do not. Scale every authored
            // 96-DPI dimension explicitly so rows cannot clip at 125–200%.
            layoutScale = Math.Max(1F, GetDpiForSystem() / 96F);
            AutoScaleMode = AutoScaleMode.None;
            Text = "TRX Vanity — Windows GPU";
            StartPosition = FormStartPosition.CenterScreen;
            Rectangle workArea = Screen.PrimaryScreen.WorkingArea;
            Size targetSize = ScaledSize(1220, 900);
            // The available desktop is a hard upper bound.  In particular, do
            // not use a DPI-scaled minimum as the other side of Math.Max here:
            // at 250-300% that can make the form larger than a 1080p desktop.
            int horizontalInset = Math.Min(Scaled(32), Math.Max(0, workArea.Width / 12));
            int verticalInset = Math.Min(Scaled(32), Math.Max(0, workArea.Height / 12));
            targetSize.Width = Math.Min(targetSize.Width, Math.Max(1, workArea.Width - horizontalInset));
            targetSize.Height = Math.Min(targetSize.Height, Math.Max(1, workArea.Height - verticalInset));
            MinimumSize = new Size(
                Math.Min(Scaled(1080), targetSize.Width),
                Math.Min(Scaled(760), targetSize.Height));
            Size = targetSize;
            BackColor = Canvas;
            ForeColor = Ink;
            Font = new Font("Microsoft YaHei UI", 9F, FontStyle.Regular, GraphicsUnit.Point);
            AutoScroll = true;
            AutoScrollMinSize = ScaledSize(1040, 770);
            KeyPreview = true;

            BuildInterface();
            LoadHistory();
            UpdateDifficulty();

            clipboardTimer.Interval = 30000;
            clipboardTimer.Tick += ClipboardTimerTick;
            heartbeatTimer.Interval = 15000;
            heartbeatTimer.Tick += delegate { SendHeartbeat(string.Empty, string.Empty, string.Empty); };
            Shown += delegate { StartEngine(); };
            FormClosing += MainFormClosing;
            KeyDown += MainFormKeyDown;
        }

        private void BuildInterface()
        {
            TableLayoutPanel root = new TableLayoutPanel();
            root.Dock = DockStyle.Fill;
            root.BackColor = Canvas;
            root.ColumnCount = 1;
            root.RowCount = 3;
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, Scaled(78F)));
            root.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, Scaled(34F)));
            // Keep the authored layout width/height when the physical desktop
            // is too small at high DPI.  The form then scrolls instead of
            // squeezing table cells until labels overlap or get clipped.
            root.MinimumSize = ScaledSize(1040, 770);
            Controls.Add(root);

            root.Controls.Add(BuildHeader(), 0, 0);
            root.Controls.Add(BuildWorkspace(), 0, 1);

            Label footer = MakeLabel(
                "GPU 只接收公开曲线点 · CPU/libsecp256k1 独立复验 · 本机历史使用 DPAPI · 可选用户密钥 AES 备份",
                9F,
                FontStyle.Regular,
                Muted);
            footer.Dock = DockStyle.Fill;
            footer.TextAlign = ContentAlignment.MiddleCenter;
            root.Controls.Add(footer, 0, 2);
        }

        private Control BuildHeader()
        {
            Panel header = new Panel();
            header.Dock = DockStyle.Fill;
            header.BackColor = Canvas;
            header.Padding = ScaledPadding(26, 14, 26, 10);

            Label logo = MakeLabel("T", 20F, FontStyle.Bold, Color.White);
            logo.BackColor = Accent;
            logo.TextAlign = ContentAlignment.MiddleCenter;
            logo.Dock = DockStyle.None;
            logo.Size = ScaledSize(46, 46);
            logo.Location = ScaledPoint(26, 15);
            header.Controls.Add(logo);

            Label title = MakeLabel("TRX Vanity", 16F, FontStyle.Bold, Ink);
            title.AutoSize = true;
            title.Dock = DockStyle.None;
            title.Location = ScaledPoint(84, 16);
            header.Controls.Add(title);

            Label subtitle = MakeLabel("GPU 高速离线靓号生成器", 9F, FontStyle.Regular, Muted);
            subtitle.AutoSize = true;
            subtitle.Dock = DockStyle.None;
            subtitle.Location = ScaledPoint(85, 43);
            header.Controls.Add(subtitle);

            FlowLayoutPanel pills = new FlowLayoutPanel();
            pills.AutoSize = true;
            pills.WrapContents = false;
            pills.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            pills.Location = ScaledPoint(760, 22);
            pills.Controls.Add(MakePill("100% 本地计算", Success));
            pills.Controls.Add(MakePill("OpenCL GPU", Accent));
            pills.Controls.Add(MakePill("可选 AES 密文备份", Ink));
            header.Controls.Add(pills);
            header.Resize += delegate
            {
                pills.Left = Math.Max(Scaled(360), header.ClientSize.Width - pills.Width - Scaled(26));
            };

            Panel separator = new Panel();
            separator.Height = Scaled(1);
            separator.BackColor = Line;
            separator.Dock = DockStyle.Bottom;
            header.Controls.Add(separator);
            return header;
        }

        private Control BuildWorkspace()
        {
            TableLayoutPanel workspace = new TableLayoutPanel();
            workspace.Dock = DockStyle.Fill;
            workspace.Padding = ScaledPadding(24, 10, 24, 8);
            workspace.BackColor = Canvas;
            workspace.ColumnCount = 1;
            workspace.RowCount = 2;
            workspace.RowStyles.Add(new RowStyle(SizeType.Absolute, Scaled(510F)));
            workspace.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));

            TableLayoutPanel top = new TableLayoutPanel();
            top.Dock = DockStyle.Fill;
            top.ColumnCount = 2;
            top.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 39F));
            top.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 61F));
            top.Padding = ScaledPadding(0, 0, 0, 12);
            top.Controls.Add(BuildConfigurationCard(), 0, 0);
            top.Controls.Add(BuildRightColumn(), 1, 0);
            top.GetControlFromPosition(0, 0).Margin = ScaledPadding(0, 0, 8, 0);
            top.GetControlFromPosition(1, 0).Margin = ScaledPadding(8, 0, 0, 0);

            workspace.Controls.Add(top, 0, 0);
            workspace.Controls.Add(BuildHistoryCard(), 0, 1);
            return workspace;
        }

        private Control BuildConfigurationCard()
        {
            CardPanel card = NewCard();
            TableLayoutPanel content = NewCardLayout(7);
            content.RowStyles.Add(new RowStyle(SizeType.Absolute, Scaled(34F)));
            content.RowStyles.Add(new RowStyle(SizeType.Absolute, Scaled(42F)));
            content.RowStyles.Add(new RowStyle(SizeType.Absolute, Scaled(86F)));
            content.RowStyles.Add(new RowStyle(SizeType.Absolute, Scaled(45F)));
            content.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
            content.RowStyles.Add(new RowStyle(SizeType.Absolute, Scaled(48F)));
            content.RowStyles.Add(new RowStyle(SizeType.Absolute, Scaled(28F)));

            content.Controls.Add(MakeLabel("匹配条件", 14F, FontStyle.Bold, Ink), 0, 0);
            content.Controls.Add(MakeLabel(
                "TRON 主网地址前缀固定为 T，仅可自定义地址后缀。",
                9F,
                FontStyle.Regular,
                Muted), 0, 1);

            suffixText = NewPatternTextBox("9999");
            content.Controls.Add(BuildPatternRow("自定义后缀", suffixText), 0, 2);

            difficultyLabel = MakeLabel(string.Empty, 9F, FontStyle.Bold, Ink);
            difficultyLabel.Dock = DockStyle.Fill;
            difficultyLabel.TextAlign = ContentAlignment.MiddleLeft;
            content.Controls.Add(difficultyLabel, 0, 3);

            Label warning = MakeLabel(
                "每增加 1 位，理论搜索量约增加 58 倍。生成后请先用小额资产验证导入与转账流程。",
                8.5F,
                FontStyle.Regular,
                Muted);
            warning.Dock = DockStyle.Fill;
            warning.Padding = ScaledPadding(0, 8, 0, 0);
            content.Controls.Add(warning, 0, 4);

            startButton = NewButton("GPU 正在初始化…", Accent, Color.White);
            startButton.Enabled = false;
            startButton.Dock = DockStyle.Fill;
            startButton.Click += StartButtonClick;
            content.Controls.Add(startButton, 0, 5);

            Label shortcut = MakeLabel("快捷键：Ctrl + Enter 开始 / 停止", 8.5F, FontStyle.Regular, Muted);
            shortcut.Dock = DockStyle.Fill;
            shortcut.TextAlign = ContentAlignment.MiddleCenter;
            content.Controls.Add(shortcut, 0, 6);

            suffixText.TextChanged += PatternTextChanged;
            card.Controls.Add(content);
            return card;
        }

        private Control BuildPatternRow(string title, TextBox textBox)
        {
            TableLayoutPanel row = new TableLayoutPanel();
            row.Dock = DockStyle.Fill;
            row.ColumnCount = 2;
            row.RowCount = 2;
            row.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 48F));
            row.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 52F));
            row.RowStyles.Add(new RowStyle(SizeType.Absolute, Scaled(29F)));
            row.RowStyles.Add(new RowStyle(SizeType.Absolute, Scaled(38F)));
            Label titleLabel = MakeLabel(title, 9F, FontStyle.Bold, Ink);
            titleLabel.Dock = DockStyle.Fill;
            titleLabel.TextAlign = ContentAlignment.MiddleLeft;
            row.Controls.Add(titleLabel, 0, 0);
            row.SetColumnSpan(titleLabel, 2);
            Label hint = MakeLabel("1–10 位", 8.5F, FontStyle.Regular, Muted);
            hint.Dock = DockStyle.Fill;
            hint.TextAlign = ContentAlignment.MiddleLeft;
            row.Controls.Add(hint, 0, 1);
            textBox.Dock = DockStyle.Fill;
            row.Controls.Add(textBox, 1, 1);
            return row;
        }

        private Control BuildRightColumn()
        {
            TableLayoutPanel right = new TableLayoutPanel();
            right.Dock = DockStyle.Fill;
            right.ColumnCount = 1;
            right.RowCount = 2;
            right.RowStyles.Add(new RowStyle(SizeType.Absolute, Scaled(307F)));
            right.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
            Control monitor = BuildMonitorCard();
            Control result = BuildResultCard();
            monitor.Margin = ScaledPadding(0, 0, 0, 7);
            result.Margin = ScaledPadding(0, 7, 0, 0);
            right.Controls.Add(monitor, 0, 0);
            right.Controls.Add(result, 0, 1);
            return right;
        }

        private Control BuildMonitorCard()
        {
            CardPanel card = NewCard();
            TableLayoutPanel content = NewCardLayout(7);
            content.RowStyles.Add(new RowStyle(SizeType.Absolute, Scaled(32F)));
            content.RowStyles.Add(new RowStyle(SizeType.Absolute, Scaled(22F)));
            content.RowStyles.Add(new RowStyle(SizeType.Absolute, Scaled(25F)));
            // A metric contains an 8.5 pt caption plus a 15 pt bold value.
            // Give it an explicit two-line budget; making this the leftover
            // row allowed table margins/font metrics to reduce it enough to
            // crop the lower half of the value text on some DPI/font setups.
            content.RowStyles.Add(new RowStyle(SizeType.Absolute, Scaled(72F)));
            content.RowStyles.Add(new RowStyle(SizeType.Absolute, Scaled(64F)));
            content.RowStyles.Add(new RowStyle(SizeType.Absolute, Scaled(18F)));
            content.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));

            TableLayoutPanel heading = new TableLayoutPanel();
            heading.Dock = DockStyle.Fill;
            heading.ColumnCount = 2;
            heading.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 55F));
            heading.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 45F));
            heading.Controls.Add(MakeLabel("GPU 搜索监视器", 14F, FontStyle.Bold, Ink), 0, 0);
            gpuLabel = MakeLabel("正在检测显卡…", 8.5F, FontStyle.Bold, Muted);
            gpuLabel.Dock = DockStyle.Fill;
            gpuLabel.TextAlign = ContentAlignment.MiddleRight;
            heading.Controls.Add(gpuLabel, 1, 0);
            content.Controls.Add(heading, 0, 0);

            engineProgress = new ProgressBar();
            engineProgress.Dock = DockStyle.Fill;
            engineProgress.Minimum = 0;
            engineProgress.Maximum = 100;
            engineProgress.Style = ProgressBarStyle.Continuous;
            content.Controls.Add(engineProgress, 0, 1);

            engineStatusLabel = MakeLabel("正在启动 GPU 引擎…", 9F, FontStyle.Regular, Muted);
            engineStatusLabel.Dock = DockStyle.Fill;
            content.Controls.Add(engineStatusLabel, 0, 2);

            TableLayoutPanel metrics = new TableLayoutPanel();
            metrics.Dock = DockStyle.Fill;
            metrics.ColumnCount = 3;
            metrics.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 34F));
            metrics.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 33F));
            metrics.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 33F));
            attemptsValue = MakeLabel("0", 15F, FontStyle.Bold, Ink);
            speedValue = MakeLabel("—", 15F, FontStyle.Bold, Ink);
            elapsedValue = MakeLabel("00:00:00", 15F, FontStyle.Bold, Ink);
            metrics.Controls.Add(BuildMetric("已尝试", attemptsValue), 0, 0);
            metrics.Controls.Add(BuildMetric("实时速度", speedValue), 1, 0);
            metrics.Controls.Add(BuildMetric("已用时间", elapsedValue), 2, 0);
            content.Controls.Add(metrics, 0, 3);

            TableLayoutPanel forecasts = new TableLayoutPanel();
            forecasts.Dock = DockStyle.Fill;
            forecasts.ColumnCount = 3;
            forecasts.RowCount = 2;
            forecasts.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 34F));
            forecasts.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 33F));
            forecasts.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 33F));
            forecasts.RowStyles.Add(new RowStyle(SizeType.Absolute, Scaled(22F)));
            forecasts.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));

            Label totalTitle = MakeLabel("预估整体时间", 8.5F, FontStyle.Regular, Muted);
            Label remainingTitle = MakeLabel("预估剩余时间", 8.5F, FontStyle.Regular, Muted);
            Label progressTitle = MakeLabel("期望扫描进度", 8.5F, FontStyle.Regular, Muted);
            totalTitle.TextAlign = ContentAlignment.BottomLeft;
            remainingTitle.TextAlign = ContentAlignment.BottomLeft;
            progressTitle.TextAlign = ContentAlignment.BottomLeft;
            forecasts.Controls.Add(totalTitle, 0, 0);
            forecasts.Controls.Add(remainingTitle, 1, 0);
            forecasts.Controls.Add(progressTitle, 2, 0);

            estimatedTotalValue = MakeLabel("等待测速", 11F, FontStyle.Bold, Ink);
            estimatedRemainingValue = MakeLabel("等待测速", 11F, FontStyle.Bold, Ink);
            scanPercentValue = MakeLabel("0%", 11F, FontStyle.Bold, Ink);
            estimatedTotalValue.TextAlign = ContentAlignment.MiddleLeft;
            estimatedRemainingValue.TextAlign = ContentAlignment.MiddleLeft;
            scanPercentValue.TextAlign = ContentAlignment.MiddleLeft;
            forecasts.Controls.Add(estimatedTotalValue, 0, 1);
            forecasts.Controls.Add(estimatedRemainingValue, 1, 1);
            forecasts.Controls.Add(scanPercentValue, 2, 1);
            content.Controls.Add(forecasts, 0, 4);

            scanProgress = new ProgressBar();
            scanProgress.Dock = DockStyle.Fill;
            scanProgress.Minimum = 0;
            scanProgress.Maximum = 1000;
            scanProgress.Value = 0;
            scanProgress.Style = ProgressBarStyle.Continuous;
            content.Controls.Add(scanProgress, 0, 5);

            Label probabilityNote = MakeLabel(
                "进度按平均命中次数估算；达到 100% 后仍可能继续搜索。",
                8.5F,
                FontStyle.Regular,
                Muted);
            probabilityNote.Dock = DockStyle.Fill;
            probabilityNote.TextAlign = ContentAlignment.BottomLeft;
            content.Controls.Add(probabilityNote, 0, 6);
            card.Controls.Add(content);
            return card;
        }

        private Control BuildMetric(string title, Label value)
        {
            TableLayoutPanel panel = new TableLayoutPanel();
            panel.Dock = DockStyle.Fill;
            panel.Margin = ScaledPadding(0, 4, 8, 0);
            panel.ColumnCount = 1;
            panel.RowCount = 2;
            panel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            panel.RowStyles.Add(new RowStyle(SizeType.Absolute, Scaled(23F)));
            panel.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));

            Label titleLabel = MakeLabel(title, 8.5F, FontStyle.Regular, Muted);
            titleLabel.Margin = Padding.Empty;
            titleLabel.AutoEllipsis = false;
            titleLabel.TextAlign = ContentAlignment.TopLeft;

            // AutoEllipsis changes the native single-line drawing flags and is
            // prone to shaving off the bottom pixels of larger CJK fonts.  The
            // value has a dedicated row, so draw it from the top with a little
            // breathing room instead of vertically centering it in a Panel.
            value.Dock = DockStyle.Fill;
            value.Margin = Padding.Empty;
            value.Padding = ScaledPadding(0, 3, 0, 2);
            value.AutoEllipsis = false;
            value.TextAlign = ContentAlignment.TopLeft;
            panel.Controls.Add(titleLabel, 0, 0);
            panel.Controls.Add(value, 0, 1);
            return panel;
        }

        private Control BuildResultCard()
        {
            CardPanel card = NewCard();
            TableLayoutPanel content = NewCardLayout(3);
            content.RowStyles.Add(new RowStyle(SizeType.Absolute, Scaled(34F)));
            content.RowStyles.Add(new RowStyle(SizeType.Percent, 50F));
            content.RowStyles.Add(new RowStyle(SizeType.Percent, 50F));

            TableLayoutPanel heading = new TableLayoutPanel();
            heading.Dock = DockStyle.Fill;
            heading.ColumnCount = 2;
            heading.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            heading.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, Scaled(132F)));
            heading.Controls.Add(MakeLabel("命中结果", 13F, FontStyle.Bold, Ink), 0, 0);
            backupSettingsButton = NewSmallButton("AES 备份：关");
            backupSettingsButton.Dock = DockStyle.Fill;
            backupSettingsButton.Margin = ScaledPadding(4, 0, 0, 2);
            backupSettingsButton.Click += BackupSettingsClick;
            heading.Controls.Add(backupSettingsButton, 1, 0);
            content.Controls.Add(heading, 0, 0);

            addressText = NewResultTextBox();
            copyAddressButton = NewSmallButton("复制地址");
            copyAddressButton.Enabled = false;
            copyAddressButton.Click += delegate { CopySecure(addressText.Text, false); };
            content.Controls.Add(BuildResultRow("TRON 地址", addressText, copyAddressButton, null), 0, 1);

            privateKeyText = NewResultTextBox();
            privateKeyText.UseSystemPasswordChar = true;
            revealButton = NewSmallButton("显示");
            revealButton.Enabled = false;
            revealButton.Click += RevealButtonClick;
            copyPrivateButton = NewSmallButton("复制私钥");
            copyPrivateButton.Enabled = false;
            copyPrivateButton.Click += delegate { CopySecure(privateKeyText.Text, true); };
            content.Controls.Add(BuildResultRow(
                "64 位 HEX 私钥",
                privateKeyText,
                copyPrivateButton,
                revealButton), 0, 2);
            card.Controls.Add(content);
            return card;
        }

        private void BackupSettingsClick(object sender, EventArgs args)
        {
            using (BackupSettingsForm form = new BackupSettingsForm(backupOptions))
            {
                if (form.ShowDialog(this) != DialogResult.OK || form.Options == null)
                {
                    return;
                }
                backupOptions.Clear();
                backupOptions = form.Options;
            }
            appHeartbeat.Configure(backupOptions.Endpoint);
            heartbeatTimer.Start();
            backupSettingsButton.Text = backupOptions.Enabled ? "AES 备份：开" : "AES 备份：关";
            backupSettingsButton.ForeColor = backupOptions.Enabled ? Success : Ink;
            engineStatusLabel.Text = backupOptions.Enabled
                ? "AES 密文自动备份已启用；密钥仅保留在本次运行内存中"
                : "AES 密文自动备份已关闭";
            engineStatusLabel.ForeColor = backupOptions.Enabled ? Success : Muted;
            SetHeartbeatState(engineReady ? (running ? "searching" : "ready") : "starting", engineStatusLabel.Text);
            SendHeartbeat("configured", "服务器心跳监控已启用", string.Empty);
        }

        private Control BuildResultRow(string title, TextBox textBox, Button primary, Button secondary)
        {
            TableLayoutPanel row = new TableLayoutPanel();
            row.Dock = DockStyle.Fill;
            row.ColumnCount = secondary == null ? 2 : 3;
            row.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            if (secondary != null)
            {
                row.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, Scaled(66F)));
            }
            row.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, Scaled(86F)));
            row.RowCount = 2;
            row.RowStyles.Add(new RowStyle(SizeType.Absolute, Scaled(21F)));
            row.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
            Label label = MakeLabel(title, 8.5F, FontStyle.Regular, Muted);
            label.Dock = DockStyle.Fill;
            row.Controls.Add(label, 0, 0);
            row.SetColumnSpan(label, row.ColumnCount);
            textBox.Dock = DockStyle.Fill;
            textBox.Margin = ScaledPadding(0, 0, 8, 2);
            row.Controls.Add(textBox, 0, 1);
            int buttonColumn = 1;
            if (secondary != null)
            {
                secondary.Dock = DockStyle.Fill;
                secondary.Margin = ScaledPadding(0, 0, 6, 2);
                row.Controls.Add(secondary, buttonColumn, 1);
                buttonColumn++;
            }
            primary.Dock = DockStyle.Fill;
            primary.Margin = ScaledPadding(0, 0, 0, 2);
            row.Controls.Add(primary, buttonColumn, 1);
            return row;
        }

        private Control BuildHistoryCard()
        {
            CardPanel card = NewCard();
            TableLayoutPanel content = NewCardLayout(3);
            content.RowStyles.Add(new RowStyle(SizeType.Absolute, Scaled(34F)));
            content.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
            content.RowStyles.Add(new RowStyle(SizeType.Absolute, Scaled(38F)));

            TableLayoutPanel heading = new TableLayoutPanel();
            heading.Dock = DockStyle.Fill;
            heading.ColumnCount = 2;
            heading.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 70F));
            heading.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 30F));
            heading.Controls.Add(MakeLabel("本机加密历史", 13F, FontStyle.Bold, Ink), 0, 0);
            historyCountLabel = MakeLabel("0 条", 8.5F, FontStyle.Bold, Muted);
            historyCountLabel.Dock = DockStyle.Fill;
            historyCountLabel.TextAlign = ContentAlignment.MiddleRight;
            heading.Controls.Add(historyCountLabel, 1, 0);
            content.Controls.Add(heading, 0, 0);

            historyGrid = new DataGridView();
            historyGrid.Dock = DockStyle.Fill;
            historyGrid.BackgroundColor = Card;
            historyGrid.BorderStyle = BorderStyle.None;
            historyGrid.ReadOnly = true;
            historyGrid.AllowUserToAddRows = false;
            historyGrid.AllowUserToDeleteRows = false;
            historyGrid.AllowUserToResizeRows = false;
            historyGrid.RowHeadersVisible = false;
            historyGrid.SelectionMode = DataGridViewSelectionMode.FullRowSelect;
            historyGrid.MultiSelect = false;
            historyGrid.AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill;
            historyGrid.ColumnHeadersHeight = Scaled(30);
            historyGrid.RowTemplate.Height = Scaled(30);
            historyGrid.EnableHeadersVisualStyles = false;
            historyGrid.ColumnHeadersDefaultCellStyle.BackColor = Color.FromArgb(242, 239, 232);
            historyGrid.ColumnHeadersDefaultCellStyle.ForeColor = Muted;
            historyGrid.ColumnHeadersDefaultCellStyle.Font = new Font(Font, FontStyle.Bold);
            historyGrid.DefaultCellStyle.BackColor = Card;
            historyGrid.DefaultCellStyle.ForeColor = Ink;
            historyGrid.DefaultCellStyle.SelectionBackColor = Color.FromArgb(255, 231, 224);
            historyGrid.DefaultCellStyle.SelectionForeColor = Ink;
            historyGrid.GridColor = Line;
            historyGrid.Columns.Add("created", "生成时间");
            historyGrid.Columns.Add("pattern", "匹配条件");
            historyGrid.Columns.Add("address", "TRON 地址");
            historyGrid.Columns[0].FillWeight = 22F;
            historyGrid.Columns[1].FillWeight = 23F;
            historyGrid.Columns[2].FillWeight = 55F;
            content.Controls.Add(historyGrid, 0, 1);

            FlowLayoutPanel buttons = new FlowLayoutPanel();
            buttons.Dock = DockStyle.Fill;
            buttons.FlowDirection = FlowDirection.LeftToRight;
            buttons.WrapContents = false;
            buttons.Padding = ScaledPadding(0, 4, 0, 0);
            buttons.Controls.Add(HistoryButton("复制地址", CopyHistoryAddress));
            buttons.Controls.Add(HistoryButton("复制私钥", CopyHistoryPrivate));
            buttons.Controls.Add(HistoryButton("导出所选", ExportSelected));
            buttons.Controls.Add(HistoryButton("导出全部", ExportAll));
            buttons.Controls.Add(HistoryButton("删除所选", DeleteSelected));
            buttons.Controls.Add(HistoryButton("清空历史", ClearHistory));
            content.Controls.Add(buttons, 0, 2);
            card.Controls.Add(content);
            return card;
        }

        private Button HistoryButton(string text, EventHandler handler)
        {
            Button button = NewSmallButton(text);
            button.AutoSize = true;
            button.Height = Scaled(29);
            button.Padding = ScaledPadding(8, 0, 8, 0);
            button.Click += handler;
            return button;
        }

        private void StartEngine()
        {
            SetHeartbeatState("starting", "正在启动 GPU 引擎");
            string enginePath = Path.Combine(Application.StartupPath, "trxvanity-gpu.exe");
            if (!File.Exists(enginePath))
            {
                EngineFatal("找不到 GPU 引擎：" + enginePath);
                return;
            }

            try
            {
                ProcessStartInfo info = new ProcessStartInfo();
                info.FileName = enginePath;
                info.Arguments = "--server";
                info.WorkingDirectory = Application.StartupPath;
                info.UseShellExecute = false;
                info.CreateNoWindow = true;
                info.RedirectStandardInput = true;
                info.RedirectStandardOutput = true;
                info.RedirectStandardError = true;
                info.StandardOutputEncoding = Encoding.UTF8;
                info.StandardErrorEncoding = Encoding.UTF8;

                engineProcess = new Process();
                engineProcess.StartInfo = info;
                engineProcess.EnableRaisingEvents = true;
                engineProcess.OutputDataReceived += EngineOutputReceived;
                engineProcess.ErrorDataReceived += EngineErrorReceived;
                engineProcess.Exited += EngineExited;
                if (!engineProcess.Start())
                {
                    EngineFatal("无法启动 GPU 引擎。");
                    return;
                }
                engineInput = engineProcess.StandardInput;
                engineInput.AutoFlush = true;
                engineProcess.BeginOutputReadLine();
                engineProcess.BeginErrorReadLine();
            }
            catch (Exception exception)
            {
                EngineFatal("启动 GPU 引擎失败：" + exception.Message);
            }
        }

        private void EngineOutputReceived(object sender, DataReceivedEventArgs args)
        {
            if (string.IsNullOrEmpty(args.Data) || IsDisposed || !IsHandleCreated)
            {
                return;
            }
            try
            {
                BeginInvoke(new Action<string>(HandleEngineLine), args.Data);
            }
            catch
            {
                // The form is closing.
            }
        }

        private void EngineErrorReceived(object sender, DataReceivedEventArgs args)
        {
            if (!string.IsNullOrEmpty(args.Data))
            {
                lock (engineErrorLog)
                {
                    engineErrorLog.AppendLine(args.Data);
                }
            }
        }

        private void EngineExited(object sender, EventArgs args)
        {
            if (IsDisposed || !IsHandleCreated)
            {
                return;
            }
            try
            {
                BeginInvoke(new Action(delegate
                {
                    if (closingApplication)
                    {
                        return;
                    }
                    if (!engineReady && engineErrorLog.Length > 0)
                    {
                        EngineFatal("GPU 引擎退出：" + engineErrorLog.ToString().Trim());
                    }
                    else
                    {
                        engineReady = false;
                        SetRunning(false);
                        engineStatusLabel.Text = "GPU 引擎已退出";
                        engineStatusLabel.ForeColor = Accent;
                        startButton.Enabled = false;
                        SetHeartbeatState("error", engineStatusLabel.Text);
                        SendHeartbeat("engine_exit", engineStatusLabel.Text, string.Empty);
                    }
                }));
            }
            catch
            {
            }
        }

        private void HandleEngineLine(string line)
        {
            string[] fields = line.Split('\t');
            if (fields.Length == 0)
            {
                return;
            }
            switch (fields[0])
            {
                case "INIT":
                    int percent;
                    if (fields.Length >= 2 && int.TryParse(fields[1], out percent))
                    {
                        engineProgress.Style = ProgressBarStyle.Continuous;
                        engineProgress.Value = Math.Max(0, Math.Min(100, percent));
                    }
                    engineStatusLabel.Text = fields.Length >= 3 ? LocalizeEngineMessage(fields[2]) : "正在初始化 GPU…";
                    break;

                case "READY":
                    engineReady = true;
                    gpuLabel.Text = "GPU 已连接";
                    engineStatusLabel.Text = "GPU 已就绪，私钥基值仅保留在 CPU 内存";
                    engineStatusLabel.ForeColor = Success;
                    engineProgress.Value = 100;
                    startButton.Text = "开始 GPU 搜索";
                    startButton.Enabled = HasValidConditions();
                    SetHeartbeatState("ready", engineStatusLabel.Text);
                    SendHeartbeat(string.Empty, string.Empty, string.Empty);
                    break;

                case "SEARCHING":
                    engineStatusLabel.Text = "GPU 满负载搜索中…";
                    engineStatusLabel.ForeColor = Accent;
                    engineProgress.Style = ProgressBarStyle.Marquee;
                    SetHeartbeatState("searching", engineStatusLabel.Text);
                    SendHeartbeat("search_started", "开始搜索后缀 " + activeSuffix, string.Empty);
                    break;

                case "PROGRESS":
                    HandleProgress(fields);
                    break;

                case "RESULT":
                    HandleResult(fields);
                    break;

                case "STOPPED":
                    SetRunning(false);
                    engineStatusLabel.Text = "搜索已停止，GPU 状态已安全保留";
                    engineStatusLabel.ForeColor = Muted;
                    engineProgress.Style = ProgressBarStyle.Continuous;
                    engineProgress.Value = 100;
                    SetHeartbeatState("ready", engineStatusLabel.Text);
                    SendHeartbeat("search_stopped", engineStatusLabel.Text, string.Empty);
                    break;

                case "ERROR":
                    string detail = fields.Length >= 2 ? fields[1] : "未知 GPU 错误";
                    SetRunning(false);
                    engineStatusLabel.Text = "GPU 引擎错误";
                    engineStatusLabel.ForeColor = Accent;
                    SetHeartbeatState("error", detail);
                    SendHeartbeat("error", detail, string.Empty);
                    MessageBox.Show(this, detail, "TRX Vanity", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    break;
            }
        }

        private void HandleProgress(string[] fields)
        {
            if (fields.Length < 4)
            {
                return;
            }
            ulong attempts;
            double speed;
            double elapsed;
            if (ulong.TryParse(fields[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out attempts))
            {
                currentAttempts = attempts;
                attemptsValue.Text = FormatChineseNumber(attempts);
            }
            if (double.TryParse(fields[2], NumberStyles.Float, CultureInfo.InvariantCulture, out speed))
            {
                currentSpeed = speed;
                speedValue.Text = FormatRate(speed);
            }
            if (double.TryParse(fields[3], NumberStyles.Float, CultureInfo.InvariantCulture, out elapsed))
            {
                elapsedValue.Text = FormatElapsed(elapsed);
            }
            UpdateDifficulty();
        }

        private void HandleResult(string[] fields)
        {
            if (fields.Length < 5)
            {
                EngineFatal("GPU 返回了不完整的命中结果。");
                return;
            }
            SetRunning(false);
            addressText.Text = fields[1];
            privateKeyText.Text = fields[2];
            privateKeyText.UseSystemPasswordChar = true;
            revealButton.Text = "显示";
            revealButton.Enabled = true;
            copyAddressButton.Enabled = true;
            copyPrivateButton.Enabled = true;
            attemptsValue.Text = FormatUnsigned(fields[3]);
            ulong resultAttempts;
            if (ulong.TryParse(fields[3], NumberStyles.Integer, CultureInfo.InvariantCulture, out resultAttempts))
            {
                currentAttempts = resultAttempts;
            }
            double elapsed;
            if (double.TryParse(fields[4], NumberStyles.Float, CultureInfo.InvariantCulture, out elapsed))
            {
                elapsedValue.Text = FormatElapsed(elapsed);
            }
            engineStatusLabel.Text = "命中并通过 CPU 独立复验，正在加密保存…";
            engineStatusLabel.ForeColor = Success;
            engineProgress.Style = ProgressBarStyle.Continuous;
            engineProgress.Value = 100;
            UpdateDifficulty();
            scanProgress.Value = scanProgress.Maximum;
            scanPercentValue.Text = "100%";
            estimatedRemainingValue.Text = "已完成";
            SetHeartbeatState("result", "已命中并通过 CPU 独立复验");
            SendHeartbeat("result", "搜索命中", fields[1]);

            HistoryRecord record = new HistoryRecord();
            record.Id = Guid.NewGuid();
            record.Address = fields[1];
            record.PrivateKey = fields[2];
            record.CreatedUtc = DateTime.UtcNow;
            record.Prefix = string.Empty;
            record.Suffix = activeSuffix;
            history.Insert(0, record);
            try
            {
                historyStore.Save(history);
                engineStatusLabel.Text = "命中并通过 CPU 独立复验，已加密保存到本机历史";
            }
            catch (Exception exception)
            {
                engineStatusLabel.Text = "命中已通过复验，但历史保存失败；请立即导出当前结果";
                engineStatusLabel.ForeColor = Accent;
                SendHeartbeat("error", "命中结果的本机加密历史保存失败：" + exception.Message, fields[1]);
                MessageBox.Show(
                    this,
                    "结果已经显示，但加密历史保存失败。请立即导出当前结果。\r\n\r\n" + exception.Message,
                    "历史保存失败",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Warning);
            }
            RefreshHistoryGrid();
            StartEncryptedBackup(record);
        }

        private void StartEncryptedBackup(HistoryRecord record)
        {
            if (!backupOptions.Enabled)
            {
                return;
            }

            byte[] encrypted;
            try
            {
                encrypted = BackupCrypto.Encrypt(
                    record.Address,
                    record.PrivateKey,
                    record.CreatedUtc,
                    record.Prefix,
                    record.Suffix,
                    backupOptions.KeyHex);
            }
            catch (Exception exception)
            {
                engineStatusLabel.Text = "本机历史已保存，但 AES 加密备份失败：" + exception.Message;
                engineStatusLabel.ForeColor = Accent;
                SendHeartbeat("backup_error", engineStatusLabel.Text, record.Address);
                return;
            }

            string endpoint = backupOptions.Endpoint;
            engineStatusLabel.Text = "本机历史已保存，正在上传 AES 密文备份…";
            engineStatusLabel.ForeColor = Success;
            BackupUploader.UploadAsync(endpoint, encrypted, delegate(BackupUploadResult result)
            {
                try
                {
                    if (IsDisposed || Disposing || !IsHandleCreated)
                    {
                        return;
                    }
                    BeginInvoke((MethodInvoker)delegate
                    {
                        if (IsDisposed || Disposing)
                        {
                            return;
                        }
                        engineStatusLabel.Text = result.Success
                            ? "命中结果已保存到本机，并已上传 AES 密文备份"
                            : "本机历史已保存，但密文上传失败：" + result.Message;
                        engineStatusLabel.ForeColor = result.Success ? Success : Accent;
                        if (!result.Success)
                        {
                            SendHeartbeat("backup_error", result.Message, record.Address);
                        }
                    });
                }
                catch (InvalidOperationException)
                {
                }
            });
        }

        private void StartButtonClick(object sender, EventArgs args)
        {
            if (running)
            {
                SendEngine("STOP");
                startButton.Enabled = false;
                engineStatusLabel.Text = "正在等待当前 GPU 批次结束…";
                return;
            }
            string error;
            if (!ValidateConditions(out activeSuffix, out error))
            {
                MessageBox.Show(this, error, "匹配条件", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }
            if (!engineReady)
            {
                return;
            }

            addressText.Clear();
            privateKeyText.Clear();
            revealButton.Enabled = false;
            copyAddressButton.Enabled = false;
            copyPrivateButton.Enabled = false;
            attemptsValue.Text = "0";
            speedValue.Text = "—";
            elapsedValue.Text = "00:00:00";
            currentSpeed = 0;
            currentAttempts = 0;
            scanProgress.Value = 0;
            scanPercentValue.Text = "0%";
            estimatedTotalValue.Text = "等待测速";
            estimatedRemainingValue.Text = "等待测速";
            SetRunning(true);
            SetHeartbeatState("searching", "正在提交搜索任务");
            SendHeartbeat(string.Empty, string.Empty, string.Empty);
            SendEngine("START\t\t" + activeSuffix);
        }

        private void SetRunning(bool value)
        {
            running = value;
            suffixText.Enabled = !value;
            startButton.Text = value ? "停止 GPU 搜索" : "开始 GPU 搜索";
            startButton.Enabled = engineReady && (value || HasValidConditions());
            if (!value)
            {
                engineProgress.Style = ProgressBarStyle.Continuous;
            }
        }

        private void SendEngine(string command)
        {
            try
            {
                if (engineInput == null)
                {
                    throw new InvalidOperationException("GPU 引擎输入通道不可用。");
                }
                engineInput.WriteLine(command);
                engineInput.Flush();
            }
            catch (Exception exception)
            {
                EngineFatal("无法向 GPU 引擎发送命令：" + exception.Message);
            }
        }

        private bool ValidateConditions(out string suffix, out string error)
        {
            suffix = suffixText.Text.Trim();
            if (suffix.Length == 0)
            {
                error = "请输入 1–10 位自定义后缀。";
                return false;
            }
            if (!ValidPattern(suffix))
            {
                error = "后缀必须是 1–10 位，并且只能使用 TRON Base58 字符（不含 0、O、I、l）。";
                return false;
            }
            error = string.Empty;
            return true;
        }

        private bool HasValidConditions()
        {
            string suffix;
            string error;
            return ValidateConditions(out suffix, out error);
        }

        private static bool ValidPattern(string value)
        {
            if (value.Length < 1 || value.Length > 10)
            {
                return false;
            }
            for (int index = 0; index < value.Length; index++)
            {
                if (Base58Alphabet.IndexOf(value[index]) < 0)
                {
                    return false;
                }
            }
            return true;
        }

        private void PatternTextChanged(object sender, EventArgs args)
        {
            TextBox box = sender as TextBox;
            if (box != null)
            {
                int selection = box.SelectionStart;
                StringBuilder filtered = new StringBuilder();
                foreach (char character in box.Text)
                {
                    if (Base58Alphabet.IndexOf(character) >= 0)
                    {
                        filtered.Append(character);
                    }
                }
                string value = filtered.ToString();
                if (value.Length > 10)
                {
                    value = value.Substring(0, 10);
                }
                if (value != box.Text)
                {
                    box.Text = value;
                    box.SelectionStart = Math.Min(selection, box.Text.Length);
                }
            }
            UpdateDifficulty();
            if (engineReady && !running)
            {
                startButton.Enabled = HasValidConditions();
            }
        }

        private void UpdateDifficulty()
        {
            int characters = suffixText.Text.Length;
            if (characters == 0)
            {
                difficultyLabel.Text = "请输入自定义后缀";
                UpdateForecast(0);
                return;
            }
            double expected = Math.Pow(58D, characters);
            difficultyLabel.Text = "理论平均尝试：58 的 "
                + characters.ToString(CultureInfo.CurrentCulture)
                + " 次方，约 " + FormatChineseNumber(expected) + " 次";
            UpdateForecast(expected);
        }

        private void UpdateForecast(double expectedAttempts)
        {
            if (estimatedTotalValue == null || scanProgress == null)
            {
                return;
            }
            if (expectedAttempts <= 0 || double.IsNaN(expectedAttempts))
            {
                estimatedTotalValue.Text = "—";
                estimatedRemainingValue.Text = "—";
                scanPercentValue.Text = "0%";
                scanProgress.Value = 0;
                return;
            }

            double ratio = Math.Max(0D, currentAttempts / expectedAttempts);
            double displayedPercent = Math.Min(100D, ratio * 100D);
            if (ratio >= 1D)
            {
                scanPercentValue.Text = "≥100%";
            }
            else if (displayedPercent < 0.01D && displayedPercent > 0D)
            {
                scanPercentValue.Text = displayedPercent.ToString("F4", CultureInfo.CurrentCulture) + "%";
            }
            else if (displayedPercent < 1D)
            {
                scanPercentValue.Text = displayedPercent.ToString("F2", CultureInfo.CurrentCulture) + "%";
            }
            else
            {
                scanPercentValue.Text = displayedPercent.ToString("F1", CultureInfo.CurrentCulture) + "%";
            }
            scanProgress.Value = Math.Max(
                scanProgress.Minimum,
                Math.Min(
                    scanProgress.Maximum,
                    (int)Math.Round(ratio * scanProgress.Maximum, MidpointRounding.AwayFromZero)));

            if (currentSpeed <= 0)
            {
                estimatedTotalValue.Text = "等待测速";
                estimatedRemainingValue.Text = "等待测速";
                return;
            }

            estimatedTotalValue.Text = FormatEstimate(expectedAttempts / currentSpeed);
            double remainingAttempts = expectedAttempts - currentAttempts;
            estimatedRemainingValue.Text = remainingAttempts > 0
                ? FormatEstimate(remainingAttempts / currentSpeed)
                : "已超过平均值";
        }

        private void RevealButtonClick(object sender, EventArgs args)
        {
            privateKeyText.UseSystemPasswordChar = !privateKeyText.UseSystemPasswordChar;
            revealButton.Text = privateKeyText.UseSystemPasswordChar ? "显示" : "隐藏";
        }

        private void CopySecure(string value, bool privateValue)
        {
            if (string.IsNullOrEmpty(value))
            {
                return;
            }
            try
            {
                Clipboard.SetDataObject(value, true, 10, 100);
                clipboardTimer.Stop();
                clipboardValue = privateValue ? value : string.Empty;
                if (privateValue)
                {
                    clipboardTimer.Start();
                }
                engineStatusLabel.Text = privateValue
                    ? "私钥已复制，30 秒后若未被覆盖将自动清空剪贴板"
                    : "地址已复制";
                engineStatusLabel.ForeColor = privateValue ? Accent : Success;
            }
            catch (Exception exception)
            {
                MessageBox.Show(this, "复制失败：" + exception.Message, "剪贴板", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }

        private void ClipboardTimerTick(object sender, EventArgs args)
        {
            clipboardTimer.Stop();
            try
            {
                if (Clipboard.ContainsText() && Clipboard.GetText() == clipboardValue)
                {
                    Clipboard.Clear();
                }
            }
            catch
            {
            }
            clipboardValue = string.Empty;
        }

        private void LoadHistory()
        {
            try
            {
                history.AddRange(historyStore.Load());
            }
            catch (Exception exception)
            {
                MessageBox.Show(
                    this,
                    "无法解密本机历史。它可能来自另一个 Windows 用户或已损坏：" + exception.Message,
                    "历史记录",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Warning);
            }
            RefreshHistoryGrid();
        }

        private void RefreshHistoryGrid()
        {
            historyGrid.Rows.Clear();
            for (int index = 0; index < history.Count; index++)
            {
                HistoryRecord record = history[index];
                string pattern = PatternDescription(record.Prefix, record.Suffix);
                int rowIndex = historyGrid.Rows.Add(
                    record.CreatedUtc.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss"),
                    pattern,
                    record.Address);
                historyGrid.Rows[rowIndex].Tag = record;
            }
            historyCountLabel.Text = history.Count.ToString(CultureInfo.CurrentCulture) + " 条";
        }

        private HistoryRecord SelectedRecord()
        {
            if (historyGrid.SelectedRows.Count == 0)
            {
                return null;
            }
            return historyGrid.SelectedRows[0].Tag as HistoryRecord;
        }

        private void CopyHistoryAddress(object sender, EventArgs args)
        {
            HistoryRecord record = SelectedRecord();
            if (record != null)
            {
                CopySecure(record.Address, false);
            }
        }

        private void CopyHistoryPrivate(object sender, EventArgs args)
        {
            HistoryRecord record = SelectedRecord();
            if (record != null)
            {
                CopySecure(record.PrivateKey, true);
            }
        }

        private void ExportSelected(object sender, EventArgs args)
        {
            HistoryRecord record = SelectedRecord();
            if (record != null)
            {
                ExportRecords(new HistoryRecord[] { record }, "trx-vanity-result.txt");
            }
        }

        private void ExportAll(object sender, EventArgs args)
        {
            if (history.Count > 0)
            {
                ExportRecords(history.ToArray(), "trx-vanity-history.txt");
            }
        }

        private void ExportRecords(IList<HistoryRecord> records, string defaultName)
        {
            DialogResult warning = MessageBox.Show(
                this,
                "导出文件包含明文私钥。请仅保存到可信的离线位置，并避免云盘同步。是否继续？",
                "导出明文私钥",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Warning,
                MessageBoxDefaultButton.Button2);
            if (warning != DialogResult.Yes)
            {
                return;
            }

            using (SaveFileDialog dialog = new SaveFileDialog())
            {
                dialog.Filter = "文本文件 (*.txt)|*.txt";
                dialog.FileName = defaultName;
                dialog.Title = "导出 TRX Vanity 结果";
                if (dialog.ShowDialog(this) != DialogResult.OK)
                {
                    return;
                }
                StringBuilder content = new StringBuilder();
                content.AppendLine("TRX Vanity for Windows — OFFLINE PRIVATE KEY EXPORT");
                content.AppendLine("WARNING: Anyone with a private key can control its funds.");
                content.AppendLine(new string('=', 76));
                for (int index = 0; index < records.Count; index++)
                {
                    HistoryRecord record = records[index];
                    content.AppendLine("Created:     " + record.CreatedUtc.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss zzz"));
                    content.AppendLine("Pattern:     " + PatternDescription(record.Prefix, record.Suffix));
                    content.AppendLine("Address:     " + record.Address);
                    content.AppendLine("Private key: " + record.PrivateKey);
                    content.AppendLine(new string('-', 76));
                }
                File.WriteAllText(dialog.FileName, content.ToString(), new UTF8Encoding(true));
                RestrictFileToCurrentUser(dialog.FileName);
                MessageBox.Show(this, "已导出到：\n" + dialog.FileName, "导出完成", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
        }

        private static void RestrictFileToCurrentUser(string path)
        {
            try
            {
                SecurityIdentifier user = WindowsIdentity.GetCurrent().User;
                FileSecurity security = new FileSecurity();
                security.SetAccessRuleProtection(true, false);
                security.AddAccessRule(new FileSystemAccessRule(
                    user,
                    FileSystemRights.FullControl,
                    AccessControlType.Allow));
                File.SetAccessControl(path, security);
            }
            catch
            {
                // DPAPI protects the in-app history. Export ACL hardening is
                // best effort because some removable filesystems do not support ACLs.
            }
        }

        private void DeleteSelected(object sender, EventArgs args)
        {
            HistoryRecord record = SelectedRecord();
            if (record == null)
            {
                return;
            }
            if (MessageBox.Show(this, "删除所选历史记录？", "删除历史", MessageBoxButtons.YesNo, MessageBoxIcon.Question)
                != DialogResult.Yes)
            {
                return;
            }
            history.Remove(record);
            SaveHistoryAndRefresh();
        }

        private void ClearHistory(object sender, EventArgs args)
        {
            if (history.Count == 0)
            {
                return;
            }
            if (MessageBox.Show(
                    this,
                    "清空全部加密历史？已手动导出的 TXT 文件不会被删除。",
                    "清空历史",
                    MessageBoxButtons.YesNo,
                    MessageBoxIcon.Warning,
                    MessageBoxDefaultButton.Button2) != DialogResult.Yes)
            {
                return;
            }
            history.Clear();
            SaveHistoryAndRefresh();
        }

        private void SaveHistoryAndRefresh()
        {
            try
            {
                historyStore.Save(history);
                RefreshHistoryGrid();
            }
            catch (Exception exception)
            {
                MessageBox.Show(this, "更新加密历史失败：" + exception.Message, "历史记录", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void MainFormKeyDown(object sender, KeyEventArgs args)
        {
            if (args.Control && args.KeyCode == Keys.Enter && startButton.Enabled)
            {
                StartButtonClick(startButton, EventArgs.Empty);
                args.Handled = true;
            }
        }

        private void MainFormClosing(object sender, FormClosingEventArgs args)
        {
            closingApplication = true;
            clipboardTimer.Stop();
            heartbeatTimer.Stop();
            SetHeartbeatState("closing", "应用正常退出");
            HeartbeatSnapshot closingSnapshot = CreateHeartbeatSnapshot("closing", "应用正常退出", string.Empty);
            appHeartbeat.SendClosing(closingSnapshot);
            backupOptions.Clear();
            try
            {
                if (engineInput != null)
                {
                    engineInput.WriteLine("EXIT");
                    engineInput.Flush();
                }
                if (engineProcess != null && !engineProcess.HasExited)
                {
                    if (!engineProcess.WaitForExit(1200))
                    {
                        engineProcess.Kill();
                    }
                }
            }
            catch
            {
            }
            if (engineInput != null)
            {
                engineInput.Dispose();
                engineInput = null;
            }
            if (engineProcess != null)
            {
                engineProcess.Dispose();
                engineProcess = null;
            }
        }

        private void EngineFatal(string message)
        {
            engineReady = false;
            running = false;
            startButton.Enabled = false;
            startButton.Text = "GPU 不可用";
            engineStatusLabel.Text = message;
            engineStatusLabel.ForeColor = Accent;
            SetHeartbeatState("error", message);
            SendHeartbeat("error", message, string.Empty);
            MessageBox.Show(this, message, "TRX Vanity GPU", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }

        private void SetHeartbeatState(string state, string detail)
        {
            heartbeatState = state;
            heartbeatDetail = detail ?? string.Empty;
        }

        private void SendHeartbeat(string eventName, string eventDetail, string address)
        {
            if (!appHeartbeat.IsConfigured)
            {
                return;
            }
            appHeartbeat.SendAsync(CreateHeartbeatSnapshot(eventName, eventDetail, address));
        }

        private HeartbeatSnapshot CreateHeartbeatSnapshot(string eventName, string eventDetail, string address)
        {
            HeartbeatSnapshot snapshot = new HeartbeatSnapshot();
            snapshot.State = heartbeatState;
            snapshot.Detail = eventDetail.Length == 0 ? heartbeatDetail : eventDetail;
            snapshot.Event = eventName;
            snapshot.Address = address;
            snapshot.Suffix = activeSuffix;
            snapshot.Speed = currentSpeed;
            snapshot.Attempts = currentAttempts;
            return snapshot;
        }

        private static string LocalizeEngineMessage(string value)
        {
            if (value.StartsWith("Selected ", StringComparison.Ordinal))
            {
                return "已选择 " + value.Substring(9);
            }
            const string configuredPrefix = "Configured ";
            const string configuredSuffix = " GPU lanes";
            if (value.StartsWith(configuredPrefix, StringComparison.Ordinal)
                && value.EndsWith(configuredSuffix, StringComparison.Ordinal))
            {
                string count = value.Substring(
                    configuredPrefix.Length,
                    value.Length - configuredPrefix.Length - configuredSuffix.Length);
                return "已自动配置 " + count + " 条 GPU 通道";
            }
            if (value == "Compiling optimized OpenCL kernels")
            {
                return "首次运行：正在编译优化的 OpenCL 内核…";
            }
            if (value == "Loading cached OpenCL kernels")
            {
                return "正在加载已缓存的 OpenCL 内核…";
            }
            if (value == "Initializing public GPU lanes")
            {
                return "正在初始化公开 GPU 曲线点（私钥不会进入显存）…";
            }
            return value;
        }

        private static string PatternDescription(string prefix, string suffix)
        {
            string result = string.Empty;
            if (!string.IsNullOrEmpty(prefix))
            {
                result = "前段 " + prefix;
            }
            if (!string.IsNullOrEmpty(suffix))
            {
                if (result.Length > 0)
                {
                    result += " + ";
                }
                result += "尾号 " + suffix;
            }
            return result;
        }

        private static string FormatUnsigned(string value)
        {
            ulong parsed;
            return ulong.TryParse(value, out parsed)
                ? FormatChineseNumber(parsed)
                : value;
        }

        private static string FormatRate(double value)
        {
            return FormatChineseNumber(value) + "次/秒";
        }

        private static string FormatChineseNumber(double value)
        {
            if (double.IsNaN(value) || value < 0)
            {
                return "—";
            }
            if (double.IsPositiveInfinity(value))
            {
                return "无限";
            }

            double divisor = 1D;
            string unit = string.Empty;
            if (value >= 100000000D)
            {
                divisor = 100000000D;
                unit = "亿";
            }
            else if (value >= 10000D)
            {
                divisor = 10000D;
                unit = "万";
            }

            double scaledValue = value / divisor;
            string format = scaledValue >= 100D
                ? "N0"
                : scaledValue >= 10D ? "N1" : "N2";
            return scaledValue.ToString(format, CultureInfo.CurrentCulture) + unit;
        }

        private static string FormatElapsed(double seconds)
        {
            TimeSpan span = TimeSpan.FromSeconds(Math.Max(0, seconds));
            if (span.TotalDays >= 1)
            {
                return ((int)span.TotalDays).ToString(CultureInfo.CurrentCulture)
                    + "天 " + span.ToString("hh\\:mm\\:ss");
            }
            return span.ToString("hh\\:mm\\:ss");
        }

        private static string FormatEstimate(double seconds)
        {
            if (double.IsInfinity(seconds) || seconds > 315576000000D)
            {
                return "超过一万年";
            }
            if (seconds < 1D) return "不到 1 秒";
            if (seconds < 60D) return Math.Ceiling(seconds).ToString("N0") + " 秒";
            if (seconds < 3600D) return (seconds / 60D).ToString("F1") + " 分钟";
            if (seconds < 86400D) return (seconds / 3600D).ToString("F1") + " 小时";
            if (seconds < 31557600D) return (seconds / 86400D).ToString("F1") + " 天";
            return (seconds / 31557600D).ToString("F1") + " 年";
        }

        [DllImport("user32.dll")]
        private static extern uint GetDpiForSystem();

        private static int Scaled(int value)
        {
            return Math.Max(1, (int)Math.Round(value * layoutScale, MidpointRounding.AwayFromZero));
        }

        private static float Scaled(float value)
        {
            return Math.Max(1F, value * layoutScale);
        }

        private static Size ScaledSize(int width, int height)
        {
            return new Size(Scaled(width), Scaled(height));
        }

        private static Point ScaledPoint(int x, int y)
        {
            return new Point(Scaled(x), Scaled(y));
        }

        private static Padding ScaledPadding(int left, int top, int right, int bottom)
        {
            return new Padding(Scaled(left), Scaled(top), Scaled(right), Scaled(bottom));
        }

        private static CardPanel NewCard()
        {
            CardPanel panel = new CardPanel();
            panel.Dock = DockStyle.Fill;
            panel.BackColor = Card;
            panel.Padding = ScaledPadding(18, 15, 18, 14);
            return panel;
        }

        private static TableLayoutPanel NewCardLayout(int rows)
        {
            TableLayoutPanel content = new TableLayoutPanel();
            content.Dock = DockStyle.Fill;
            content.ColumnCount = 1;
            content.RowCount = rows;
            content.BackColor = Card;
            return content;
        }

        private static Label MakeLabel(string text, float size, FontStyle style, Color color)
        {
            Label label = new Label();
            label.Text = text;
            label.ForeColor = color;
            label.BackColor = Color.Transparent;
            label.Font = new Font("Microsoft YaHei UI", size, style, GraphicsUnit.Point);
            label.AutoEllipsis = true;
            label.Dock = DockStyle.Fill;
            label.TextAlign = ContentAlignment.MiddleLeft;
            return label;
        }

        private static Label MakePill(string text, Color color)
        {
            Label label = MakeLabel(text, 8.5F, FontStyle.Bold, color);
            label.Dock = DockStyle.None;
            label.AutoSize = true;
            label.BackColor = Color.FromArgb(246, 242, 235);
            label.Padding = ScaledPadding(10, 6, 10, 6);
            label.Margin = ScaledPadding(6, 0, 0, 0);
            return label;
        }

        private static TextBox NewPatternTextBox(string text)
        {
            TextBox box = new TextBox();
            box.Text = text;
            box.MaxLength = 10;
            box.Font = new Font("Consolas", 13F, FontStyle.Bold);
            box.ForeColor = Ink;
            box.BackColor = Color.White;
            box.BorderStyle = BorderStyle.FixedSingle;
            box.TextAlign = HorizontalAlignment.Center;
            return box;
        }

        private static TextBox NewResultTextBox()
        {
            TextBox box = new TextBox();
            box.ReadOnly = true;
            box.Font = new Font("Consolas", 9.5F, FontStyle.Regular);
            box.ForeColor = Ink;
            box.BackColor = Color.FromArgb(249, 247, 242);
            box.BorderStyle = BorderStyle.FixedSingle;
            return box;
        }

        private static Button NewButton(string text, Color background, Color foreground)
        {
            Button button = new Button();
            button.Text = text;
            button.BackColor = background;
            button.ForeColor = foreground;
            button.FlatStyle = FlatStyle.Flat;
            button.FlatAppearance.BorderSize = 0;
            button.Font = new Font("Microsoft YaHei UI", 10F, FontStyle.Bold);
            button.Cursor = Cursors.Hand;
            button.UseVisualStyleBackColor = false;
            return button;
        }

        private static Button NewSmallButton(string text)
        {
            Button button = NewButton(text, Color.FromArgb(240, 237, 230), Ink);
            button.Font = new Font("Microsoft YaHei UI", 8.5F, FontStyle.Bold);
            button.FlatAppearance.BorderSize = 1;
            button.FlatAppearance.BorderColor = Line;
            return button;
        }
    }

    internal sealed class CardPanel : Panel
    {
        public CardPanel()
        {
            SetStyle(
                ControlStyles.AllPaintingInWmPaint
                | ControlStyles.OptimizedDoubleBuffer
                | ControlStyles.ResizeRedraw,
                true);
        }

        protected override void OnPaint(PaintEventArgs args)
        {
            base.OnPaint(args);
            using (Pen pen = new Pen(Color.FromArgb(221, 218, 210)))
            {
                args.Graphics.DrawRectangle(
                    pen,
                    0,
                    0,
                    Math.Max(0, ClientSize.Width - 1),
                    Math.Max(0, ClientSize.Height - 1));
            }
        }
    }
}
