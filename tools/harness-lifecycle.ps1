Set-StrictMode -Version Latest

function Initialize-HarnessJobType {
    if ("AgentObserverHarness.SafeProcessLauncher" -as [type]) {
        return
    }

    # C# is kept C#5-compatible: PowerShell 5.1 compiles Add-Type sources with
    # the legacy C# 5 compiler.
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace AgentObserverHarness
{
    public sealed class KillOnCloseJob : IDisposable
    {
        private IntPtr handle;

        // Read-only access to the raw job handle. Ownership stays with this
        // object; SafeProcessLauncher only borrows it for AssignProcessToJobObject
        // and never closes it.
        public IntPtr Handle { get { return handle; } }

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public long Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IO_COUNTERS
        {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateJobObject(IntPtr attributes, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(
            IntPtr job,
            int informationClass,
            ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION information,
            uint informationLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        public KillOnCloseJob()
        {
            handle = CreateJobObject(IntPtr.Zero, null);
            if (handle == IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateJobObject failed");

            var information = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            information.BasicLimitInformation.LimitFlags = 0x00002000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            uint length = (uint)Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
            if (!SetInformationJobObject(handle, 9, ref information, length))
            {
                int error = Marshal.GetLastWin32Error();
                CloseHandle(handle);
                handle = IntPtr.Zero;
                throw new Win32Exception(error, "SetInformationJobObject failed");
            }
        }

        public void Assign(int processId)
        {
            if (handle == IntPtr.Zero)
                throw new ObjectDisposedException("KillOnCloseJob");
            using (Process process = Process.GetProcessById(processId))
            {
                if (!AssignProcessToJobObject(handle, process.Handle))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "AssignProcessToJobObject failed");
            }
        }

        public void Dispose()
        {
            if (handle == IntPtr.Zero)
                return;
            CloseHandle(handle);
            handle = IntPtr.Zero;
            GC.SuppressFinalize(this);
        }

        ~KillOnCloseJob()
        {
            Dispose();
        }
    }

    // Per-stream drain state for a launched process. Both stdout and stderr are
    // drained concurrently from process start into a bounded in-memory capture
    // plus an optional bounded incremental log file. Draining always continues
    // after the capture/log caps are reached so the child can never block on a
    // full pipe.
    internal sealed class HarnessDrainContext
    {
        public FileStream Stream;
        public FileStream Log;
        public StringBuilder Capture;
        public object Sync;
        public long LogBytes;
        public long TotalBytes;
        public bool Truncated;
        public bool LogTruncated;
        public int MaxCapture;
        public int MaxLog;
    }

    public sealed class LaunchedProcess : IDisposable
    {
        private IntPtr _processHandle;
        private HarnessDrainContext _stdoutContext;
        private HarnessDrainContext _stderrContext;
        private Thread _stdoutThread;
        private Thread _stderrThread;
        private bool _disposed;

        public int ProcessId { get; private set; }
        public DateTime CreationTimeUtc { get; private set; }
        public int MaxCaptureBytes { get; private set; }

        internal LaunchedProcess(IntPtr processHandle, int processId, DateTime creationTimeUtc,
            FileStream stdoutStream, FileStream stderrStream, FileStream stdoutLog, FileStream stderrLog,
            int maxCaptureBytes, int maxLogBytes)
        {
            _processHandle = processHandle;
            ProcessId = processId;
            CreationTimeUtc = creationTimeUtc;
            MaxCaptureBytes = maxCaptureBytes;
            _stdoutContext = SafeProcessLauncher.MakeDrainContext(stdoutStream, stdoutLog, maxCaptureBytes, maxLogBytes);
            _stderrContext = SafeProcessLauncher.MakeDrainContext(stderrStream, stderrLog, maxCaptureBytes, maxLogBytes);
            if (stdoutStream != null)
            {
                _stdoutThread = new Thread(new ParameterizedThreadStart(SafeProcessLauncher.DrainLoop));
                _stdoutThread.IsBackground = true;
                _stdoutThread.Start(_stdoutContext);
            }
            if (stderrStream != null)
            {
                _stderrThread = new Thread(new ParameterizedThreadStart(SafeProcessLauncher.DrainLoop));
                _stderrThread.IsBackground = true;
                _stderrThread.Start(_stderrContext);
            }
        }

        public bool HasExited { get { return WaitForExit(0); } }

        public bool WaitForExit(int millisecondsTimeout)
        {
            if (_processHandle == IntPtr.Zero)
                throw new ObjectDisposedException("LaunchedProcess");
            int result = SafeProcessLauncher.WaitForSingleObject(_processHandle, millisecondsTimeout);
            if (result == 0)
                return true;
            if (result == SafeProcessLauncher.WAIT_TIMEOUT)
                return false;
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        public int ExitCode
        {
            get
            {
                if (!WaitForExit(0))
                    throw new InvalidOperationException("Process " + ProcessId + " has not exited; refusing to read ExitCode");
                int code;
                if (!SafeProcessLauncher.GetExitCodeProcess(_processHandle, out code))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                return code;
            }
        }

        public string Stdout
        {
            get { lock (_stdoutContext.Sync) { return _stdoutContext.Capture.ToString(); } }
        }

        public string Stderr
        {
            get { lock (_stderrContext.Sync) { return _stderrContext.Capture.ToString(); } }
        }

        public bool StdoutTruncated { get { return _stdoutContext.Truncated; } }
        public bool StderrTruncated { get { return _stderrContext.Truncated; } }
        public bool StdoutCaptureTruncated { get { return _stdoutContext.Truncated; } }
        public bool StderrCaptureTruncated { get { return _stderrContext.Truncated; } }
        public bool StdoutLogTruncated { get { return _stdoutContext.LogTruncated; } }
        public bool StderrLogTruncated { get { return _stderrContext.LogTruncated; } }
        public long StdoutTotalBytes { get { return _stdoutContext.TotalBytes; } }
        public long StderrTotalBytes { get { return _stderrContext.TotalBytes; } }
        public long StdoutPersistedLogBytes { get { return _stdoutContext.LogBytes; } }
        public long StderrPersistedLogBytes { get { return _stderrContext.LogBytes; } }

        public bool WaitDrains(int millisecondsTimeout)
        {
            Stopwatch watch = Stopwatch.StartNew();
            if (_stdoutThread != null)
            {
                int remain = millisecondsTimeout - (int)watch.ElapsedMilliseconds;
                if (remain < 0) remain = 0;
                if (!_stdoutThread.Join(remain)) return false;
            }
            if (_stderrThread != null)
            {
                int remain = millisecondsTimeout - (int)watch.ElapsedMilliseconds;
                if (remain < 0) remain = 0;
                if (!_stderrThread.Join(remain)) return false;
            }
            return true;
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            WaitDrains(500);
            if (_stdoutContext != null)
            {
                try { if (_stdoutContext.Log != null) _stdoutContext.Log.Dispose(); } catch { }
                try { if (_stdoutContext.Stream != null) _stdoutContext.Stream.Dispose(); } catch { }
            }
            if (_stderrContext != null)
            {
                try { if (_stderrContext.Log != null) _stderrContext.Log.Dispose(); } catch { }
                try { if (_stderrContext.Stream != null) _stderrContext.Stream.Dispose(); } catch { }
            }
            if (_processHandle != IntPtr.Zero)
            {
                SafeProcessLauncher.CloseHandle(_processHandle);
                _processHandle = IntPtr.Zero;
            }
            GC.SuppressFinalize(this);
        }

        ~LaunchedProcess()
        {
            Dispose();
        }
    }

    // The single low-level process launcher of the local-package tool chain.
    // Contract (AGENTS.md rule 5): CreateProcessW(CREATE_SUSPENDED) ->
    // AssignProcessToJobObject(kill-on-close job) -> record PID + creation time
    // -> ResumeThread. The child executes no user code until it provably sits in
    // the job object, so every descendant it later spawns is job-owned. A process
    // that cannot be assigned, measured or resumed is terminated while still
    // suspended and the operation fails. All process, thread and pipe handles are
    // closed on success and failure paths; the job handle is only borrowed and
    // stays owned by the KillOnCloseJob caller. No token handles are opened.
    public static class SafeProcessLauncher
    {
        internal const int WAIT_TIMEOUT = 258;
        private const uint CREATE_SUSPENDED = 0x00000004;
        private const uint CREATE_NO_WINDOW = 0x08000000;
        private const uint STARTF_USESTDHANDLES = 0x00000100;
        private const uint STARTF_USESHOWWINDOW = 0x00000001;
        private const short SW_HIDE = 0;
        private const uint HANDLE_FLAG_INHERIT = 0x00000001;
        private const uint STD_INPUT_HANDLE = 4294967286; // (uint)-10
        private static readonly IntPtr INVALID_HANDLE_VALUE = new IntPtr(-1);

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct STARTUPINFO
        {
            public uint cb;
            public string lpReserved;
            public string lpDesktop;
            public string lpTitle;
            public uint dwX;
            public uint dwY;
            public uint dwXSize;
            public uint dwYSize;
            public uint dwXCountChars;
            public uint dwYCountChars;
            public uint dwFillAttribute;
            public uint dwFlags;
            public short wShowWindow;
            public short cbReserved2;
            public IntPtr lpReserved2;
            public IntPtr hStdInput;
            public IntPtr hStdOutput;
            public IntPtr hStdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PROCESS_INFORMATION
        {
            public IntPtr hProcess;
            public IntPtr hThread;
            public uint dwProcessId;
            public uint dwThreadId;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct SECURITY_ATTRIBUTES
        {
            public uint nLength;
            public IntPtr lpSecurityDescriptor;
            public bool bInheritHandle;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct FILETIME
        {
            public uint dwLowDateTime;
            public uint dwHighDateTime;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CreateProcessW(
            string lpApplicationName,
            string lpCommandLine,
            IntPtr lpProcessAttributes,
            IntPtr lpThreadAttributes,
            bool bInheritHandles,
            uint dwCreationFlags,
            IntPtr lpEnvironment,
            string lpCurrentDirectory,
            ref STARTUPINFO lpStartupInfo,
            out PROCESS_INFORMATION lpProcessInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint ResumeThread(IntPtr hThread);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateProcess(IntPtr hProcess, uint uExitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool CloseHandle(IntPtr handle);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern int WaitForSingleObject(IntPtr handle, int milliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool GetExitCodeProcess(IntPtr hProcess, out int lpExitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetProcessTimes(
            IntPtr hProcess,
            out FILETIME lpCreationTime,
            out FILETIME lpExitTime,
            out FILETIME lpKernelTime,
            out FILETIME lpUserTime);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CreatePipe(
            out IntPtr hReadPipe,
            out IntPtr hWritePipe,
            ref SECURITY_ATTRIBUTES lpPipeAttributes,
            uint nSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetHandleInformation(IntPtr hObject, uint dwMask, uint dwFlags);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr GetStdHandle(uint nStdHandle);

        internal static HarnessDrainContext MakeDrainContext(FileStream stream, FileStream log, int maxCapture, int maxLog)
        {
            HarnessDrainContext context = new HarnessDrainContext();
            context.Stream = stream;
            context.Log = log;
            context.Capture = new StringBuilder();
            context.Sync = new object();
            context.MaxCapture = maxCapture;
            context.MaxLog = maxLog;
            return context;
        }

        internal static void DrainLoop(object state)
        {
            HarnessDrainContext context = (HarnessDrainContext)state;
            if (context.Stream == null) return;
            byte[] buffer = new byte[16384];
            char[] chars = new char[16384];
            Decoder decoder = new UTF8Encoding(false).GetDecoder();
            try
            {
                int read;
                while ((read = context.Stream.Read(buffer, 0, buffer.Length)) > 0)
                {
                    context.TotalBytes += read;
                    int charCount = decoder.GetChars(buffer, 0, read, chars, 0);
                    lock (context.Sync)
                    {
                        if (charCount > 0)
                        {
                            if (context.Capture.Length < context.MaxCapture)
                            {
                                int remaining = context.MaxCapture - context.Capture.Length;
                                int take = (remaining < charCount) ? remaining : charCount;
                                context.Capture.Append(chars, 0, take);
                                if (take < charCount) context.Truncated = true;
                            }
                            else
                            {
                                context.Truncated = true;
                            }
                        }
                    }
                    // MaxLog is the absolute whole-file cap. Keep draining the
                    // pipe after the cap; never write past MaxLog.
                    if (context.Log != null)
                    {
                        if (context.LogBytes >= context.MaxLog)
                        {
                            context.LogTruncated = true;
                        }
                        else
                        {
                            try
                            {
                                long logRemaining = context.MaxLog - context.LogBytes;
                                int logTake = (read < logRemaining) ? read : (int)logRemaining;
                                if (logTake > 0)
                                {
                                    context.Log.Write(buffer, 0, logTake);
                                    context.LogBytes += logTake;
                                }
                                if (logTake < read)
                                    context.LogTruncated = true;
                            }
                            catch { context.Log = null; }
                        }
                    }
                }
            }
            catch { }
            try { if (context.Log != null) context.Log.Flush(); } catch { }
        }

        private static void TerminateStillSuspended(IntPtr processHandle)
        {
            // The process was never resumed (or its state cannot be proven), so it
            // owns nothing and cannot have spawned descendants. Terminate the
            // exact process before any handle is closed.
            TerminateProcess(processHandle, 1);
        }

        private static string QuoteArgument(string value)
        {
            if (string.IsNullOrEmpty(value))
                return "\"\"";
            if (value.IndexOf(' ') >= 0 || value.IndexOf('\t') >= 0)
                return "\"" + value + "\"";
            return value;
        }

        public static LaunchedProcess Start(
            string fileName,
            string arguments,
            string workingDirectory,
            IntPtr jobHandle,
            bool hideWindow,
            string stdoutLogPath,
            string stderrLogPath,
            int maxCaptureBytes,
            int maxLogBytes)
        {
            if (string.IsNullOrEmpty(fileName))
                throw new ArgumentException("fileName is required");
            if (jobHandle == IntPtr.Zero)
                throw new ArgumentException("jobHandle must be a live kill-on-close job object; a process may never be resumed without job ownership");
            if (maxCaptureBytes < 0) maxCaptureBytes = 0;
            if (maxLogBytes <= 0) maxLogBytes = 2097152;

            SECURITY_ATTRIBUTES pipeAttributes = new SECURITY_ATTRIBUTES();
            pipeAttributes.nLength = (uint)Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
            pipeAttributes.lpSecurityDescriptor = IntPtr.Zero;
            pipeAttributes.bInheritHandle = true;

            IntPtr stdoutRead = IntPtr.Zero;
            IntPtr stdoutWrite = IntPtr.Zero;
            IntPtr stderrRead = IntPtr.Zero;
            IntPtr stderrWrite = IntPtr.Zero;
            FileStream stdoutStream = null;
            FileStream stderrStream = null;
            FileStream stdoutLog = null;
            FileStream stderrLog = null;
            bool processCreated = false;
            PROCESS_INFORMATION processInfo = new PROCESS_INFORMATION();
            try
            {
                // Official evidence logs must use CreateNew: refuse if the file
                // already exists. Never FileMode.Append (that turned a 2 MiB
                // cap into 14 MiB across reused evidence roots).
                if (!string.IsNullOrEmpty(stdoutLogPath))
                    stdoutLog = new FileStream(stdoutLogPath, FileMode.CreateNew, FileAccess.Write, FileShare.Read);
                if (!string.IsNullOrEmpty(stderrLogPath))
                    stderrLog = new FileStream(stderrLogPath, FileMode.CreateNew, FileAccess.Write, FileShare.Read);

                if (!CreatePipe(out stdoutRead, out stdoutWrite, ref pipeAttributes, 0))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "CreatePipe(stdout) failed");
                if (!CreatePipe(out stderrRead, out stderrWrite, ref pipeAttributes, 0))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "CreatePipe(stderr) failed");
                // The parent's read ends must not leak into the child.
                SetHandleInformation(stdoutRead, HANDLE_FLAG_INHERIT, 0);
                SetHandleInformation(stderrRead, HANDLE_FLAG_INHERIT, 0);

                STARTUPINFO startupInfo = new STARTUPINFO();
                startupInfo.cb = (uint)Marshal.SizeOf(typeof(STARTUPINFO));
                startupInfo.dwFlags = STARTF_USESTDHANDLES;
                if (hideWindow)
                {
                    startupInfo.dwFlags |= STARTF_USESHOWWINDOW;
                    startupInfo.wShowWindow = SW_HIDE;
                }
                startupInfo.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
                if (startupInfo.hStdInput == IntPtr.Zero || startupInfo.hStdInput == INVALID_HANDLE_VALUE)
                    startupInfo.hStdInput = IntPtr.Zero;
                startupInfo.hStdOutput = stdoutWrite;
                startupInfo.hStdError = stderrWrite;

                string commandLine = QuoteArgument(fileName);
                if (!string.IsNullOrEmpty(arguments))
                    commandLine = commandLine + " " + arguments;

                uint creationFlags = CREATE_SUSPENDED;
                if (hideWindow)
                    creationFlags |= CREATE_NO_WINDOW;

                if (!CreateProcessW(null, commandLine, IntPtr.Zero, IntPtr.Zero, true, creationFlags, IntPtr.Zero,
                    string.IsNullOrEmpty(workingDirectory) ? null : workingDirectory,
                    ref startupInfo, out processInfo))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateProcessW failed for " + fileName);
                }
                processCreated = true;

                if (!AssignProcessToJobObject(jobHandle, processInfo.hProcess))
                {
                    int error = Marshal.GetLastWin32Error();
                    TerminateStillSuspended(processInfo.hProcess);
                    throw new Win32Exception(error, "AssignProcessToJobObject failed for PID " + processInfo.dwProcessId
                        + "; the still-suspended process was terminated and was never resumed");
                }

                FILETIME creation;
                FILETIME exitTime;
                FILETIME kernelTime;
                FILETIME userTime;
                if (!GetProcessTimes(processInfo.hProcess, out creation, out exitTime, out kernelTime, out userTime))
                {
                    int error = Marshal.GetLastWin32Error();
                    TerminateStillSuspended(processInfo.hProcess);
                    throw new Win32Exception(error, "GetProcessTimes failed for PID " + processInfo.dwProcessId
                        + "; the still-suspended process was terminated and was never resumed");
                }
                long creationFileTime = ((long)creation.dwHighDateTime << 32) | (long)(uint)creation.dwLowDateTime;
                DateTime creationTimeUtc = DateTime.FromFileTimeUtc(creationFileTime);

                uint previousSuspendCount = ResumeThread(processInfo.hThread);
                if (previousSuspendCount == 0xFFFFFFFF)
                {
                    int error = Marshal.GetLastWin32Error();
                    TerminateStillSuspended(processInfo.hProcess);
                    throw new Win32Exception(error, "ResumeThread failed for PID " + processInfo.dwProcessId
                        + "; the still-suspended process was terminated");
                }

                // Thread handle is no longer needed once the process is running.
                CloseHandle(processInfo.hThread);
                processInfo.hThread = IntPtr.Zero;

                // The parent must close its copies of the write ends so the drains
                // observe EOF once the child (and any descendant holding them) exits.
                CloseHandle(stdoutWrite);
                stdoutWrite = IntPtr.Zero;
                CloseHandle(stderrWrite);
                stderrWrite = IntPtr.Zero;

                stdoutStream = new FileStream(
                    new Microsoft.Win32.SafeHandles.SafeFileHandle(stdoutRead, true), FileAccess.Read, 16384, false);
                stdoutRead = IntPtr.Zero; // handle now owned by the FileStream
                stderrStream = new FileStream(
                    new Microsoft.Win32.SafeHandles.SafeFileHandle(stderrRead, true), FileAccess.Read, 16384, false);
                stderrRead = IntPtr.Zero;

                IntPtr processHandle = processInfo.hProcess;
                processInfo.hProcess = IntPtr.Zero; // ownership transferred to LaunchedProcess
                LaunchedProcess result = new LaunchedProcess(processHandle, (int)processInfo.dwProcessId, creationTimeUtc,
                    stdoutStream, stderrStream, stdoutLog, stderrLog, maxCaptureBytes, maxLogBytes);
                stdoutStream = null;
                stderrStream = null;
                stdoutLog = null;
                stderrLog = null;
                return result;
            }
            finally
            {
                // Failure path only: everything this method still owns is closed. A
                // created process that was not resumed is terminated first; a
                // resumed one is already inside the caller's kill-on-close job,
                // so terminating it here is still exact and safe.
                if (processCreated && processInfo.hProcess != IntPtr.Zero)
                {
                    TerminateProcess(processInfo.hProcess, 1);
                    CloseHandle(processInfo.hProcess);
                    processInfo.hProcess = IntPtr.Zero;
                }
                if (processInfo.hThread != IntPtr.Zero) CloseHandle(processInfo.hThread);
                if (stdoutWrite != IntPtr.Zero) CloseHandle(stdoutWrite);
                if (stderrWrite != IntPtr.Zero) CloseHandle(stderrWrite);
                if (stdoutRead != IntPtr.Zero) CloseHandle(stdoutRead);
                if (stderrRead != IntPtr.Zero) CloseHandle(stderrRead);
                if (stdoutStream != null) { try { stdoutStream.Dispose(); } catch { } }
                if (stderrStream != null) { try { stderrStream.Dispose(); } catch { } }
                if (stdoutLog != null) { try { stdoutLog.Dispose(); } catch { } }
                if (stderrLog != null) { try { stderrLog.Dispose(); } catch { } }
            }
        }
    }
}
'@
}

function Get-HarnessUnixMilliseconds {
    param([Parameter(Mandatory)][DateTime]$DateTime)
    ([DateTimeOffset]($DateTime.ToUniversalTime())).ToUnixTimeMilliseconds()
}

function Get-HarnessProperty {
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function Get-HarnessBlockedExitCode { 10 }

function ConvertTo-HarnessArgumentString {
    # Single source of truth for command-line quoting of launcher arguments.
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ArgumentList)
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($argument in $ArgumentList) {
        if ($null -eq $argument) { continue }
        if ($argument -match '\s') {
            [void]$parts.Add('"' + ($argument -replace '"', '\"') + '"')
        } else {
            [void]$parts.Add($argument)
        }
    }
    return ($parts -join ' ')
}

function New-HarnessBlockedResult {
    param([Parameter(Mandatory)][string]$Reason)
    $normalized = $Reason
    if ($normalized -notlike 'BLOCKED_BY_PROVIDER:*') {
        $normalized = "BLOCKED_BY_PROVIDER: $normalized"
    }
    [pscustomobject]@{
        status = 'BLOCKED'
        acceptance_pass = $false
        timed_out = $false
        failure_reason = $normalized
        automatic_retries = 0
    }
}

function Get-HarnessScenarioConfig {
    param([Parameter(Mandatory)][string]$Scenario)
    switch ($Scenario) {
        'normal' {
            return [pscustomobject]@{
                Scenario = 'normal'
                ModelCallBudget = 1
                DefaultTimeoutSeconds = 300
            }
        }
        'kill' {
            return [pscustomobject]@{
                Scenario = 'kill'
                ModelCallBudget = 1
                DefaultTimeoutSeconds = 180
            }
        }
        'restart-missed' {
            return [pscustomobject]@{
                Scenario = 'restart-missed'
                ModelCallBudget = 1
                DefaultTimeoutSeconds = 180
            }
        }
        'parallel' {
            return [pscustomobject]@{
                Scenario = 'parallel'
                ModelCallBudget = 2
                DefaultTimeoutSeconds = 300
            }
        }
        default {
            throw "Invalid scenario '$Scenario'. Valid scenarios are: normal, kill, restart-missed, parallel. 'all' is prohibited."
        }
    }
}

function Get-HarnessScenarioPlan {
    param([Parameter(Mandatory)][string]$Scenario)
    $cfg = Get-HarnessScenarioConfig -Scenario $Scenario
    $checkPoints = switch ($Scenario) {
        'normal' { @('after-run-before-result-ready') }
        'kill' { @('before-intentional-kill') }
        'restart-missed' { @('before-intentional-observer-kill') }
        'parallel' { @('before-second-call', 'both-invocations') }
    }
    [pscustomobject]@{
        Scenario = $Scenario
        ModelCallBudget = [int]$cfg.ModelCallBudget
        DefaultTimeoutSeconds = [int]$cfg.DefaultTimeoutSeconds
        InvokesNormal = ($Scenario -eq 'normal')
        InvokesKill = ($Scenario -eq 'kill')
        InvokesRestartMissed = ($Scenario -eq 'restart-missed')
        InvokesParallel = ($Scenario -eq 'parallel')
        StartsSecondModelCall = ($Scenario -eq 'parallel')
        IntentionalKill = ($Scenario -eq 'kill')
        IntentionalObserverKill = ($Scenario -eq 'restart-missed')
        ProviderFailureCheckPoints = @($checkPoints)
    }
}

function Assert-HarnessSupervisorInvocation {
    param(
        [bool]$AllowLiveScenario = $false,
        [string]$Scenario = '',
        [int]$ConfirmModelCallBudget = 0
    )
    if (-not $AllowLiveScenario) {
        if (-not [string]::IsNullOrWhiteSpace($Scenario)) {
            Get-HarnessScenarioConfig -Scenario $Scenario | Out-Null
        }
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($Scenario)) {
        throw 'Live scenario requires explicit -Scenario (one of normal, kill, restart-missed, parallel).'
    }
    $cfg = Get-HarnessScenarioConfig -Scenario $Scenario
    if ($ConfirmModelCallBudget -ne $cfg.ModelCallBudget) {
        throw "Scenario '$Scenario' requires -ConfirmModelCallBudget $($cfg.ModelCallBudget). Received $ConfirmModelCallBudget. Live invocation aborted."
    }
    $cfg
}

function Get-HarnessProviderFailureReason {
    param(
        [string[]]$ProtocolLines = @(),
        [string]$ProtocolText = '',
        [string]$StderrText = '',
        $Snapshot = $null,
        [object[]]$WatchRows = @()
    )

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($ProtocolLines)) {
        if ($null -ne $line) { [void]$lines.Add([string]$line) }
    }
    if ($ProtocolText) {
        foreach ($line in @($ProtocolText -split '\r?\n')) {
            [void]$lines.Add([string]$line)
        }
    }

    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $trim = $line.Trim()
        if ($trim -notmatch '^\{') { continue }
        $rec = $null
        try { $rec = $trim | ConvertFrom-Json } catch { continue }

        $type = [string](Get-HarnessProperty $rec 'type')
        $outcome = [string](Get-HarnessProperty $rec 'assistantOutcome')
        if (-not $outcome) { $outcome = [string](Get-HarnessProperty $rec 'assistant_outcome') }
        if ($type -eq 'agent_end' -and $outcome -eq 'failed') {
            return 'BLOCKED_BY_PROVIDER: agent_end assistantOutcome=failed'
        }
        $lineAttention = Get-HarnessProperty $rec 'attention_state'
        if (-not $lineAttention) { $lineAttention = Get-HarnessProperty $rec 'attentionState' }
        if ([string]$lineAttention -eq 'INTERRUPTED') {
            return 'BLOCKED_BY_PROVIDER: attention state INTERRUPTED'
        }

        $stopReason = Get-HarnessProperty $rec 'stopReason'
        if (-not $stopReason) {
            $stopReason = Get-HarnessProperty (Get-HarnessProperty $rec 'data') 'stopReason'
        }
        if ([string]$stopReason -eq 'error') {
            return 'BLOCKED_BY_PROVIDER: explicit provider error'
        }

        if ($type -eq 'error') {
            return 'BLOCKED_BY_PROVIDER: explicit provider error'
        }
        $err = Get-HarnessProperty $rec 'error'
        if ($null -ne $err -and [string]$err -ne '') {
            return 'BLOCKED_BY_PROVIDER: explicit provider error'
        }
    }

    $attentionObjects = New-Object System.Collections.Generic.List[object]
    if ($null -ne $Snapshot) { [void]$attentionObjects.Add($Snapshot) }
    foreach ($row in @($WatchRows)) {
        if ($null -ne $row) { [void]$attentionObjects.Add($row) }
    }
    foreach ($row in $attentionObjects) {
        $att = Get-HarnessProperty $row 'attention_state'
        if (-not $att) { $att = Get-HarnessProperty $row 'attentionState' }
        if ([string]$att -eq 'INTERRUPTED') {
            return 'BLOCKED_BY_PROVIDER: attention state INTERRUPTED'
        }
    }

    if ($StderrText -and ($StderrText -match '(?i)(provider (error|unavailable)|authentication (failed|error)|stopReason["\s:=]+error)')) {
        return 'BLOCKED_BY_PROVIDER: explicit provider error'
    }
    return $null
}

function New-HarnessScenarioSummary {
    param(
        [Parameter(Mandatory)][string]$Scenario,
        [Parameter(Mandatory)][string]$Status,
        [bool]$AcceptancePass = $false,
        [bool]$TimedOut = $false,
        [int]$ModelCallBudget = 0,
        [int]$ModelCallsStarted = 0,
        [string]$FailureReason = $null,
        [bool]$CleanupSuccess = $true,
        [int]$OwnedProcessesRemaining = 0,
        [string]$RunRoot = '',
        [double]$ElapsedSeconds = 0
    )
    if ($Status -eq 'BLOCKED') {
        $AcceptancePass = $false
        $TimedOut = $false
        if ($FailureReason -and $FailureReason -notlike 'BLOCKED_BY_PROVIDER:*') {
            $FailureReason = "BLOCKED_BY_PROVIDER: $FailureReason"
        }
    }
    if ($TimedOut) {
        $Status = 'FAIL'
        $AcceptancePass = $false
    }
    [ordered]@{
        scenario = $Scenario
        status = $Status
        acceptance_pass = [bool]$AcceptancePass
        model_call_budget = [int]$ModelCallBudget
        model_calls_started = [int]$ModelCallsStarted
        automatic_retries = 0
        elapsed_seconds = $ElapsedSeconds
        timed_out = [bool]$TimedOut
        failure_reason = $FailureReason
        cleanup_success = [bool]$CleanupSuccess
        owned_processes_remaining = [int]$OwnedProcessesRemaining
        run_root = $RunRoot
    }
}

function Resolve-HarnessAcceptanceClaim {
    param(
        [bool]$LiveAttempted = $false,
        [string]$Status = 'OFFLINE',
        [bool]$AcceptancePass = $false
    )
    if (-not $LiveAttempted) {
        $AcceptancePass = $false
        if ([string]::IsNullOrWhiteSpace($Status) -or $Status -eq 'PASS') {
            $Status = 'OFFLINE'
        }
    } elseif ($Status -eq 'BLOCKED' -or $Status -eq 'FAIL') {
        $AcceptancePass = $false
    } elseif ($Status -eq 'PASS' -and -not $AcceptancePass) {
        $Status = 'FAIL'
    } elseif ($Status -ne 'PASS') {
        $AcceptancePass = $false
    }
    [pscustomobject]@{
        status = $Status
        acceptance_pass = [bool]$AcceptancePass
        live_scenario_attempted = [bool]$LiveAttempted
    }
}

function Write-HarnessProgress {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Scenario,
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][int]$ModelCallBudget,
        [Parameter(Mandatory)][int]$ModelCallsStarted
    )
    $payload = [ordered]@{
        scenario = $Scenario
        stage = $Stage
        model_call_budget = $ModelCallBudget
        model_calls_started = $ModelCallsStarted
        updated_at = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $json = $payload | ConvertTo-Json -Compress
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $tmp = Join-Path $dir ('.progress.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($tmp, $json, $utf8)
    if (Test-Path -LiteralPath $Path) {
        $bak = $tmp + '.bak'
        [System.IO.File]::Replace($tmp, $Path, $bak)
        Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue
    } else {
        [System.IO.File]::Move($tmp, $Path)
    }
}

function Read-HarnessProgress {
    param(
        [string]$Path = '',
        $Fallback = $null
    )
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        return $Fallback
    }
    try {
        $raw = [System.IO.File]::ReadAllText($Path)
        if ([string]::IsNullOrWhiteSpace($raw)) { return $Fallback }
        $obj = $raw | ConvertFrom-Json
        if ($null -eq $obj) { return $Fallback }
        $calls = Get-HarnessProperty $obj 'model_calls_started'
        if ($null -eq $calls) { return $Fallback }
        [void][int]$calls
        return $obj
    } catch {
        return $Fallback
    }
}

function Update-HarnessProgressState {
    param([Parameter(Mandatory)]$Context)
    $progressFile = Get-HarnessProperty $Context 'ProgressFile'
    if (-not $progressFile) { return }
    $fallback = Get-HarnessProperty $Context 'LastValidProgress'
    $progress = Read-HarnessProgress -Path ([string]$progressFile) -Fallback $fallback
    if ($progress) {
        $Context.LastValidProgress = $progress
        try { $Context.ModelCallsStarted = [int]$progress.model_calls_started } catch { }
        $stage = Get-HarnessProperty $progress 'stage'
        if ($stage) { $Context.ProgressStage = [string]$stage }
    }
}

function New-HarnessLifecycle {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$RunRoot,
        [string]$Scenario = 'none',
        [int]$ModelCallsStarted = 0,
        [ValidateRange(1, 86400)][int]$OverallTimeoutSeconds = 900,
        [ValidateRange(1, 300)][int]$HeartbeatSeconds = 10,
        [string]$ProgressFile = '',
        [DateTimeOffset]$StartedAt = [DateTimeOffset]::MinValue,
        [DateTimeOffset]$AbsoluteDeadlineAt = [DateTimeOffset]::MinValue
    )

    Initialize-HarnessJobType
    $resolvedStarted = $StartedAt
    if ($resolvedStarted -eq [DateTimeOffset]::MinValue) {
        $resolvedStarted = [DateTimeOffset]::UtcNow
    }
    $resolvedDeadline = $AbsoluteDeadlineAt
    if ($resolvedDeadline -eq [DateTimeOffset]::MinValue) {
        $resolvedDeadline = $resolvedStarted.AddSeconds($OverallTimeoutSeconds)
    }
    [pscustomobject]@{
        Name = $Name
        Scenario = $Scenario
        ModelCallsStarted = $ModelCallsStarted
        ProgressFile = $ProgressFile
        ProgressStage = ''
        LastValidProgress = $null
        RunRoot = [System.IO.Path]::GetFullPath($RunRoot)
        StartedAt = $resolvedStarted
        Deadline = $resolvedDeadline
        OverallTimeoutSeconds = $OverallTimeoutSeconds
        HeartbeatSeconds = $HeartbeatSeconds
        LastHeartbeat = [DateTimeOffset]::MinValue
        OwnedProcesses = [System.Collections.ArrayList]::new()
        BindingRoots = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        Job = [AgentObserverHarness.KillOnCloseJob]::new()
        Closed = $false
        LastCleanupFailure = $null
        EmergencyCleanupBudgetMs = 0
        EmergencyCleanupUsedMs = 0
    }
}

function Set-HarnessDeadline {
    param(
        [Parameter(Mandatory)]$Context,
        [ValidateRange(1, 86400)][int]$TimeoutSeconds,
        [switch]$FromNow
    )
    if ($FromNow) {
        $Context.StartedAt = [DateTimeOffset]::UtcNow
    }
    $Context.Deadline = $Context.StartedAt.AddSeconds($TimeoutSeconds)
    $Context.OverallTimeoutSeconds = $TimeoutSeconds
}

function Get-HarnessRemainingSeconds {
    param([Parameter(Mandatory)]$Context)
    [int][math]::Max(0, [math]::Ceiling(($Context.Deadline - [DateTimeOffset]::UtcNow).TotalSeconds))
}

function Get-HarnessRemainingMilliseconds {
    param([Parameter(Mandatory)]$Context)
    [int][math]::Max(0, [math]::Floor(($Context.Deadline - [DateTimeOffset]::UtcNow).TotalMilliseconds))
}

function Get-HarnessClippedTimeoutMilliseconds {
    param(
        [Parameter(Mandatory)]$Context,
        [int]$RequestedMilliseconds = 0,
        [Parameter(Mandatory)][string]$Stage
    )
    Assert-HarnessDeadline -Context $Context -Stage $Stage
    $remainingMs = Get-HarnessRemainingMilliseconds -Context $Context
    if ($remainingMs -le 0) {
        Stop-HarnessOwnedProcesses -Context $Context -Reason "deadline:$Stage"
        throw "Harness overall deadline exceeded during $Stage ($($Context.OverallTimeoutSeconds)s)"
    }
    if ($RequestedMilliseconds -le 0) { return $remainingMs }
    return [int][math]::Min($RequestedMilliseconds, $remainingMs)
}

function Get-HarnessClippedTimeoutSeconds {
    param(
        [Parameter(Mandatory)]$Context,
        [int]$RequestedSeconds = 0,
        [Parameter(Mandatory)][string]$Stage
    )
    Assert-HarnessDeadline -Context $Context -Stage $Stage
    $remaining = Get-HarnessRemainingSeconds -Context $Context
    if ($remaining -le 0) {
        Stop-HarnessOwnedProcesses -Context $Context -Reason "deadline:$Stage"
        throw "Harness overall deadline exceeded during $Stage ($($Context.OverallTimeoutSeconds)s)"
    }
    if ($RequestedSeconds -le 0) { return $remaining }
    return [int][math]::Min($RequestedSeconds, $remaining)
}

function Add-HarnessBindingRoot {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Path
    )
    [void]$Context.BindingRoots.Add([System.IO.Path]::GetFullPath($Path))
}

function Register-HarnessProcess {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Scenario,
        [string]$BindingRoot = ''
    )

    $Process.Refresh()
    $startedAtUnixMs = Get-HarnessUnixMilliseconds -DateTime $Process.StartTime
    $record = [pscustomobject]@{
        ProcessId = [int]$Process.Id
        ProcessStartedAtUnixMs = [int64]$startedAtUnixMs
        Kind = $Kind
        Scenario = $Scenario
        BindingRoot = $BindingRoot
        Process = $Process
        RegisteredAt = [DateTimeOffset]::UtcNow
        JobAssigned = $false
    }
    [void]$Context.OwnedProcesses.Add($record)
    if ($BindingRoot) {
        Add-HarnessBindingRoot -Context $Context -Path $BindingRoot
    }

    try {
        $Context.Job.Assign($Process.Id)
        $record.JobAssigned = $true
    } catch {
        Stop-HarnessProcessRecord -Record $record -Reason 'job-assignment-failed' | Out-Null
        throw "Cannot assign $Kind PID $($Process.Id) to the harness kill-on-close job: $($_.Exception.Message)"
    }
    $record
}

function Start-HarnessProcess {
    # The ONLY process start path of the harness. Launches through the C#
    # SafeProcessLauncher: CreateProcessW(CREATE_SUSPENDED) ->
    # AssignProcessToJobObject(kill-on-close job) -> record PID + creation time
    # -> ResumeThread. The child can therefore not execute user code before it
    # is provably inside the job object, so every descendant it spawns is
    # job-owned. stdout and stderr are ALWAYS piped and drained concurrently
    # from process start into a bounded capture plus optional bounded log files.
    # A process that cannot be assigned to the job is terminated while still
    # suspended and this function throws (FAIL); it is never resumed.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Scenario,
        [string]$BindingRoot = '',
        [string]$WorkingDirectory = '',
        # Bounded incremental log files (draining continues past the cap).
        [string]$RedirectStandardOutput = '',
        [string]$RedirectStandardError = '',
        # Bounded in-memory capture cap (bytes, approximate for non-ASCII).
        [ValidateRange(0, 104857600)][int]$MaxCaptureBytes = 262144,
        [ValidateRange(0, 1073741824)][int]$MaxLogBytes = 2097152,
        # GUI children (e.g. AgentObserver.Hud.exe) pass -ShowWindow so their
        # window appears; everything else launches hidden.
        [switch]$ShowWindow
    )

    Assert-HarnessDeadline -Context $Context -Stage "start:$Kind"
    Initialize-HarnessJobType
    if ($null -eq $Context.Job) {
        throw "Cannot start ${Kind}: the harness kill-on-close job object is already closed"
    }

    $resolved = $FilePath
    $command = Get-Command $FilePath -ErrorAction SilentlyContinue
    if ($command -and $command.Source) { $resolved = $command.Source }

    $arguments = ConvertTo-HarnessArgumentString -ArgumentList $ArgumentList
    $workDir = $WorkingDirectory
    if ([string]::IsNullOrWhiteSpace($workDir)) { $workDir = (Get-Location).ProviderPath }

    foreach ($redirectPath in @(@($RedirectStandardOutput) + @($RedirectStandardError))) {
        if (-not $redirectPath) { continue }
        $redirectDir = Split-Path -Parent $redirectPath
        if ($redirectDir -and -not (Test-Path -LiteralPath $redirectDir)) {
            New-Item -ItemType Directory -Force -Path $redirectDir | Out-Null
        }
    }

    $hideWindow = -not [bool]$ShowWindow
    $launch = [AgentObserverHarness.SafeProcessLauncher]::Start(
        $resolved, $arguments, $workDir, $Context.Job.Handle, $hideWindow,
        $RedirectStandardOutput, $RedirectStandardError,
        [int]$MaxCaptureBytes, [int]$MaxLogBytes)

    # Assignment already happened inside the launcher BEFORE ResumeThread; the
    # record below is pure bookkeeping of a proven job-owned process.
    $observedProcess = $null
    try { $observedProcess = [System.Diagnostics.Process]::GetProcessById([int]$launch.ProcessId) } catch { }
    $record = [pscustomobject]@{
        ProcessId = [int]$launch.ProcessId
        ProcessStartedAtUnixMs = [int64](Get-HarnessUnixMilliseconds -DateTime $launch.CreationTimeUtc)
        Kind = $Kind
        Scenario = $Scenario
        BindingRoot = $BindingRoot
        Process = $observedProcess
        Launcher = $launch
        RegisteredAt = [DateTimeOffset]::UtcNow
        JobAssigned = $true
    }
    [void]$Context.OwnedProcesses.Add($record)
    if ($BindingRoot) {
        Add-HarnessBindingRoot -Context $Context -Path $BindingRoot
    }
    [pscustomobject]@{ Process = $observedProcess; Record = $record; Launcher = $launch }
}

function Test-HarnessProcessRecordAlive {
    param([Parameter(Mandatory)]$Record)
    $launcher = Get-HarnessProperty $Record 'Launcher'
    if ($launcher) {
        # The launcher holds the real process handle: its signalled state is the
        # authoritative exit proof, independent of Get-Process visibility.
        try {
            return -not $launcher.WaitForExit(0)
        } catch [System.ObjectDisposedException] {
            # The launcher was disposed only after the record was confirmed dead.
            return $false
        }
    }
    $process = Get-Process -Id $Record.ProcessId -ErrorAction SilentlyContinue
    if (-not $process) { return $false }
    try {
        $actual = Get-HarnessUnixMilliseconds -DateTime $process.StartTime
        return [int64]$actual -eq [int64]$Record.ProcessStartedAtUnixMs
    } catch {
        return $false
    }
}

function Stop-HarnessProcessRecord {
    param(
        [Parameter(Mandatory)]$Record,
        [string]$Reason = 'cleanup'
    )
    if (-not (Test-HarnessProcessRecordAlive -Record $Record)) {
        Complete-HarnessRecord -Record $Record
        return $true
    }
    Write-Host "harness cleanup kind=$($Record.Kind) scenario=$($Record.Scenario) pid=$($Record.ProcessId) reason=$Reason"
    Stop-Process -Id $Record.ProcessId -Force -ErrorAction SilentlyContinue
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(5)
    while ((Test-HarnessProcessRecordAlive -Record $Record) -and [DateTimeOffset]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    $gone = -not (Test-HarnessProcessRecordAlive -Record $Record)
    if ($gone) { Complete-HarnessRecord -Record $Record }
    $gone
}

function Complete-HarnessRecord {
    # Releases the launcher (closing its process handle and flushing the bounded
    # incremental log files) and the observation Process object of a record that
    # has been proven dead. Never called for a live process.
    param([Parameter(Mandatory)]$Record)
    $launcher = Get-HarnessProperty $Record 'Launcher'
    if ($launcher) {
        try { $launcher.Dispose() } catch { }
        try { $Record.Launcher = $null } catch { }
    }
    $process = Get-HarnessProperty $Record 'Process'
    if ($process) {
        try { $process.Dispose() } catch { }
        try { $Record.Process = $null } catch { }
    }
}

function Write-HarnessHeartbeat {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Stage,
        [string]$Scenario = '',
        [int]$ModelCallsStarted = -1,
        [string]$Detail = '',
        [switch]$Force
    )
    $beforeCalls = $Context.ModelCallsStarted
    Update-HarnessProgressState -Context $Context
    $now = [DateTimeOffset]::UtcNow
    $callsChanged = $Context.ModelCallsStarted -ne $beforeCalls
    if (-not $Force -and -not $callsChanged -and ($now - $Context.LastHeartbeat).TotalSeconds -lt $Context.HeartbeatSeconds) {
        return
    }
    $Context.LastHeartbeat = $now
    $elapsed = [math]::Floor(($now - $Context.StartedAt).TotalSeconds)
    $remaining = [math]::Max(0, [math]::Ceiling(($Context.Deadline - $now).TotalSeconds))
    $alive = @($Context.OwnedProcesses | Where-Object { Test-HarnessProcessRecordAlive -Record $_ }).Count
    $scenarioStr = if ($Scenario) {
        $Scenario
    } elseif ($Context.PSObject.Properties['Scenario'] -and $Context.Scenario) {
        $Context.Scenario
    } else {
        'none'
    }
    $callsStr = if ($ModelCallsStarted -ge 0) {
        $ModelCallsStarted
    } else {
        $Context.ModelCallsStarted
    }
    $suffix = if ($Detail) { " $Detail" } else { '' }
    $progressStage = Get-HarnessProperty $Context 'ProgressStage'
    if ($progressStage) { $suffix += " progress_stage=$progressStage" }
    Write-Host "harness scenario=$scenarioStr stage=$Stage elapsed=${elapsed}s remaining=${remaining}s owned_alive=$alive model_calls_started=$callsStr$suffix"
}

function Stop-HarnessOwnedProcesses {
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Reason = 'deadline'
    )
    if ($Context.Job) {
        $Context.Job.Dispose()
        $Context.Job = $null
    }
    for ($index = $Context.OwnedProcesses.Count - 1; $index -ge 0; $index--) {
        Stop-HarnessProcessRecord -Record $Context.OwnedProcesses[$index] -Reason $Reason | Out-Null
    }
    Stop-HarnessBindingProcesses -Context $Context
}

function Assert-HarnessDeadline {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Stage
    )
    if ([DateTimeOffset]::UtcNow -ge $Context.Deadline) {
        Stop-HarnessOwnedProcesses -Context $Context -Reason "deadline:$Stage"
        throw "Harness overall deadline exceeded during $Stage ($($Context.OverallTimeoutSeconds)s)"
    }
}

function Get-HarnessProcessExitCode {
    param(
        [Parameter(Mandatory)]$Record,
        [string]$Stage = 'process'
    )
    $launcher = Get-HarnessProperty $Record 'Launcher'
    if ($launcher) {
        if (-not $launcher.WaitForExit(0)) {
            throw "Refusing to read ExitCode before exit for $Stage PID $($Record.ProcessId)"
        }
        return [int]$launcher.ExitCode
    }
    $process = $Record.Process
    if ($process) {
        try { $process.Refresh() } catch { }
        if ($process.HasExited) {
            return [int]$process.ExitCode
        }
    }
    throw "Refusing to read ExitCode before HasExited for $Stage PID $($Record.ProcessId)"
}

function Resolve-HarnessFailureClassification {
    param([string]$Message = '')
    # Single source of truth for top-level failure classification.
    #   blocked    -> the message explicitly reports a provider failure
    #   timed_out  -> the message reports a wait timeout or an exceeded deadline
    # A generic harness exception (evidence read failure, access denied, ...) is
    # neither and MUST stay a plain FAIL.
    [pscustomobject]@{
        blocked = ($Message -like '*BLOCKED_BY_PROVIDER*')
        timed_out = (($Message -like '*Timed out*') -or ($Message -like '*deadline exceeded*'))
        failure_reason = $Message
    }
}

function Get-HarnessProviderFailureMessage {
    param([Parameter(Mandatory)][string]$Message)
    # Only used for case A: the FailFast callback explicitly RETURNED a provider
    # failure reason. Normalising that reason with the BLOCKED_BY_PROVIDER prefix is
    # correct. Never call this for an arbitrary callback exception.
    if ($Message -like '*BLOCKED_BY_PROVIDER*') { return $Message }
    return "BLOCKED_BY_PROVIDER: $Message"
}

function Invoke-HarnessFailFastCleanup {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Reason
    )
    # Tears down the entire owned process tree of the current scenario using the
    # kill-on-close Job Object plus owned process records matched by PID and creation
    # time. A cleanup error must never mask the original callback exception, but it
    # must not be lost either: it is recorded on the context so the outer finally /
    # Measure-HarnessCleanup can still report the real cleanup result.
    try {
        Stop-HarnessOwnedProcesses -Context $Context -Reason $Reason
    } catch {
        try { $Context.LastCleanupFailure = $_.Exception.Message } catch { }
    }
}

