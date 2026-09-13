# Pure package assembly helpers; process ownership stays in the existing builder.
Set-StrictMode -Version Latest

function Get-AlphaRustPathPolicy {
    param([string]$RepoRoot, [string]$RustSysroot, $CargoMetadata,
        [string]$UserProfile, [string]$ExistingEncodedFlags = '', [string]$ExistingRustFlags = '')
    $mappings = @(
        [pscustomobject]@{from=$RepoRoot; to='/src/agent-observer'},
        [pscustomobject]@{from=$RustSysroot; to='/src/rust-toolchain'}
    )
    if ($UserProfile) { $mappings += [pscustomobject]@{from=$UserProfile; to='/src/build-user'} }
    foreach ($crate in @($CargoMetadata.packages | Where-Object { $null -ne $_.source })) {
        $mappings += [pscustomobject]@{
            from=(Split-Path -Parent $crate.manifest_path)
            to=('/src/dependencies/' + $crate.name + '-' + $crate.version)
        }
    }
    foreach ($mapping in $mappings) {
        if (-not [IO.Path]::IsPathRooted($mapping.from) -or $mapping.from -match '[\x00-\x1f]') { throw 'Invalid build source root' }
        $mapping.from = [IO.Path]::GetFullPath($mapping.from).TrimEnd('\', '/')
        if ($mapping.from -eq [IO.Path]::GetPathRoot($mapping.from).TrimEnd('\', '/')) { throw 'Refusing drive-wide source mapping' }
    }
    $flags = @()
    if ($ExistingEncodedFlags) { $flags = @($ExistingEncodedFlags.Split([char]31)) }
    elseif ($ExistingRustFlags) { $flags = @($ExistingRustFlags.Trim() -split '\s+') }
    # rustc uses textual matching, and the LAST matching prefix wins.
    # Encoded flags keep paths with spaces intact; emit both Windows separators.
    $ordered = @($mappings | Sort-Object @{Expression={$_.from.Length}}, from)
    foreach ($mapping in $ordered) {
        foreach ($prefix in @($mapping.from.Replace('/', '\'), $mapping.from.Replace('\', '/')) | Select-Object -Unique) {
            $flags += '--remap-path-prefix=' + $prefix + '=' + $mapping.to
        }
    }
    return [pscustomobject]@{
        encoded_flags=($flags -join [char]31)
        private_prefixes=[string[]]@($ordered | ForEach-Object from | Select-Object -Unique)
        mapping_count=$ordered.Count
    }
}

function Measure-AlphaPrivateBuildPaths {
    param([string]$Root, [string[]]$Prefixes, [DateTimeOffset]$Deadline,
        [ValidateRange(256,1048576)][int]$ChunkBytes = 1048576)
    if (-not $Prefixes -or @($Prefixes | Where-Object { -not $_ }).Count) { throw 'Private prefix set must not be empty' }
    $patterns = @($Prefixes | ForEach-Object {
        $_.Replace('/', '\'); $_.Replace('\', '/'); $_.Replace('/', '\').Replace('\', '\\')
    } | Select-Object -Unique)
    $maxBytes = ($patterns | ForEach-Object { [Text.Encoding]::UTF8.GetByteCount($_) } | Measure-Object -Maximum).Maximum
    $overlap = [int][Math]::Max(8, $maxBytes * 2 + 8)
    $buffer = New-Object byte[] ($ChunkBytes + $overlap)
    $hits = New-Object 'System.Collections.Generic.List[object]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $prefix = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $files = 0; $bytes = [long]0
    foreach ($file in Get-ChildItem -LiteralPath $Root -File -Recurse) {
        if ([DateTimeOffset]::UtcNow -ge $Deadline) { throw 'Private build path scan deadline exceeded' }
        $relative = $file.FullName.Substring($prefix.Length).Replace('\', '/')
        $stream = [IO.File]::OpenRead($file.FullName)
        try {
            $carry = 0
            while ($true) {
                if ([DateTimeOffset]::UtcNow -ge $Deadline) { throw 'Private build path scan deadline exceeded' }
                $read = $stream.Read($buffer, $carry, $ChunkBytes)
                if ($read -eq 0) { break }
                $bytes += $read; $length = $carry + $read
                $texts = @([Text.Encoding]::UTF8.GetString($buffer,0,$length),
                    [Text.Encoding]::Unicode.GetString($buffer,0,$length))
                if ($length -gt 1) { $texts += [Text.Encoding]::Unicode.GetString($buffer,1,$length-1) }
                foreach ($text in $texts) {
                    for ($index=0; $index -lt $patterns.Count; $index++) {
                        if ($text.IndexOf($patterns[$index], [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                            if ($seen.Add($relative + ':' + $index)) {
                                if ($hits.Count -ge 100) { throw 'Private build path hit limit exceeded' }
                                # Never copy the private prefix into distributable metadata.
                                $hits.Add([pscustomobject]@{path=$relative; prefix_index=$index})
                            }
                        }
                    }
                }
                $carry = [Math]::Min($overlap,$length)
                [Array]::Copy($buffer,$length-$carry,$buffer,0,$carry)
            }
        } finally { $stream.Dispose() }
        $files++
    }
    if ([DateTimeOffset]::UtcNow -ge $Deadline) { throw 'Private build path scan deadline exceeded' }
    return [pscustomobject]@{passed=($hits.Count -eq 0); files_checked=$files; bytes_checked=$bytes
        prefix_count=$Prefixes.Count; encodings=@('UTF-8','UTF-16LE (both alignments)'); hits=$hits.ToArray()}
}

function Test-AlphaRustPathPrivacy {
    param([string]$FixtureRoot)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(20)
    $profile = 'C:\Users\synthetic person'
    $crate = $profile + '\.cargo\registry\synthetic-1'
    $metadata = [pscustomobject]@{packages=@([pscustomobject]@{source='registry';name='synthetic';version='1';manifest_path=($crate+'\Cargo.toml')})}
    $policy = Get-AlphaRustPathPolicy -RepoRoot 'D:\synthetic project' -RustSysroot ($profile+'\.rustup\toolchain') `
        -UserProfile $profile -CargoMetadata $metadata -ExistingEncodedFlags ('-C'+[char]31+'opt-level=2') -ExistingRustFlags '-C opt-level=0'
    $flags = $policy.encoded_flags.Split([char]31)
    if ($flags[0] -ne '-C' -or $flags[1] -ne 'opt-level=2' -or $flags -contains 'opt-level=0') { throw 'Rust flag precedence regression' }
    if ($flags -notcontains "--remap-path-prefix=$crate=/src/dependencies/synthetic-1" -or
        $flags -notcontains ('--remap-path-prefix='+$crate.Replace('\','/')+'=/src/dependencies/synthetic-1')) { throw 'Missing dependency mapping or broken spaces' }
    if ($flags[-1] -notlike '*/src/dependencies/synthetic-1') { throw 'Specific mappings must follow user-profile mapping' }
    $plainPolicy = Get-AlphaRustPathPolicy -RepoRoot 'D:\synthetic project' -RustSysroot 'D:\toolchain' -CargoMetadata $metadata `
        -UserProfile '' -ExistingRustFlags '-C opt-level=2'
    if (-not $plainPolicy.encoded_flags.StartsWith('-C'+[char]31+'opt-level=2'+[char]31)) { throw 'RUSTFLAGS preservation regression' }
    $dirty = Join-Path $FixtureRoot 'dirty'; $clean = Join-Path $FixtureRoot 'clean'
    $null = [IO.Directory]::CreateDirectory($dirty); $null = [IO.Directory]::CreateDirectory($clean)
    $samples = @(
        [Text.Encoding]::UTF8.GetBytes(('x'*250)+$crate+'\src\lib.rs'),
        [Text.Encoding]::Unicode.GetBytes(('x'*125)+$crate+'\src\lib.rs'),
        ([byte[]]@(1)+[Text.Encoding]::Unicode.GetBytes($crate+'\src\lib.rs')),
        [Text.Encoding]::UTF8.GetBytes($crate.Replace('\','/').ToLowerInvariant()),
        [Text.Encoding]::UTF8.GetBytes($crate.Replace('\','\\'))
    )
    for ($i=0; $i -lt $samples.Count; $i++) { [IO.File]::WriteAllBytes((Join-Path $dirty "$i.bin"), $samples[$i]) }
    [IO.File]::WriteAllText((Join-Path $clean 'remapped.txt'), '/src/dependencies/synthetic-1/src/lib.rs')
    $negative = Measure-AlphaPrivateBuildPaths -Root $dirty -Prefixes @($profile) -Deadline $deadline -ChunkBytes 256
    if ($negative.passed -or @($negative.hits.path | Select-Object -Unique).Count -ne 5) { throw 'Private path negative controls failed' }
    $positive = Measure-AlphaPrivateBuildPaths -Root $clean -Prefixes @($profile) -Deadline $deadline -ChunkBytes 256
    if (-not $positive.passed -or $positive.files_checked -ne 1) { throw 'Clean path scan failed' }
    $reject = $false
    try { $null = Measure-AlphaPrivateBuildPaths -Root $clean -Prefixes @($profile) -Deadline ([DateTimeOffset]::UtcNow.AddSeconds(-1)) }
    catch { $reject = $_.Exception.Message -eq 'Private build path scan deadline exceeded' }
    if (-not $reject) { throw 'Expired scan deadline accepted' }
    return [pscustomobject]@{passed=$true; assertions=7; negative_files_detected=5}
}

function Get-AlphaPublishArguments {
    param([string]$Project, [string]$Output, [string]$Intermediate, [string]$Config)
    return ,@('publish', $Project, '-c', 'Release', '-r', 'win-x64',
        '--self-contained', 'true', '-o', $Output, '--configfile', $Config,
        '-p:RuntimeFrameworkVersion=10.0.12', '-p:PublishSingleFile=false',
        '-p:PublishTrimmed=false', '-p:PublishAot=false', '-p:DebugType=None',
        '-p:DebugSymbols=false', '-p:UseSharedCompilation=false', '-nodeReuse:false',
        ('-p:BaseIntermediateOutputPath=' + $Intermediate.TrimEnd('\', '/') + '/'),
        ('-p:BaseOutputPath=' + $Intermediate.TrimEnd('\', '/') + '/bin/'))
}

function Copy-AlphaLicenseFiles {
    param([string]$Source, [string]$Destination)
    $files = @(Get-ChildItem -LiteralPath $Source -File | Where-Object {
        $_.Name -match '^(LICENSE|LICENCE|COPYING|NOTICE|THIRD[-_. ]?PARTY[-_. ]?NOTICES|COPYRIGHT)'
    })
    if ($files.Count -eq 0) { throw "No license files found: $Source" }
    $null = [IO.Directory]::CreateDirectory($Destination)
    foreach ($file in $files) { Copy-Item -LiteralPath $file.FullName -Destination $Destination }
    $licenseDirectory = Join-Path $Source 'licenses'
    if (Test-Path -LiteralPath $licenseDirectory -PathType Container) {
        Copy-Item -LiteralPath $licenseDirectory -Destination $Destination -Recurse
    }
}

function Add-AlphaPackageContent {
    param([string]$RepoRoot, [string]$PublishRoot, [string]$PackageRoot,
        [string]$ObserverExe, $CargoMetadata, [string]$RustSysroot,
        [string]$NugetPackages)
    foreach ($name in @('AgentObserver.Hud.exe', 'AgentObserver.Hud.dll',
        'AgentObserver.Hud.runtimeconfig.json', 'coreclr.dll', 'hostfxr.dll', 'hostpolicy.dll')) {
        if (-not (Test-Path -LiteralPath (Join-Path $PublishRoot $name) -PathType Leaf)) {
            throw "Required self-contained file missing: $name"
        }
    }
    $runtime = Get-Content -LiteralPath (Join-Path $PublishRoot 'AgentObserver.Hud.runtimeconfig.json') -Raw | ConvertFrom-Json
    $options = $runtime.runtimeOptions
    if ($options.tfm -ne 'net10.0' -or -not $options.PSObject.Properties['includedFrameworks']) {
        throw 'Expected a self-contained .NET 10 runtimeconfig'
    }
    $frameworks = @($options.includedFrameworks)
    foreach ($name in @('Microsoft.NETCore.App', 'Microsoft.WindowsDesktop.App')) {
        $match = @($frameworks | Where-Object { $_.name -ceq $name -and $_.version -ceq '10.0.12' })
        if ($match.Count -ne 1) { throw "Unexpected packaged framework: $name" }
    }
    foreach ($item in Get-ChildItem -LiteralPath $PublishRoot) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Publish reparse point rejected' }
        Copy-Item -LiteralPath $item.FullName -Destination $PackageRoot -Recurse
    }
    Copy-Item -LiteralPath $ObserverExe -Destination (Join-Path $PackageRoot 'agent-observer-poc.exe')
    foreach ($name in @('LICENSE-MIT', 'LICENSE-APACHE', 'THIRD_PARTY_NOTICES.md', 'README.md')) {
        Copy-Item -LiteralPath (Join-Path $RepoRoot $name) -Destination $PackageRoot
    }
    $fixtureRoot = Join-Path $PackageRoot 'hud/fixtures'
    $null = [IO.Directory]::CreateDirectory($fixtureRoot)
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'hud/fixtures/working-fresh-aging-stale.jsonl') -Destination $fixtureRoot
    # Optional bridges remain opt-in; shipping them does not install them.
    $toolsRoot = Join-Path $PackageRoot 'tools'
    $null = [IO.Directory]::CreateDirectory($toolsRoot)
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'tools/install-native-agent-bridges.ps1') -Destination $toolsRoot
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'integrations') -Destination $PackageRoot -Recurse

    $licenses = Join-Path $PackageRoot 'licenses'
    $inventory = @()
    foreach ($crate in @($CargoMetadata.packages | Where-Object { $null -ne $_.source } | Sort-Object name)) {
        if (-not $crate.license) { throw "Missing crate license metadata: $($crate.name)" }
        $relative = 'licenses/rust/' + $crate.name + '-' + $crate.version
        Copy-AlphaLicenseFiles -Source (Split-Path -Parent $crate.manifest_path) -Destination (Join-Path $PackageRoot $relative)
        $inventory += [pscustomobject]@{ name=$crate.name; version=$crate.version; license=$crate.license; path=$relative }
    }
    # Rust's installed distribution supplies the standard-library attribution,
    # including native components. Do not pretend Cargo metadata covers it.
    Copy-AlphaLicenseFiles -Source (Join-Path $RustSysroot 'share/doc/rust') -Destination (Join-Path $licenses 'rust-toolchain')
    foreach ($pack in @('microsoft.netcore.app.runtime.win-x64', 'microsoft.windowsdesktop.app.runtime.win-x64')) {
        Copy-AlphaLicenseFiles -Source (Join-Path $NugetPackages "$pack/10.0.12") -Destination (Join-Path $licenses "$pack-10.0.12")
        $inventory += [pscustomobject]@{ name=$pack; version='10.0.12'; license='See supplied license and third-party notices'; path="licenses/$pack-10.0.12" }
    }
    $inventory | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $licenses 'dependency-inventory.json') -Encoding UTF8
}

function Get-AlphaPackageManifestFiles {
    param([string]$Root)
    $prefix = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    foreach ($file in Get-ChildItem -LiteralPath $Root -File -Recurse | Sort-Object FullName) {
        [pscustomobject]@{
            path = $file.FullName.Substring($prefix.Length).Replace('\', '/')
            size_bytes = $file.Length
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
}

function Test-AlphaPackageContent {
    param([string]$FixtureRoot)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(20)
    $assert = { param($Condition, $Message) if (-not $Condition) { throw "Alpha content test: $Message" } }
    # An owned native handle is authoritative even when process enumeration
    # has no entry yet/anymore. Do not fall through to an unrelated PID lookup.
    $liveHandle = [pscustomobject]@{}
    $liveHandle | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($milliseconds) return $false }
    $deadHandle = [pscustomobject]@{}
    $deadHandle | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($milliseconds) return $true }
    & $assert (Test-HarnessProcessRecordAlive -Record ([pscustomobject]@{Launcher=$liveHandle;ProcessId=-1})) 'unsignalled owned handle remains live'
    & $assert (-not (Test-HarnessProcessRecordAlive -Record ([pscustomobject]@{Launcher=$deadHandle;ProcessId=-1}))) 'signalled owned handle is exited'
    $publishArgs = Get-AlphaPublishArguments -Project 'project.csproj' -Output 'publish' -Intermediate 'obj' -Config 'NuGet.Config'
    & $assert ($publishArgs -contains '--self-contained' -and $publishArgs -contains 'true') 'self-contained arguments'
    & $assert ($publishArgs -contains '-p:RuntimeFrameworkVersion=10.0.12') 'pinned runtime'
    & $assert ($publishArgs -contains '-p:UseSharedCompilation=false' -and $publishArgs -contains '-nodeReuse:false') 'no persistent compiler server'
    & $assert ($publishArgs -contains '-p:BaseOutputPath=obj/bin/') 'build output outside publish payload'
    $repo = Join-Path $FixtureRoot 'source'; $publish = Join-Path $FixtureRoot 'publish'
    $package = Join-Path $FixtureRoot 'package'; $nuget = Join-Path $FixtureRoot 'nuget'
    foreach ($dir in @($repo,$publish,$package,(Join-Path $repo 'hud/fixtures'),(Join-Path $repo 'tools'),(Join-Path $repo 'integrations'),
        (Join-Path $repo 'crate'),(Join-Path $repo 'share/doc/rust'),
        (Join-Path $nuget 'microsoft.netcore.app.runtime.win-x64/10.0.12'),
        (Join-Path $nuget 'microsoft.windowsdesktop.app.runtime.win-x64/10.0.12'))) { $null = [IO.Directory]::CreateDirectory($dir) }
    foreach ($name in @('LICENSE-MIT','LICENSE-APACHE','THIRD_PARTY_NOTICES.md','README.md',
        'hud/fixtures/working-fresh-aging-stale.jsonl','tools/install-native-agent-bridges.ps1',
        'integrations/synthetic.txt','crate/LICENSE-MIT','share/doc/rust/COPYRIGHT-library.html','observer.exe')) {
        [IO.File]::WriteAllText((Join-Path $repo $name), 'synthetic')
    }
    foreach ($name in @('AgentObserver.Hud.exe','AgentObserver.Hud.dll','coreclr.dll','hostfxr.dll','hostpolicy.dll','extra-runtime.dll')) {
        [IO.File]::WriteAllText((Join-Path $publish $name), 'synthetic')
    }
    foreach ($pack in @('microsoft.netcore.app.runtime.win-x64','microsoft.windowsdesktop.app.runtime.win-x64')) {
        [IO.File]::WriteAllText((Join-Path $nuget "$pack/10.0.12/LICENSE.txt"), 'synthetic license')
    }
    $config = Join-Path $publish 'AgentObserver.Hud.runtimeconfig.json'
    [IO.File]::WriteAllText($config, '{"runtimeOptions":{"tfm":"net10.0","includedFrameworks":[{"name":"Microsoft.NETCore.App","version":"10.0.12"},{"name":"Microsoft.WindowsDesktop.App","version":"10.0.12"}]}}')
    $metadata = [pscustomobject]@{ packages=@([pscustomobject]@{source='registry';name='synthetic';version='1';license='MIT';manifest_path=(Join-Path $repo 'crate/Cargo.toml')}) }
    Add-AlphaPackageContent -RepoRoot $repo -PublishRoot $publish -PackageRoot $package -ObserverExe (Join-Path $repo 'observer.exe') `
        -CargoMetadata $metadata -RustSysroot $repo -NugetPackages $nuget
    $files = @(Get-AlphaPackageManifestFiles -Root $package)
    & $assert ($files.path -contains 'extra-runtime.dll') 'complete publish output retained'
    & $assert ($files.path -contains 'hud/fixtures/working-fresh-aging-stale.jsonl') 'packaged self-test fixture'
    & $assert ($files.path -contains 'licenses/rust/synthetic-1/LICENSE-MIT') 'actual crate license'
    & $assert ($files.path -contains 'licenses/microsoft.windowsdesktop.app.runtime.win-x64-10.0.12/LICENSE.txt') 'runtime license'
    $roundtrip = $files | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    & $assert (@($roundtrip).Count -eq $files.Count -and @($files | Where-Object { $_.path -match '\\|^[A-Za-z]:' }).Count -eq 0) 'portable manifest roundtrip'
    [IO.File]::WriteAllText($config, '{"runtimeOptions":{"tfm":"net10.0","frameworks":[]}}')
    $rejected = $false
    try { Add-AlphaPackageContent -RepoRoot $repo -PublishRoot $publish -PackageRoot $package -ObserverExe '' -CargoMetadata $metadata -RustSysroot $repo -NugetPackages $nuget }
    catch { $rejected = $_.Exception.Message -eq 'Expected a self-contained .NET 10 runtimeconfig' }
    & $assert $rejected 'framework-dependent output rejected before copying'
    & $assert ([DateTimeOffset]::UtcNow -lt $deadline) 'test deadline'
    return [pscustomobject]@{passed=$true; assertions=13}
}
