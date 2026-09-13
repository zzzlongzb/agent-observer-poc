Set-StrictMode -Version Latest

function ConvertTo-VisibilityIdSet {
    param([AllowNull()]$ProcessIds)

    $ids = [Collections.Generic.HashSet[int]]::new()
    foreach ($processId in @($ProcessIds)) {
        if ($null -ne $processId) { [void]$ids.Add([int]$processId) }
    }
    return ,$ids
}

function Get-VisibilityObjectProperty {
    param([AllowNull()]$InputObject, [Parameter(Mandatory)][string]$Name)

    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function ConvertTo-VisibilityUtcTicks {
    param([AllowNull()]$Value)

    if ($null -eq $Value) { throw 'creation time is missing' }
    if ($Value -is [DateTimeOffset]) { return ([DateTimeOffset]$Value).UtcTicks }
    if ($Value -is [DateTime]) { return ([DateTime]$Value).ToUniversalTime().Ticks }
    return [DateTimeOffset]::Parse([string]$Value).UtcTicks
}

function Test-CoordinatorLaunchBinding {
    [CmdletBinding()]
    param(
        [AllowNull()]$LaunchContext,
        [Parameter(Mandatory)][string]$ExpectedRunId,
        [Parameter(Mandatory)][string]$ExpectedRepositoryRoot,
        [AllowNull()][Nullable[int]]$SupervisorParentPid,
        [AllowNull()]$CoordinatorProcess,
        [bool]$SupervisorRootAvailable = $true
    )

    $failures = [Collections.Generic.List[string]]::new()
    if ($null -eq $LaunchContext) {
        [void]$failures.Add('launch context is missing or could not be parsed')
    } else {
        $runId = [string](Get-VisibilityObjectProperty $LaunchContext 'run_id')
        if ($runId -cne $ExpectedRunId) { [void]$failures.Add('run_id mismatch') }

        $actualRoot = [string](Get-VisibilityObjectProperty $LaunchContext 'repository_root')
        try {
            $rootMatches = [IO.Path]::GetFullPath($actualRoot).TrimEnd('\') -ieq [IO.Path]::GetFullPath($ExpectedRepositoryRoot).TrimEnd('\')
        } catch { $rootMatches = $false }
        if (-not $rootMatches) { [void]$failures.Add('repository root mismatch') }

        $coordinatorPid = Get-VisibilityObjectProperty $LaunchContext 'coordinator_pid'
        if ($null -eq $coordinatorPid -or $null -eq $SupervisorParentPid -or [int]$SupervisorParentPid -ne [int]$coordinatorPid) {
            [void]$failures.Add('supervisor immediate parent PID does not match coordinator_pid')
        }

        if ($null -eq $CoordinatorProcess) {
            [void]$failures.Add('immediate coordinator process is missing')
        } else {
            $actualPid = Get-VisibilityObjectProperty $CoordinatorProcess 'pid'
            if ($null -eq $actualPid -or $null -eq $coordinatorPid -or [int]$actualPid -ne [int]$coordinatorPid) {
                [void]$failures.Add('coordinator process PID mismatch')
            }
            try {
                $expectedCreation = ConvertTo-VisibilityUtcTicks (Get-VisibilityObjectProperty $LaunchContext 'coordinator_creation_time')
                $actualCreation = ConvertTo-VisibilityUtcTicks (Get-VisibilityObjectProperty $CoordinatorProcess 'creation_time')
                if ($expectedCreation -ne $actualCreation) { [void]$failures.Add('coordinator creation time mismatch') }
            } catch {
                [void]$failures.Add('coordinator creation time is missing or invalid')
            }
        }

        if ((Get-VisibilityObjectProperty $LaunchContext 'baseline_probe_reliable') -ne $true) {
            [void]$failures.Add('coordinator baseline probe is not reliable')
        }
        if ((Get-VisibilityObjectProperty $LaunchContext 'coordinator_visible_window_observed') -ne $false) {
            [void]$failures.Add('coordinator visibility is not verified hidden')
        }
    }
    if (-not $SupervisorRootAvailable) { [void]$failures.Add('supervisor root could not be read') }

    [pscustomobject][ordered]@{
        status = if ($failures.Count -eq 0) { 'VERIFIED' } else { 'BLOCKED' }
        pass = ($failures.Count -eq 0)
        supervisor_parent_binding_verified = ($failures.Count -eq 0)
        failures = @($failures)
    }
}

function Get-LaunchAncestorDiagnostics {
    [CmdletBinding()]
    param(
        [AllowNull()]$RecordedAncestors,
        [AllowNull()]$CurrentProcesses
    )

    $currentByPid = @{}
    foreach ($process in @($CurrentProcesses)) {
        if ($null -ne $process) { $currentByPid[[string](Get-VisibilityObjectProperty $process 'pid')] = $process }
    }
    @($RecordedAncestors | ForEach-Object {
        $recorded = $_
        $pidValue = [int](Get-VisibilityObjectProperty $recorded 'pid')
        $current = $currentByPid[[string]$pidValue]
        $status = 'TERMINATED_BEFORE_SAMPLE'
        if ($null -ne $current) {
            try {
                $recordedTicks = ConvertTo-VisibilityUtcTicks (Get-VisibilityObjectProperty $recorded 'creation_time')
                $currentTicks = ConvertTo-VisibilityUtcTicks (Get-VisibilityObjectProperty $current 'creation_time')
                $status = if ($recordedTicks -eq $currentTicks) { 'MATCHED' } else { 'PID_REUSED_OR_IDENTITY_MISMATCH' }
            } catch { $status = 'IDENTITY_UNREADABLE' }
        }
        [pscustomobject][ordered]@{
            pid = $pidValue
            status = $status
            reliability = 'DIAGNOSTIC_ONLY'
            recorded_creation_time = Get-VisibilityObjectProperty $recorded 'creation_time'
            current_creation_time = if ($null -ne $current) { Get-VisibilityObjectProperty $current 'creation_time' } else { $null }
            name = Get-VisibilityObjectProperty $recorded 'name'
        }
    })
}

function ConvertTo-SortedVisibilityIds {
    param([Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.HashSet[int]]$Ids)

    return ,@($Ids | Sort-Object)
}

function Get-VisibilityAuditResult {
    [CmdletBinding()]
    param(
        [bool]$ProbeReliable,
        [AllowNull()]$BaselineVisibleProcessIds,
        [AllowNull()]$ObservedVisibleProcessIds,
        [AllowNull()]$OwnedProcesses,
        [AllowNull()]$AssociatedProcesses,
        [int]$SupervisorPid
    )

    if (-not $ProbeReliable -or $null -eq $BaselineVisibleProcessIds -or $null -eq $ObservedVisibleProcessIds) {
        return [pscustomobject][ordered]@{
            status = 'BLOCKED'
            pass = $false
            baseline_visible_window_process_ids = $null
            observed_visible_window_process_ids = $null
            new_visible_window_process_ids = $null
            attributable_visible_window_process_ids = $null
            unattributed_new_visible_window_process_ids = $null
            visible_owned_process_ids = $null
            visible_owned_windows = $null
            attributable_visible_windows = $null
            unattributed_new_visible_windows = $null
            windows_terminal_owned_visible = $null
            associated_visible_console_hosts = $null
            supervisor_visible_window_observed = $null
        }
    }

    $baseline = ConvertTo-VisibilityIdSet $BaselineVisibleProcessIds
    $observed = ConvertTo-VisibilityIdSet $ObservedVisibleProcessIds
    $newVisible = [Collections.Generic.HashSet[int]]::new($observed)
    $newVisible.ExceptWith($baseline)

    $visibleOwned = [Collections.Generic.HashSet[int]]::new()
    $visibleOwnedWindowsTerminal = [Collections.Generic.HashSet[int]]::new()
    $associatedVisibleConsoleHosts = [Collections.Generic.HashSet[int]]::new()
    $consoleHostNames = @('conhost.exe', 'OpenConsole.exe', 'WindowsTerminal.exe', 'cmd.exe', 'powershell.exe', 'pwsh.exe')
    foreach ($process in @($OwnedProcesses)) {
        if ($null -eq $process -or -not [bool]$process.visible_window_observed) { continue }
        $processId = [int]$process.pid
        [void]$visibleOwned.Add($processId)
        if ([string]$process.name -ieq 'WindowsTerminal.exe') {
            [void]$visibleOwnedWindowsTerminal.Add($processId)
        }
        if ($consoleHostNames -contains [string]$process.name) {
            [void]$associatedVisibleConsoleHosts.Add($processId)
        }
    }

    $attributable = [Collections.Generic.HashSet[int]]::new($visibleOwned)
    foreach ($process in @($AssociatedProcesses)) {
        if ($null -eq $process) { continue }
        $processId = [int]$process.pid
        if (-not $newVisible.Contains($processId) -or -not $observed.Contains($processId)) { continue }
        [void]$attributable.Add($processId)
        if ($consoleHostNames -contains [string]$process.name) {
            [void]$associatedVisibleConsoleHosts.Add($processId)
        }
        if ([string]$process.name -ieq 'WindowsTerminal.exe') {
            [void]$visibleOwnedWindowsTerminal.Add($processId)
        }
    }

    $unattributed = [Collections.Generic.HashSet[int]]::new($newVisible)
    $unattributed.ExceptWith($attributable)
    $supervisorVisible = $visibleOwned.Contains($SupervisorPid)
    $pass = -not $supervisorVisible -and $visibleOwned.Count -eq 0 -and $attributable.Count -eq 0

    [pscustomobject][ordered]@{
        status = if ($pass) { 'PASS' } else { 'FAIL' }
        pass = $pass
        baseline_visible_window_process_ids = ConvertTo-SortedVisibilityIds $baseline
        observed_visible_window_process_ids = ConvertTo-SortedVisibilityIds $observed
        new_visible_window_process_ids = ConvertTo-SortedVisibilityIds $newVisible
        attributable_visible_window_process_ids = ConvertTo-SortedVisibilityIds $attributable
        unattributed_new_visible_window_process_ids = ConvertTo-SortedVisibilityIds $unattributed
        visible_owned_process_ids = ConvertTo-SortedVisibilityIds $visibleOwned
        visible_owned_windows = $visibleOwned.Count
        attributable_visible_windows = $attributable.Count
        unattributed_new_visible_windows = $unattributed.Count
        windows_terminal_owned_visible = $visibleOwnedWindowsTerminal.Count
        associated_visible_console_hosts = $associatedVisibleConsoleHosts.Count
        supervisor_visible_window_observed = $supervisorVisible
    }
}