function Invoke-HarnessFailFast {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Stage,
        [scriptblock]$FailFast
    )
    if (-not $FailFast) { return }

    $failure = $null
    try {
        $failure = & $FailFast
    } catch {
        # Case B / case C: the callback threw. Clean up first, then rethrow with the
        # ORIGINAL classification preserved:
        #   B - the message already carries BLOCKED_BY_PROVIDER -> stays BLOCKED
        #   C - any other harness exception (EVIDENCE_READ_FAILED, ACCESS_DENIED, ...)
        #       -> stays a plain FAIL and is never relabelled as a provider failure.
        $message = [string]$_.Exception.Message
        Invoke-HarnessFailFastCleanup -Context $Context -Reason "failfast-exception:$Stage"
        throw "Fail-fast during ${Stage}: $message"
    }

    # Case A: the callback returned a non-empty reason, i.e. it explicitly reported a
    # provider failure. Clean up, then throw with BLOCKED semantics.
    if ($failure) {
        $message = Get-HarnessProviderFailureMessage -Message ([string]$failure)
        Invoke-HarnessFailFastCleanup -Context $Context -Reason "failfast:$Stage"
        throw "Fail-fast during ${Stage}: $message"
    }
}

function Wait-HarnessProcess {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Record,
        [Parameter(Mandatory)][string]$Stage,
        [int]$TimeoutSeconds = 0,
        [string]$ProgressFile = '',
        [scriptblock]$FailFast
    )
    if ($ProgressFile) { $Context.ProgressFile = $ProgressFile }
    $effectiveTimeout = Get-HarnessClippedTimeoutSeconds -Context $Context -RequestedSeconds $TimeoutSeconds -Stage $Stage
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($effectiveTimeout)
    while (Test-HarnessProcessRecordAlive -Record $Record) {
        Assert-HarnessDeadline -Context $Context -Stage $Stage
        Invoke-HarnessFailFast -Context $Context -Stage $Stage -FailFast $FailFast
        if ([DateTimeOffset]::UtcNow -ge $deadline) {
            Invoke-HarnessFailFast -Context $Context -Stage "$Stage-wait-timeout" -FailFast $FailFast
            Stop-HarnessProcessRecord -Record $Record -Reason "wait-timeout:$Stage" | Out-Null
            if ([DateTimeOffset]::UtcNow -ge $Context.Deadline) {
                Stop-HarnessOwnedProcesses -Context $Context -Reason "deadline:$Stage"
            }
            throw "Timed out after ${effectiveTimeout}s waiting for $Stage PID $($Record.ProcessId)"
        }
        $detail = "pid=$($Record.ProcessId)"
        Write-HarnessHeartbeat -Context $Context -Stage $Stage -Detail $detail
        $now = [DateTimeOffset]::UtcNow
        $remainMs = [math]::Min(250, ($deadline - $now).TotalMilliseconds)
        $deadlineRemainMs = ($Context.Deadline - $now).TotalMilliseconds
        $slice = [math]::Min($remainMs, $deadlineRemainMs)
        if ($slice -le 0) { continue }
        Start-Sleep -Milliseconds ([int][math]::Max(1, $slice))
    }
    # Final FailFast check after the child has exited and before ExitCode is read.
    # A provider failure can be persisted in the same instant the child exits; without
    # this check the wait would return exit code 0 and the scenario would claim PASS.
    Invoke-HarnessFailFast -Context $Context -Stage "$Stage-post-exit" -FailFast $FailFast
    Get-HarnessProcessExitCode -Record $Record -Stage $Stage
}

