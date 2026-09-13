using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace AgentObserver.Hud
{
    internal enum ObserverSourceState
    {
        Starting,
        Live,
        Offline,
        Error
    }

    internal sealed class ObserverProcessClient : IDisposable
    {
        private readonly string _executable;
        private readonly Action<string> _log;
        private readonly object _processLock = new object();
        private CancellationTokenSource? _cancellation;
        private Process? _process;
        private Task? _worker;
        private bool _livePublished;

        public ObserverProcessClient(string executable, Action<string> log)
        {
            _executable = executable;
            _log = log;
        }

        public event Action<ObserverScan>? ScanReceived;
        public event Action<ObserverSourceState, string>? StatusChanged;

        internal static string[] DefaultWatchArguments()
        {
            return new[] { "watch", "--json", "--interval-secs", "1" };
        }

        public void Start()
        {
            if (_worker != null)
            {
                return;
            }

            _cancellation = new CancellationTokenSource();
            _worker = Task.Run(() => RunLoopAsync(_cancellation.Token));
        }

        private async Task RunLoopAsync(CancellationToken cancellationToken)
        {
            var retry = 0;
            while (!cancellationToken.IsCancellationRequested)
            {
                Process? process = null;
                var processStarted = false;
                var lastError = string.Empty;
                try
                {
                    RaiseStatus(ObserverSourceState.Starting, "Starting Observer");
                    var startInfo = new ProcessStartInfo
                    {
                        FileName = _executable,
                        UseShellExecute = false,
                        CreateNoWindow = true,
                        RedirectStandardOutput = true,
                        RedirectStandardError = true,
                        StandardOutputEncoding = new UTF8Encoding(false, true),
                        StandardErrorEncoding = new UTF8Encoding(false, true)
                    };
                    foreach (var argument in DefaultWatchArguments())
                    {
                        startInfo.ArgumentList.Add(argument);
                    }

                    process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
                    process.ErrorDataReceived += (_, eventArgs) =>
                    {
                        if (!string.IsNullOrWhiteSpace(eventArgs.Data))
                        {
                            lastError = eventArgs.Data;
                        }
                    };
                    if (!process.Start())
                    {
                        throw new InvalidOperationException("Observer process did not start");
                    }

                    processStarted = true;
                    _log("observer started pid=" + process.Id);

                    lock (_processLock)
                    {
                        _process = process;
                    }

                    process.BeginErrorReadLine();
                    while (!cancellationToken.IsCancellationRequested)
                    {
                        var line = await process.StandardOutput.ReadLineAsync().ConfigureAwait(false);
                        if (line == null)
                        {
                            break;
                        }

                        _log("observer stdout line bytes=" + line.Length);

                        if (ScanParser.TryParse(line, out var scan, out var parseError) && scan != null)
                        {
                            _log("observer scan sessions=" + scan.SessionCount);
                            retry = 0;
                            RaiseStatus(ObserverSourceState.Live, "Observer live");
                            ScanReceived?.Invoke(scan);
                        }
                        else if (!string.IsNullOrWhiteSpace(parseError))
                        {
                            _log("observer parse error=" + parseError);
                            RaiseStatus(ObserverSourceState.Error, "Invalid Observer JSONL");
                        }
                    }

                    if (!cancellationToken.IsCancellationRequested)
                    {
                        var detail = process.HasExited
                            ? "Observer exited with code " + process.ExitCode
                            : "Observer stream closed";
                        if (!string.IsNullOrWhiteSpace(lastError))
                        {
                            detail += ": " + lastError;
                        }

                        RaiseStatus(ObserverSourceState.Offline, detail);
                    }
                }
                catch (Exception error) when (
                    error is Win32Exception ||
                    error is IOException ||
                    error is InvalidOperationException ||
                    error is DecoderFallbackException)
                {
                    _log("observer exception=" + error);
                    if (!cancellationToken.IsCancellationRequested)
                    {
                        RaiseStatus(ObserverSourceState.Offline, error.Message);
                    }
                }
                finally
                {
                    lock (_processLock)
                    {
                        if (ReferenceEquals(_process, process))
                        {
                            _process = null;
                        }
                    }

                    if (processStarted && process != null && !process.HasExited)
                    {
                        try
                        {
                            process.Kill(true);
                        }
                        catch (InvalidOperationException)
                        {
                        }
                        catch (Win32Exception)
                        {
                        }
                    }

                    process?.Dispose();
                }

                if (cancellationToken.IsCancellationRequested)
                {
                    break;
                }

                retry = Math.Min(retry + 1, 4);
                var delay = TimeSpan.FromSeconds(Math.Min(10, 1 << retry));
                try
                {
                    await Task.Delay(delay, cancellationToken).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    break;
                }
            }
        }

        private void RaiseStatus(ObserverSourceState state, string detail)
        {
            if (state == ObserverSourceState.Live)
            {
                if (_livePublished)
                {
                    return;
                }

                _livePublished = true;
            }
            else
            {
                _livePublished = false;
            }

            StatusChanged?.Invoke(state, detail);
        }

        public void Dispose()
        {
            _cancellation?.Cancel();
            lock (_processLock)
            {
                if (_process != null && !_process.HasExited)
                {
                    try
                    {
                        _process.Kill(true);
                        _process.WaitForExit(3000);
                    }
                    catch (InvalidOperationException)
                    {
                    }
                    catch (Win32Exception)
                    {
                    }
                }
            }

            _cancellation?.Dispose();
        }
    }
}
