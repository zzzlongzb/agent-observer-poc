using System;
using System.IO;
using System.Threading;
using System.Windows.Forms;

namespace AgentObserver.Hud
{
    internal static class Program
    {
        private const string SingleInstanceMutexName = @"Local\AgentObserver.Hud.SingleInstance.v1";

        [STAThread]
        private static int Main(string[] args)
        {
            HudOptions options;
            try
            {
                options = HudOptions.Parse(args);
            }
            catch (ArgumentException error)
            {
                Console.Error.WriteLine(error.Message);
                return 2;
            }

            if (options.SelfTest)
            {
                return HudSelfTests.Run();
            }

            // Single-instance guard: a second double-click must not start a
            // second Observer or show a second HUD. It exits quietly instead.
            Mutex? singleInstance = null;
            try
            {
                singleInstance = new Mutex(initiallyOwned: true, SingleInstanceMutexName, out var createdNew);
                if (!createdNew)
                {
                    return 0;
                }
            }
            catch (UnauthorizedAccessException)
            {
                // The named mutex exists but belongs to this user's session in a
                // state we cannot own; treat it as "another instance is running".
                return 0;
            }
            catch (WaitHandleCannotBeOpenedException)
            {
                // Fall through and run without the guard rather than blocking the HUD.
                singleInstance = null;
            }

            try
            {
                Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new HudForm(options));
                return 0;
            }
            finally
            {
                try
                {
                    singleInstance?.ReleaseMutex();
                }
                catch (ApplicationException)
                {
                }

                singleInstance?.Dispose();
            }
        }
    }

    internal sealed class HudOptions
    {
        public string ObserverExecutable { get; private set; } = string.Empty;
        public int MaxSessions { get; private set; } = 8;
        public string? ScreenshotFile { get; private set; }
        public string? DiagnosticLog { get; private set; }
        public string? ReplayFile { get; private set; }
        public int? CloseAfterMs { get; private set; }
        public bool SelfTest { get; private set; }

        public static HudOptions Parse(string[] args)
        {
            var options = new HudOptions();
            for (var index = 0; index < args.Length; index++)
            {
                switch (args[index])
                {
                    case "--observer-exe":
                        options.ObserverExecutable = RequiredValue(args, ref index, "--observer-exe");
                        break;
                    case "--max-sessions":
                        var raw = RequiredValue(args, ref index, "--max-sessions");
                        if (!int.TryParse(raw, out var maximum) || maximum < 1 || maximum > 20)
                        {
                            throw new ArgumentException("--max-sessions must be between 1 and 20");
                        }

                        options.MaxSessions = maximum;
                        break;
                    case "--self-test":
                        options.SelfTest = true;
                        break;
                    case "--screenshot-file":
                        options.ScreenshotFile = RequiredValue(args, ref index, "--screenshot-file");
                        break;
                    case "--diagnostic-log":
                        options.DiagnosticLog = RequiredValue(args, ref index, "--diagnostic-log");
                        break;
                    case "--replay-file":
                        options.ReplayFile = RequiredValue(args, ref index, "--replay-file");
                        break;
                    case "--close-after-ms":
                        var closeRaw = RequiredValue(args, ref index, "--close-after-ms");
                        if (!int.TryParse(closeRaw, out var closeAfter) || closeAfter < 1)
                        {
                            throw new ArgumentException("--close-after-ms must be a positive integer");
                        }

                        options.CloseAfterMs = closeAfter;
                        break;
                    default:
                        throw new ArgumentException("Unknown HUD argument: " + args[index]);
                }
            }

            if (!string.IsNullOrWhiteSpace(options.ReplayFile))
            {
                options.ReplayFile = Path.GetFullPath(options.ReplayFile);
                if (!File.Exists(options.ReplayFile))
                {
                    throw new ArgumentException("--replay-file not found: " + options.ReplayFile);
                }
            }

            if (string.IsNullOrWhiteSpace(options.ObserverExecutable))
            {
                options.ObserverExecutable = FindObserverExecutable();
            }

            return options;
        }

        private static string RequiredValue(string[] args, ref int index, string name)
        {
            index++;
            if (index >= args.Length || string.IsNullOrWhiteSpace(args[index]))
            {
                throw new ArgumentException(name + " requires a value");
            }

            return args[index];
        }

        private static string FindObserverExecutable()
        {
            var fromEnvironment = Environment.GetEnvironmentVariable("AGENT_OBSERVER_EXE");
            if (!string.IsNullOrWhiteSpace(fromEnvironment))
            {
                return fromEnvironment;
            }

            var packaged = Path.Combine(AppContext.BaseDirectory, "agent-observer-poc.exe");
            if (File.Exists(packaged))
            {
                return packaged;
            }

            var current = new DirectoryInfo(AppContext.BaseDirectory);
            for (var depth = 0; depth < 10 && current != null; depth++, current = current.Parent)
            {
                var candidate = Path.Combine(current.FullName, "target", "debug", "agent-observer-poc.exe");
                if (File.Exists(candidate))
                {
                    return candidate;
                }
            }

            return "agent-observer-poc.exe";
        }
    }
}