function Wait-HarnessCondition {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][scriptblock]$Condition,
        [Parameter(Mandatory)][string]$Stage,
        [int]$TimeoutSeconds = 0,
        [scriptblock]$FailFast,
        [string]$Detail = ''
    )
    $effectiveTimeout = Get-HarnessClippedTimeoutSeconds -Context $Context -RequestedSeconds $TimeoutSeconds -Stage $Stage
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($effectiveTimeout)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        Assert-HarnessDeadline -Context $Context -Stage $Stage
        Invoke-HarnessFailFast -Context $Context -Stage $Stage -FailFast $FailFast
        $result = & $Condition
        if ($null -ne $result -and $result -ne $false) {
            # Success boundary. The condition may have observed a state that was written
            # in the same instant a provider failure was persisted, so the failure can be
            # invisible to the pre-condition FailFast above. Re-check once before
            # returning. The condition itself is never re-run.
            Invoke-HarnessFailFast -Context $Context -Stage "$Stage-success" -FailFast $FailFast
            return $result
        }
        Write-HarnessHeartbeat -Context $Context -Stage $Stage -Detail $Detail
        $now = [DateTimeOffset]::UtcNow
        $remainMs = [math]::Min(250, ($deadline - $now).TotalMilliseconds)
        $deadlineRemainMs = ($Context.Deadline - $now).TotalMilliseconds
        $slice = [math]::Min($remainMs, $deadlineRemainMs)
        if ($slice -le 0) { break }
        Start-Sleep -Milliseconds ([int][math]::Max(1, $slice))
    }
    Invoke-HarnessFailFast -Context $Context -Stage "$Stage-condition-timeout" -FailFast $FailFast
    Assert-HarnessDeadline -Context $Context -Stage $Stage
    throw "Timed out after ${effectiveTimeout}s waiting for $Stage"
}

