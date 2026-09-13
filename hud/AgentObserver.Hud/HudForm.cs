using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace AgentObserver.Hud
{
    internal sealed class HudForm : Form
    {
        private const int WsExNoActivate = 0x08000000;
        private const int WsExToolWindow = 0x00000080;
        private const int WmMouseActivate = 0x0021;
        private const int MaNoActivate = 3;
        private const uint SwpNoSize = 0x0001;
        private const uint SwpNoMove = 0x0002;
        private const uint SwpNoActivate = 0x0010;
        private const uint SwpShowWindow = 0x0040;
        private static readonly IntPtr HwndTopmost = new IntPtr(-1);

        private readonly HudOptions _options;
        private readonly ObserverProcessClient _observer;
        private readonly SessionAdmissionStore _admission = new SessionAdmissionStore();
        private readonly object _logLock = new object();
        private readonly Panel _header;
        private readonly DoubleBufferedFlowLayoutPanel _sessionList;
        private readonly SessionListPresenter _presenter;
        private readonly List<SessionItem> _lastSessions = new List<SessionItem>();
        private Timer? _closeTimer;
        private Point _dragStart;
        private Point _windowStart;
        private bool _dragging;
        private bool _observerUnavailable;
        private ObserverSourceState _sourceState = ObserverSourceState.Starting;
        private int _scanCount;
        private int _skippedCount;
        private int _windowResizeCount;
        private int _screenshotCount;
        private int _observerStartCount;
        private int _rowsCreatedTotal;
        private int _rowsUpdatedTotal;
        private int _rowsRemovedTotal;
        private int _rowsReorderedTotal;

        public HudForm(HudOptions options)
        {
            _options = options;
            _observer = new ObserverProcessClient(options.ObserverExecutable, LogObserverMessage);
            _observer.ScanReceived += HandleScan;
            _observer.StatusChanged += HandleStatus;

            AutoScaleMode = AutoScaleMode.Dpi;
            BackColor = HudColors.Background;
            ClientSize = new Size(HudMetrics.WindowWidth, HudMetrics.HeaderHeight);
            FormBorderStyle = FormBorderStyle.None;
            Font = new Font("Segoe UI", 9F, FontStyle.Regular, GraphicsUnit.Point);
            MaximizeBox = false;
            MinimizeBox = false;
            Name = "AgentObserverHud";
            Opacity = 0.96;
            ShowIcon = false;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            Text = "ATTENTION";
            TopMost = true;
            DoubleBuffered = true;
            SetStyle(
                ControlStyles.AllPaintingInWmPaint
                | ControlStyles.OptimizedDoubleBuffer
                | ControlStyles.ResizeRedraw,
                true);
            UpdateStyles();

            _header = BuildHeader();
            _sessionList = new DoubleBufferedFlowLayoutPanel
            {
                AutoScroll = false,
                BackColor = HudColors.Background,
                Dock = DockStyle.Fill,
                FlowDirection = FlowDirection.TopDown,
                Margin = Padding.Empty,
                Padding = Padding.Empty,
                WrapContents = false
            };
            _presenter = new SessionListPresenter(_sessionList);

            Controls.Add(_sessionList);
            Controls.Add(_header);

            Shown += (_, __) =>
            {
                WriteDiagnostic("HUD shown");
                PlaceAtTopRight();
                SetWindowPos(
                    Handle,
                    HwndTopmost,
                    0,
                    0,
                    0,
                    0,
                    SwpNoMove | SwpNoSize | SwpNoActivate | SwpShowWindow);
                if (!string.IsNullOrWhiteSpace(_options.ReplayFile))
                {
                    ApplyReplay();
                }
                else
                {
                    _observer.Start();
                }
                if (_options.CloseAfterMs.HasValue)
                {
                    _closeTimer = new Timer { Interval = _options.CloseAfterMs.Value };
                    _closeTimer.Tick += (_, __) =>
                    {
                        _closeTimer.Stop();
                        _closeTimer.Dispose();
                        _closeTimer = null;
                        Close();
                    };
                    _closeTimer.Start();
                }
            };
            FormClosing += (_, __) =>
            {
                WriteDiagnostic("HUD closing");
                _closeTimer?.Stop();
                _closeTimer?.Dispose();
                _closeTimer = null;
                _observer.Dispose();
                WriteDiagnostic(
                    "run summary scans=" + _scanCount
                    + " skipped=" + _skippedCount
                    + " commits=" + _presenter.CommitCount
                    + " created=" + _rowsCreatedTotal
                    + " updated=" + _rowsUpdatedTotal
                    + " removed=" + _rowsRemovedTotal
                    + " reordered=" + _rowsReorderedTotal
                    + " resized=" + _windowResizeCount
                    + " screenshots=" + _screenshotCount
                    + " observer_starts=" + _observerStartCount);
            };
        }

        protected override bool ShowWithoutActivation => true;

        protected override CreateParams CreateParams
        {
            get
            {
                var parameters = base.CreateParams;
                parameters.ExStyle |= WsExNoActivate | WsExToolWindow;
                return parameters;
            }
        }

        protected override void WndProc(ref Message message)
        {
            if (message.Msg == WmMouseActivate)
            {
                message.Result = new IntPtr(MaNoActivate);
                return;
            }

            base.WndProc(ref message);
        }

        protected override void OnPaint(PaintEventArgs eventArgs)
        {
            base.OnPaint(eventArgs);
            using var pen = new Pen(HudColors.Border);
            eventArgs.Graphics.DrawRectangle(pen, 0, 0, ClientSize.Width - 1, ClientSize.Height - 1);
        }

        private Panel BuildHeader()
        {
            var header = new Panel
            {
                BackColor = HudColors.Header,
                Dock = DockStyle.Top,
                Height = HudMetrics.HeaderHeight
            };
            var title = new Label
            {
                AutoSize = true,
                Font = new Font("Segoe UI Semibold", 9F, FontStyle.Bold, GraphicsUnit.Point),
                ForeColor = HudColors.Text,
                Location = new Point(12, 8),
                Text = "ATTENTION"
            };
            var close = new Button
            {
                AccessibleName = "Close ATTENTION HUD",
                BackColor = HudColors.Header,
                Cursor = Cursors.Hand,
                FlatStyle = FlatStyle.Flat,
                Font = new Font("Segoe UI", 12F, FontStyle.Regular, GraphicsUnit.Point),
                ForeColor = HudColors.Muted,
                Location = new Point(HudMetrics.WindowWidth - 38, 1),
                Size = new Size(32, 30),
                TabStop = false,
                Text = "\u00D7",
                UseVisualStyleBackColor = false
            };
            close.FlatAppearance.BorderSize = 0;
            close.Click += (_, __) => Close();
            close.MouseEnter += (_, __) => close.ForeColor = HudColors.Text;
            close.MouseLeave += (_, __) => close.ForeColor = HudColors.Muted;
            new ToolTip().SetToolTip(close, "Close");

            header.Controls.Add(title);
            header.Controls.Add(close);
            AttachDrag(header);
            AttachDrag(title);
            return header;
        }

        private void AttachDrag(Control control)
        {
            control.MouseDown += (_, eventArgs) =>
            {
                if (eventArgs.Button != MouseButtons.Left)
                {
                    return;
                }

                _dragging = true;
                _dragStart = Cursor.Position;
                _windowStart = Location;
            };
            control.MouseMove += (_, eventArgs) =>
            {
                if (!_dragging || eventArgs.Button != MouseButtons.Left)
                {
                    return;
                }

                var cursor = Cursor.Position;
                Location = new Point(
                    _windowStart.X + cursor.X - _dragStart.X,
                    _windowStart.Y + cursor.Y - _dragStart.Y);
            };
            control.MouseUp += (_, __) => _dragging = false;
        }

        private void HandleScan(ObserverScan scan)
        {
            WriteDiagnostic("scan event sessions=" + scan.SessionCount);
            if (IsDisposed || Disposing || !IsHandleCreated)
            {
                return;
            }

            try
            {
                BeginInvoke(new Action(() =>
                {
                    try
                    {
                        RenderScan(scan);
                    }
                    catch (Exception error)
                    {
                        WriteQaError("render", error);
                        WriteDiagnostic("render error=" + error.Message);
                    }
                }));
            }
            catch (InvalidOperationException)
            {
            }
        }

        private void HandleStatus(ObserverSourceState state, string detail)
        {
            if (IsDisposed || Disposing || !IsHandleCreated)
            {
                return;
            }

            try
            {
                BeginInvoke(new Action(() =>
                {
                    switch (state)
                    {
                        case ObserverSourceState.Live:
                            if (HudStatusPolicy.IsRedundantLive(_sourceState, _observerUnavailable))
                            {
                                return;
                            }

                            _sourceState = ObserverSourceState.Live;
                            _observerUnavailable = false;
                            break;
                        case ObserverSourceState.Starting:
                            _sourceState = ObserverSourceState.Starting;
                            break;
                        default:
                            _sourceState = state;
                            if (_observerUnavailable)
                            {
                                return;
                            }

                            WriteDiagnostic("observer unavailable detail=" + detail);
                            _observerUnavailable = true;
                            CommitStatusModel();
                            break;
                    }
                }));
            }
            catch (InvalidOperationException)
            {
            }
        }

        private void ApplyReplay()
        {
            WriteDiagnostic("replay start file=" + _options.ReplayFile);
            foreach (var line in File.ReadAllLines(_options.ReplayFile!))
            {
                if (string.IsNullOrWhiteSpace(line))
                {
                    continue;
                }

                if (ScanParser.TryParse(line, out var scan, out var parseError) && scan != null)
                {
                    RenderScan(scan);
                }
                else
                {
                    WriteDiagnostic("replay parse skipped error=" + (parseError ?? "non-scan"));
                }
            }

            WriteDiagnostic(
                "replay complete rows=" + _lastSessions.Count
                + " admitted=" + _admission.AdmittedCount);
        }

        private void RenderScan(ObserverScan scan)
        {
            _scanCount++;
            var selection = _admission.Apply(scan.Sessions, _options.MaxSessions);
            _lastSessions.Clear();
            _lastSessions.AddRange(selection.Visible);
            _sourceState = ObserverSourceState.Live;
            _observerUnavailable = false;
            var model = VisibleRenderModel.Create(_lastSessions, false);
            if (!CommitModel(model))
            {
                _skippedCount++;
                WriteDiagnostic(
                    "scan skipped unchanged rows=" + _lastSessions.Count
                    + " admitted=" + _admission.AdmittedCount);
                return;
            }

            var change = _presenter.LastChange;
            WriteDiagnostic(
                "scan rendered rows=" + _lastSessions.Count
                + " admitted=" + _admission.AdmittedCount
                + " created=" + change.Created
                + " updated=" + change.Updated
                + " removed=" + change.Removed
                + " reordered=" + change.Reordered
                + " lights=" + string.Join(",", _lastSessions.Select(item => item.Light.ToString().ToLowerInvariant()))
                + " names=" + string.Join(" | ", _lastSessions.Select(item => item.DisplayName))
                + " meta=" + string.Join(" | ", _lastSessions.Select(item => item.MetaText))
                + " evidence=" + string.Join(",", _lastSessions.Select(item => item.IsStale ? "no-recent-evidence" : item.EvidenceFreshness)));
        }

        private void CommitStatusModel()
        {
            var model = VisibleRenderModel.Create(_lastSessions, _observerUnavailable);
            CommitModel(model);
        }

        private bool CommitModel(VisibleRenderModel model)
        {
            if (!_presenter.Commit(model))
            {
                return false;
            }

            var change = _presenter.LastChange;
            _rowsCreatedTotal += change.Created;
            _rowsUpdatedTotal += change.Updated;
            _rowsRemovedTotal += change.Removed;
            _rowsReorderedTotal += change.Reordered;
            ApplyWindowSize(model);
            SaveScreenshot();
            return true;
        }

        private void ApplyWindowSize(VisibleRenderModel model)
        {
            var next = HudLayout.ClientSizeFor(_header.Height, model.Rows.Count, model.ObserverUnavailable);
            if (ClientSize != next)
            {
                ClientSize = next;
                _windowResizeCount++;
                WriteDiagnostic("window resized width=" + next.Width + " height=" + next.Height);
            }
        }

        private void SaveScreenshot()
        {
            if (string.IsNullOrWhiteSpace(_options.ScreenshotFile))
            {
                return;
            }

            try
            {
                var path = Path.GetFullPath(_options.ScreenshotFile);
                var directory = Path.GetDirectoryName(path);
                if (!string.IsNullOrWhiteSpace(directory))
                {
                    Directory.CreateDirectory(directory);
                }

                using var bitmap = new Bitmap(Width, Height);
                DrawToBitmap(bitmap, new Rectangle(Point.Empty, Size));
                bitmap.Save(path, ImageFormat.Png);
                _screenshotCount++;
                WriteDiagnostic("screenshot saved=" + path);
            }
            catch (Exception error)
            {
                WriteQaError("screenshot", error);
            }
        }

        private void WriteQaError(string stage, Exception error)
        {
            if (string.IsNullOrWhiteSpace(_options.ScreenshotFile))
            {
                return;
            }

            try
            {
                File.WriteAllText(_options.ScreenshotFile + ".error.txt", stage + ": " + error);
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
        }

        private void LogObserverMessage(string message)
        {
            if (message.StartsWith("observer started pid=", StringComparison.Ordinal))
            {
                _observerStartCount++;
            }

            WriteDiagnostic(message);
        }

        private void WriteDiagnostic(string message)
        {
            if (string.IsNullOrWhiteSpace(_options.DiagnosticLog))
            {
                return;
            }

            try
            {
                var path = Path.GetFullPath(_options.DiagnosticLog);
                var directory = Path.GetDirectoryName(path);
                if (!string.IsNullOrWhiteSpace(directory))
                {
                    Directory.CreateDirectory(directory);
                }

                lock (_logLock)
                {
                    File.AppendAllText(path, DateTimeOffset.UtcNow.ToString("O") + " " + message + Environment.NewLine);
                }
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
        }

        private void PlaceAtTopRight()
        {
            var area = Screen.FromPoint(Cursor.Position).WorkingArea;
            Location = new Point(area.Right - Width - 18, area.Top + 18);
        }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool SetWindowPos(
            IntPtr window,
            IntPtr insertAfter,
            int x,
            int y,
            int width,
            int height,
            uint flags);
    }

    internal static class HudMetrics
    {
        public const int WindowWidth = 392;
        public const int HeaderHeight = 32;
    }

    internal static class HudLayout
    {
        public static Size ClientSizeFor(int headerHeight, int sessionCount, bool unavailable)
        {
            var listHeight = 0;
            if (unavailable)
            {
                listHeight += ObserverUnavailableRow.RowHeight;
            }

            listHeight += sessionCount * SessionRowControl.RowHeight;
            return new Size(HudMetrics.WindowWidth, headerHeight + listHeight);
        }
    }

    internal sealed class DoubleBufferedFlowLayoutPanel : FlowLayoutPanel
    {
        public DoubleBufferedFlowLayoutPanel()
        {
            DoubleBuffered = true;
            ResizeRedraw = true;
            SetStyle(
                ControlStyles.AllPaintingInWmPaint
                | ControlStyles.OptimizedDoubleBuffer,
                true);
            UpdateStyles();
        }
    }

    internal struct RowChangeStats
    {
        public int Created;
        public int Updated;
        public int Removed;
        public int Reordered;
    }

    internal sealed class SessionListPresenter
    {
        private readonly FlowLayoutPanel _list;
        private readonly Dictionary<string, SessionRowControl> _rows =
            new Dictionary<string, SessionRowControl>(StringComparer.Ordinal);
        private ObserverUnavailableRow? _unavailable;
        private string _fingerprint = string.Empty;

        public SessionListPresenter(FlowLayoutPanel list)
        {
            _list = list;
        }

        public int CommitCount { get; private set; }

        public RowChangeStats LastChange { get; private set; }

        public bool Commit(VisibleRenderModel model)
        {
            if (string.Equals(model.Fingerprint, _fingerprint, StringComparison.Ordinal))
            {
                return false;
            }

            Apply(model);
            _fingerprint = model.Fingerprint;
            CommitCount++;
            return true;
        }

        private void Apply(VisibleRenderModel model)
        {
            var stats = new RowChangeStats();
            _list.SuspendLayout();
            var structural = false;
            try
            {
                structural |= ApplyUnavailable(model.ObserverUnavailable);
                structural |= ApplySessionSet(model.Rows, ref stats);
                structural |= ApplyOrder(model, ref stats);
            }
            finally
            {
                _list.ResumeLayout(structural);
            }

            LastChange = stats;
        }

        private bool ApplyUnavailable(bool show)
        {
            if (show)
            {
                if (_unavailable != null)
                {
                    return false;
                }

                _unavailable = new ObserverUnavailableRow();
                _list.Controls.Add(_unavailable);
                return true;
            }

            if (_unavailable == null)
            {
                return false;
            }

            _list.Controls.Remove(_unavailable);
            _unavailable.Dispose();
            _unavailable = null;
            return true;
        }

        private bool ApplySessionSet(IReadOnlyList<SessionItem> rows, ref RowChangeStats stats)
        {
            var structural = false;
            var desired = new HashSet<string>(StringComparer.Ordinal);
            for (var index = 0; index < rows.Count; index++)
            {
                desired.Add(rows[index].Identity);
            }

            var removed = new List<string>();
            foreach (var pair in _rows)
            {
                if (!desired.Contains(pair.Key))
                {
                    removed.Add(pair.Key);
                }
            }

            foreach (var identity in removed)
            {
                var control = _rows[identity];
                _list.Controls.Remove(control);
                control.Dispose();
                _rows.Remove(identity);
                stats.Removed++;
                structural = true;
            }

            for (var index = 0; index < rows.Count; index++)
            {
                var item = rows[index];
                var alternate = index % 2 == 1;
                if (_rows.TryGetValue(item.Identity, out var existing))
                {
                    if (existing.Bind(item, index, alternate))
                    {
                        stats.Updated++;
                    }

                    continue;
                }

                var created = new SessionRowControl(item, index, alternate);
                _rows[item.Identity] = created;
                _list.Controls.Add(created);
                stats.Created++;
                structural = true;
            }

            return structural;
        }

        private bool ApplyOrder(VisibleRenderModel model, ref RowChangeStats stats)
        {
            var baseIndex = _unavailable != null ? 1 : 0;
            var wrong = _unavailable != null && _list.Controls.GetChildIndex(_unavailable) != 0;
            if (!wrong)
            {
                for (var index = 0; index < model.Rows.Count; index++)
                {
                    var control = _rows[model.Rows[index].Identity];
                    if (_list.Controls.GetChildIndex(control) != baseIndex + index)
                    {
                        wrong = true;
                        break;
                    }
                }
            }

            if (!wrong)
            {
                return false;
            }

            if (_unavailable != null)
            {
                _list.Controls.SetChildIndex(_unavailable, 0);
            }

            for (var index = 0; index < model.Rows.Count; index++)
            {
                var control = _rows[model.Rows[index].Identity];
                var target = baseIndex + index;
                if (_list.Controls.GetChildIndex(control) != target)
                {
                    _list.Controls.SetChildIndex(control, target);
                    stats.Reordered++;
                }
            }

            return true;
        }
    }

    internal sealed class ObserverUnavailableRow : UserControl
    {
        public const int RowHeight = 36;

        public ObserverUnavailableRow()
        {
            DoubleBuffered = true;
            SetStyle(
                ControlStyles.AllPaintingInWmPaint
                | ControlStyles.OptimizedDoubleBuffer
                | ControlStyles.ResizeRedraw,
                true);
            SetStyle(ControlStyles.Selectable, false);
            AccessibleName = "Observer unavailable";
            BackColor = HudColors.Row;
            Height = RowHeight;
            Margin = Padding.Empty;
            TabStop = false;
            Width = HudMetrics.WindowWidth;

            var light = new TrafficLightGlyph(TrafficLight.Red)
            {
                Location = new Point(12, 10)
            };
            Controls.Add(light);

            var label = new Label
            {
                AutoEllipsis = true,
                Font = new Font("Segoe UI Semibold", 9F, FontStyle.Bold, GraphicsUnit.Point),
                ForeColor = HudColors.Text,
                Location = new Point(32, 8),
                Size = new Size(HudMetrics.WindowWidth - 44, 20),
                Text = "Observer unavailable"
            };
            Controls.Add(label);
        }
    }

    internal sealed class SessionRowControl : UserControl
    {
        public const int RowHeight = 56;
        public const int NameLineHeight = 25;
        public const int MetaLineHeight = 23;

        private readonly TrafficLightGlyph _light;
        private readonly Label _name;
        private readonly Label _meta;
        private readonly ToolTip _tooltip = new ToolTip();
        private string _boundFingerprint = string.Empty;
        private string _tooltipText = string.Empty;

        public SessionRowControl(SessionItem item, int position, bool alternate)
        {
            DoubleBuffered = true;
            SetStyle(
                ControlStyles.AllPaintingInWmPaint
                | ControlStyles.OptimizedDoubleBuffer
                | ControlStyles.ResizeRedraw,
                true);
            SetStyle(ControlStyles.Selectable, false);
            Height = RowHeight;
            Margin = Padding.Empty;
            TabStop = false;
            Width = HudMetrics.WindowWidth;

            _light = new TrafficLightGlyph(item.Light)
            {
                Location = new Point(12, 10)
            };
            Controls.Add(_light);

            _name = new Label
            {
                AutoEllipsis = true,
                Font = new Font("Segoe UI Semibold", 9F, FontStyle.Bold, GraphicsUnit.Point),
                ForeColor = HudColors.Text,
                Location = new Point(32, 3),
                Size = new Size(HudMetrics.WindowWidth - 44, NameLineHeight),
                TextAlign = ContentAlignment.MiddleLeft,
                UseCompatibleTextRendering = false
            };
            Controls.Add(_name);

            _meta = new Label
            {
                AutoEllipsis = true,
                Font = new Font("Segoe UI", 8.5F, FontStyle.Regular, GraphicsUnit.Point),
                ForeColor = HudColors.Muted,
                Location = new Point(32, 28),
                Size = new Size(HudMetrics.WindowWidth - 44, MetaLineHeight),
                TextAlign = ContentAlignment.MiddleLeft,
                UseCompatibleTextRendering = false
            };
            Controls.Add(_meta);

            Bind(item, position, alternate);
        }

        public string SessionIdentity { get; private set; } = string.Empty;

        public TrafficLight BoundLight
        {
            get { return _light.Light; }
        }

        public bool Bind(SessionItem item, int position, bool alternate)
        {
            var fingerprint = VisibleRenderModel.RowFingerprint(position, item);
            if (string.Equals(_boundFingerprint, fingerprint, StringComparison.Ordinal))
            {
                return false;
            }

            _boundFingerprint = fingerprint;
            SessionIdentity = item.Identity;
            var back = alternate ? HudColors.RowAlternate : HudColors.Row;
            if (BackColor != back)
            {
                BackColor = back;
                _light.Invalidate();
            }

            if (AccessibleName != item.DisplayName)
            {
                AccessibleName = item.DisplayName;
            }

            if (AccessibleDescription != item.MetaText)
            {
                AccessibleDescription = item.MetaText;
            }

            _light.Light = item.Light;
            if (_name.Text != item.DisplayName)
            {
                _name.Text = item.DisplayName;
            }

            if (_meta.Text != item.MetaText)
            {
                _meta.Text = item.MetaText;
            }

            if (_tooltipText != item.DebugTooltip)
            {
                _tooltipText = item.DebugTooltip;
                _tooltip.SetToolTip(this, _tooltipText);
                _tooltip.SetToolTip(_name, _tooltipText);
                _tooltip.SetToolTip(_meta, _tooltipText);
            }

            return true;
        }
    }

    internal sealed class TrafficLightGlyph : Control
    {
        private TrafficLight _light;

        public TrafficLightGlyph(TrafficLight light)
        {
            SetStyle(
                ControlStyles.AllPaintingInWmPaint
                | ControlStyles.OptimizedDoubleBuffer
                | ControlStyles.ResizeRedraw
                | ControlStyles.UserPaint
                | ControlStyles.Selectable,
                true);
            SetStyle(ControlStyles.Selectable, false);
            _light = light;
            Size = new Size(16, 16);
            TabStop = false;
        }

        [System.ComponentModel.DesignerSerializationVisibility(
            System.ComponentModel.DesignerSerializationVisibility.Hidden)]
        public TrafficLight Light
        {
            get { return _light; }
            set
            {
                if (_light == value)
                {
                    return;
                }

                _light = value;
                Invalidate();
            }
        }

        protected override void OnPaint(PaintEventArgs eventArgs)
        {
            eventArgs.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            eventArgs.Graphics.Clear(Parent?.BackColor ?? HudColors.Row);
            var bounds = new Rectangle(1, 1, Width - 2, Height - 2);
            using var fill = new SolidBrush(HudColors.ForLight(_light));
            eventArgs.Graphics.FillEllipse(fill, bounds);
            using var rim = new Pen(Color.FromArgb(70, 0, 0, 0));
            eventArgs.Graphics.DrawEllipse(rim, bounds);
        }
    }

    internal static class HudColors
    {
        public static readonly Color Background = Color.FromArgb(20, 22, 25);
        public static readonly Color Header = Color.FromArgb(31, 34, 39);
        public static readonly Color Row = Color.FromArgb(25, 28, 32);
        public static readonly Color RowAlternate = Color.FromArgb(28, 31, 35);
        public static readonly Color Border = Color.FromArgb(53, 58, 65);
        public static readonly Color Text = Color.FromArgb(239, 242, 245);
        public static readonly Color Muted = Color.FromArgb(153, 163, 174);
        public static readonly Color Red = Color.FromArgb(227, 66, 52);
        public static readonly Color Yellow = Color.FromArgb(240, 186, 46);
        public static readonly Color Green = Color.FromArgb(46, 173, 88);

        public static Color ForLight(TrafficLight light)
        {
            switch (light)
            {
                case TrafficLight.Red:
                    return Red;
                case TrafficLight.Yellow:
                    return Yellow;
                default:
                    return Green;
            }
        }
    }
}
