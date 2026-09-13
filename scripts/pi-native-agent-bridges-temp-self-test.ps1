# Offline installer self-test. Every TARGET is under TEMP; the real Pi extension
# is read only to obtain the already-verified managed-old fixture bytes.
param(
    [string]$PowerShellExecutable = '',
    [string]$Installer = ''
)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
if (-not $Installer) { $Installer = Join-Path $repoRoot 'tools\install-native-agent-bridges.ps1' }
if (-not $PowerShellExecutable) { $PowerShellExecutable = (Get-Process -Id $PID).Path }
$root = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('agent-observer-installer-selftest-' + [Guid]::NewGuid().ToString('N'))))
$source = Join-Path $repoRoot 'integrations\pi-agent-observer.ts'
$realOld = Join-Path $env:USERPROFILE '.pi\agent\extensions\agent-observer-bridge.ts'
$result = [ordered]@{
    test = 'native-agent-bridges-temp-self-test'
    shell = $PSVersionTable.PSVersion.ToString()
    pass = $false
    cases = @()
    failures = @()
}
function Write-Bytes([string]$Path, [byte[]]$Bytes) {
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    [IO.File]::WriteAllBytes($Path, $Bytes)
}
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant() }
function Run-Installer {
    param([string[]]$Arguments, [bool]$ExpectSuccess = $true)
    $out = & $PowerShellExecutable -NoProfile -NonInteractive -File $Installer @Arguments 2>&1
    $code = $LASTEXITCODE
    if ($ExpectSuccess -and $code -ne 0) { throw "installer failed ($code): $($out -join [Environment]::NewLine)" }
    if (-not $ExpectSuccess) {
        if ($code -eq 0) { throw "installer unexpectedly succeeded: $($out -join [Environment]::NewLine)" }
        return $null
    }
    $json = ($out -join [Environment]::NewLine) | ConvertFrom-Json
    return $json
}
function State($Report) { @($Report.actions)[0].state }
function Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $result.cases += [ordered]@{ name = $Name; pass = $true } }
    catch { $result.cases += [ordered]@{ name = $Name; pass = $false; error = $_.Exception.Message }; $result.failures += "${Name}: $($_.Exception.Message)" }
}
try {
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    if (-not (Test-Path -LiteralPath $realOld -PathType Leaf)) { throw 'verified managed-old Pi bridge is not installed; cannot run hash fixture test' }
    $oldBytes = [IO.File]::ReadAllBytes($realOld)
    $oldHash = Hash $realOld
    if ($oldHash -ne '5D460657D02E784A6CFC0DD943F3D8ADC3C9363A77EF1AD0E74D8571A7E1558B') { throw "managed-old fixture hash changed: $oldHash" }
    $oldFixture = Join-Path $root 'old-bridge.ts'
    Write-Bytes $oldFixture $oldBytes
    $target = Join-Path $root 'target.ts'

    Case 'missing -> MISSING and dry-run writes nothing' {
        $r = Run-Installer @('-Scope','Pi','-PiTargetPath',$target)
        if ((State $r) -ne 'MISSING' -or (Test-Path $target)) { throw 'missing dry-run mismatch or wrote target' }
    }
    Case 'same bytes -> CURRENT' {
        Write-Bytes $target ([IO.File]::ReadAllBytes($source))
        $before = Hash $target
        $r = Run-Installer @('-Scope','Pi','-PiTargetPath',$target)
        if ((State $r) -ne 'CURRENT' -or (Hash $target) -ne $before) { throw 'current dry-run mismatch' }
        Remove-Item $target -Force
    }
    Case 'known managed old hash -> UPDATE_AVAILABLE' {
        Write-Bytes $target $oldBytes
        $before = Hash $target
        $r = Run-Installer @('-Scope','Pi','-PiTargetPath',$target)
        if ((State $r) -ne 'UPDATE_AVAILABLE' -or (Hash $target) -ne $before) { throw 'known-old dry-run mismatch or write' }
    }
    Case 'Install without UpdateManaged rejects known old' {
        $before = Hash $target
        [void](Run-Installer @('-Scope','Pi','-Install','-PiTargetPath',$target) $false)
        if ((Hash $target) -ne $before) { throw 'conservative install changed target' }
    }
    Case 'Install UpdateManaged updates and preserves backup' {
        $r = Run-Installer @('-Scope','Pi','-Install','-UpdateManaged','-PiTargetPath',$target)
        $backup = Join-Path $root ('target.ts.backup.' + $oldHash.Substring(0,12).ToLowerInvariant())
        if ((Hash $target) -ne (Hash $source)) { throw 'updated target differs from source' }
        if ((Hash $backup) -ne $oldHash) { throw 'backup differs from old bytes' }
        if ((State $r) -ne 'UPDATE_AVAILABLE') { throw 'update report state mismatch' }
    }
    Case 'unknown hash rejects even with UpdateManaged' {
        Write-Bytes $target ([Text.Encoding]::UTF8.GetBytes('unknown bridge content'))
        $before = Hash $target
        $r = Run-Installer @('-Scope','Pi','-PiTargetPath',$target)
        if ((State $r) -ne 'CONFLICT') { throw 'unknown hash was not conflict' }
        [void](Run-Installer @('-Scope','Pi','-Install','-UpdateManaged','-PiTargetPath',$target) $false)
        if ((Hash $target) -ne $before) { throw 'unknown conflict was changed' }
    }
    Case 'target hash change before replacement rejects' {
        Write-Bytes $target $oldBytes
        $env:AGENT_OBSERVER_INSTALL_TEST_MUTATE_TARGET = '1'
        try { [void](Run-Installer @('-Scope','Pi','-Install','-UpdateManaged','-PiTargetPath',$target) $false) }
        finally { Remove-Item Env:AGENT_OBSERVER_INSTALL_TEST_MUTATE_TARGET -ErrorAction SilentlyContinue }
        if (([IO.File]::ReadAllText($target)) -ne 'test mutation') { throw 'TOCTOU mutation was not observed' }
    }
} catch { $result.failures += $_.Exception.Message }
finally {
    Remove-Item Env:AGENT_OBSERVER_INSTALL_TEST_MUTATE_TARGET -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    $result.scratch_remaining = Test-Path -LiteralPath $root
    $result.pass = ($result.failures.Count -eq 0 -and -not $result.scratch_remaining -and @($result.cases | Where-Object { -not $_.pass }).Count -eq 0)
}
Write-Output ($result | ConvertTo-Json -Depth 8)
if (-not $result.pass) { exit 1 }