function Wait-HarnessSleep {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Stage,
        [int]$Milliseconds = 0,
        [int]$Seconds = 0
    )
    $totalMs = $Milliseconds + ($Seconds * 1000)
    if ($totalMs -le 0) { return }
    $sleepDeadline = [DateTimeOffset]::UtcNow.AddMilliseconds($totalMs)
    while ([DateTimeOffset]::UtcNow -lt $sleepDeadline) {
        Assert-HarnessDeadline -Context $Context -Stage $Stage
        $remainMs = ($sleepDeadline - [DateTimeOffset]::UtcNow).TotalMilliseconds
        $deadlineRemainMs = ($Context.Deadline - [DateTimeOffset]::UtcNow).TotalMilliseconds
        $slice = [math]::Min(100, [math]::Min($remainMs, $deadlineRemainMs))
        if ($slice -le 0) { break }
        Start-Sleep -Milliseconds ([int][math]::Max(1, $slice))
    }
    Assert-HarnessDeadline -Context $Context -Stage $Stage
}

function Stop-HarnessBindingProcesses {
    param([Parameter(Mandatory)]$Context)
    foreach ($root in $Context.BindingRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $files = Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.json' -ErrorAction SilentlyContinue
        foreach ($file in $files) {
            try {
                $value = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                if (-not $value.process_id -or -not $value.process_started_at_unix_ms) { continue }
                $record = [pscustomobject]@{
                    ProcessId = [int]$value.process_id
                    ProcessStartedAtUnixMs = [int64]$value.process_started_at_unix_ms
                    Kind = 'binding-child'
                    Scenario = $file.Directory.Name
                }
                Stop-HarnessProcessRecord -Record $record -Reason 'binding-root-cleanup' | Out-Null
            } catch {
                continue
            }
        }
    }
}

function Close-HarnessLifecycle {
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Reason = 'finally'
    )
    if ($Context.Closed) { return }
    $Context.Closed = $true
    Write-HarnessHeartbeat -Context $Context -Stage 'cleanup' -Detail "reason=$Reason" -Force
    Stop-HarnessOwnedProcesses -Context $Context -Reason $Reason
}

function Assert-NoHarnessProcesses {
    param([Parameter(Mandatory)]$Context)
    $alive = @($Context.OwnedProcesses | Where-Object { Test-HarnessProcessRecordAlive -Record $_ })
    if ($alive.Count -gt 0) {
        $ids = ($alive | ForEach-Object { $_.ProcessId }) -join ','
        throw "Harness cleanup left owned processes alive: $ids"
    }
    foreach ($root in $Context.BindingRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $liveBindings = @()
        foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.json' -ErrorAction SilentlyContinue) {
            try {
                $value = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
                if (-not $value.process_id -or -not $value.process_started_at_unix_ms) { continue }
                $record = [pscustomobject]@{
                    ProcessId = [int]$value.process_id
                    ProcessStartedAtUnixMs = [int64]$value.process_started_at_unix_ms
                }
                if (Test-HarnessProcessRecordAlive -Record $record) { $liveBindings += $file.FullName }
            } catch {
                continue
            }
        }
        if ($liveBindings.Count -gt 0) {
            throw "Harness cleanup left binding processes alive: $($liveBindings -join ', ')"
        }
    }
}

function Get-HarnessOwnedAliveCount {
    param([Parameter(Mandatory)]$Context)
    @($Context.OwnedProcesses | Where-Object { Test-HarnessProcessRecordAlive -Record $_ }).Count
}

function Measure-HarnessCleanup {
    param(
        [object[]]$Contexts = @(),
        $CleanupFailure = $null
    )
    # Real cleanup measurement. Must only be called after the cleanup attempt has
    # finished, so that no summary can claim cleanup_success before it is measured.
    $remaining = 0
    foreach ($ctx in @($Contexts)) {
        if ($null -eq $ctx) { continue }
        $remaining += Get-HarnessOwnedAliveCount -Context $ctx
    }
    $message = $null
    if ($null -ne $CleanupFailure) {
        $message = if ($CleanupFailure -is [System.Exception]) { $CleanupFailure.Message } else { [string]$CleanupFailure }
    }
    # A cleanup error swallowed inside Invoke-HarnessFailFast is recorded on the
    # context; pick it up so the measurement never claims a clean cleanup.
    if ($null -eq $message) {
        foreach ($ctx in @($Contexts)) {
            if ($null -eq $ctx) { continue }
            $recorded = Get-HarnessProperty $ctx 'LastCleanupFailure'
            if ($recorded) { $message = [string]$recorded; break }
        }
    }
    [pscustomobject]@{
        cleanup_success = (($null -eq $message) -and ($remaining -eq 0))
        owned_processes_remaining = [int]$remaining
        cleanup_failure = $message
    }
}

function Write-HarnessTimeoutSummaryFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ScenarioName,
        [int]$TimeoutSeconds = 0,
        [int]$Budget = 0,
        [int]$CallsStarted = 0,
        [string]$Root = '',
        [double]$ElapsedSeconds = 0,
        [string]$Reason = $null,
        # CleanupSuccess and OwnedProcessesRemaining are mandatory so that no caller
        # can fall back to a hardcoded cleanup_success=true / owned_processes_remaining=0.
        [Parameter(Mandatory)][bool]$CleanupSuccess,
        [Parameter(Mandatory)][int]$OwnedProcessesRemaining,
        # Untyped so that $null survives: a [string] parameter would coerce it to ''.
        [AllowNull()][object]$CleanupFailure = $null
    )
    if ($null -ne $CleanupFailure -and [string]::IsNullOrWhiteSpace([string]$CleanupFailure)) {
        $CleanupFailure = $null
    }
    $failureReason = $Reason
    if (-not $CleanupSuccess -or $OwnedProcessesRemaining -ne 0) {
        $parts = New-Object System.Collections.Generic.List[string]
        if ($Reason) { [void]$parts.Add([string]$Reason) }
        if ($CleanupFailure) { [void]$parts.Add("cleanup_failure=$CleanupFailure") }
        if ($OwnedProcessesRemaining -ne 0) { [void]$parts.Add("owned_processes_remaining=$OwnedProcessesRemaining") }
        $failureReason = ($parts -join ' ')
    }
    $summary = New-HarnessScenarioSummary -Scenario $ScenarioName -Status 'FAIL' -AcceptancePass:$false `
        -TimedOut:$true -ModelCallBudget $Budget -ModelCallsStarted $CallsStarted `
        -FailureReason $failureReason -CleanupSuccess:$CleanupSuccess `
        -OwnedProcessesRemaining $OwnedProcessesRemaining -RunRoot $Root -ElapsedSeconds $ElapsedSeconds
    # A timeout is never a pass and never reports a clean cleanup unless it was measured.
    $summary['passed'] = $false
    $summary['cleanup_failure'] = $CleanupFailure
    $summary['timeout_seconds'] = [int]$TimeoutSeconds
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding utf8
    $summary
}
