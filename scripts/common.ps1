# Shared helpers for the patch-template scripts. Plain text, no magic.
# Compatible with Windows PowerShell 5.1 and pwsh.

function Find-RepoRoot {
    # $PSScriptRoot is the directory of the running script (i.e. <repo>/scripts),
    # so the repository root is exactly one level up.
    return (Split-Path -Parent $PSScriptRoot)
}

function Get-KitIdentityHash {
    # Fingerprint of everything that defines what a build produces:
    # every patch file, the workflow, and the helper scripts.
    param([Parameter(Mandatory = $true)][string]$Root)

    $files = @()
    $patchDir = Join-Path $Root 'patches'
    if (Test-Path $patchDir) {
        $files += @(Get-ChildItem $patchDir -Filter '*.patch' | Sort-Object Name)
    }
    $wfDir = Join-Path (Join-Path $Root '.github') 'workflows'
    if (Test-Path $wfDir) {
        $files += @(Get-ChildItem $wfDir -Filter '*.yml' | Sort-Object Name)
    }
    $scriptsDir = Join-Path $Root 'scripts'
    if (Test-Path $scriptsDir) {
        $files += @(Get-ChildItem $scriptsDir -Filter '*.ps1' | Sort-Object Name)
    }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $ms = New-Object System.IO.MemoryStream
        $utf8 = [System.Text.Encoding]::UTF8
        foreach ($f in $files) {
            $nameBytes = $utf8.GetBytes(($f.Name + "`n"))
            $fileBytes = [System.IO.File]::ReadAllBytes($f.FullName)
            $sep = $utf8.GetBytes("`n")
            $ms.Write($nameBytes, 0, $nameBytes.Length)
            $ms.Write($fileBytes, 0, $fileBytes.Length)
            $ms.Write($sep, 0, $sep.Length)
        }
        $body = $ms.ToArray()
        $ms.Dispose()
        return [System.BitConverter]::ToString($sha.ComputeHash($body)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function ConvertFrom-PrismTag {
    # Parse a Prism Launcher release tag like "11.1.1", "9.4", "11.1.0-pre1",
    # "10.0.3-rc2". Returns null when the tag is not a recognisable version.
    param([string]$Tag = '')

    if (-not $Tag) { return $null }
    if ($Tag -match '^(?<maj>[0-9]+)\.(?<min>[0-9]+)(?:\.(?<pat>[0-9]+))?(?:-(?<rel>pre|rc)(?<num>[0-9]+))?$') {
        $pre = [int]::MaxValue
        if ($Matches['rel']) { $pre = [int]$Matches['num'] }
        $patch = 0
        if ($Matches['pat']) { $patch = [int]$Matches['pat'] }
        return [pscustomobject]@{
            major  = [int]$Matches['maj']
            minor  = [int]$Matches['min']
            patch  = $patch
            pre    = $pre
        }
    }
    return $null
}

function Compare-PrismTag {
    # Returns -1 when A < B, 0 when equal, 1 when A > B. Stable beats any
    # pre-release of the same version. Callers pass parsed objects from
    # ConvertFrom-PrismTag.
    param($A, $B)

    foreach ($k in @('major', 'minor', 'patch', 'pre')) {
        $av = $A.$k
        $bv = $B.$k
        if ($av -lt $bv) { return -1 }
        if ($av -gt $bv) { return 1 }
    }
    return 0
}

function Get-MaxPrismTag {
    # Returns the highest element of a list of {tag, ver} objects, or $null.
    param([Parameter(Mandatory = $true)]$Items)

    $best = $null
    foreach ($i in @($Items)) {
        if ($null -eq $best) { $best = $i; continue }
        if ((Compare-PrismTag $i.ver $best.ver) -gt 0) { $best = $i }
    }
    return $best
}

function Get-UpstreamApiHeaders {
    param([string]$Token)

    $h = @{
        'User-Agent'    = 'prismlauncher-offline-patch-template'
        'Accept'        = 'application/vnd.github+json'
    }
    if ($Token) { $h['Authorization'] = "Bearer $Token" }
    return $h
}

function Resolve-KitPlatforms {
    # Parses the platform selection for a run: the repositories variable
    # `platforms` (exposed to the decision script as KIT_PLATFORMS, a comma or
    # space separated subset of windows,linux,macos). Empty or 'all' means
    # every platform. Unknown names are warned about and ignored; when nothing
    # valid remains, all platforms are built - a typo in the variable must
    # never silently stop a copy from building.
    param([string]$Spec)

    $all = @('windows', 'linux', 'macos')
    if ([string]::IsNullOrWhiteSpace($Spec)) { return $all }
    if ($Spec.Trim().ToLowerInvariant() -eq 'all') { return $all }

    $requested = @($Spec -split '[,;\s]+' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
    if ($requested.Count -eq 0) { return $all }

    foreach ($x in ($requested | Where-Object { $all -notcontains $_ })) {
        Write-Warning ("Unknown platform '" + $x + "' in the 'platforms' variable; ignoring it (known: " + ($all -join ', ') + ").")
    }
    $chosen = @($all | Where-Object { $requested -contains $_ })
    if ($chosen.Count -eq 0) {
        Write-Warning "No valid platform names in the 'platforms' variable; building all platforms."
        return $all
    }
    return $chosen
}

function Get-UpstreamPlatformRecipe {
    # Read the tag's own CI configuration and return the recipe used for the
    # official build of one platform: runner os, artifact-name, Qt version,
    # CMake preset and the platform-specific extras. This keeps every kit
    # build on the exact compiler and Qt combination upstream used for that
    # release, platform by platform.
    param(
        [Parameter(Mandatory = $true)][string]$Ref,
        [Parameter(Mandatory = $true)][ValidateSet('windows', 'linux', 'macos')][string]$Platform,
        [AllowEmptyString()][string]$Token
    )

    # The matrix entries this kit mirrors: the flagship flavour of each
    # platform (a subset of upstream's own build matrix).
    $specs = @{
        windows = @{
            artifact       = 'Windows-MSVC'
            runner         = 'windows-2022'
            presetFallback = 'windows_msvc'
            qtFallback     = '6.10.2'
        }
        linux = @{
            artifact       = 'Linux'
            runner         = 'ubuntu-24.04'
            presetFallback = 'linux'
            qtFallback     = '6.10.2'
        }
        macos = @{
            artifact       = 'macOS'
            runner         = 'macos-26'
            presetFallback = 'macos_universal'
            qtFallback     = '6.9.3'
        }
    }
    $spec = $specs[$Platform]

    $base = "https://raw.githubusercontent.com/PrismLauncher/PrismLauncher/$Ref"
    $headers = Get-UpstreamApiHeaders -Token $Token

    $ci = Invoke-RestMethod -Uri "$base/.github/workflows/build.yml" -Headers $headers
    $raw = [string]$ci

    # locate the platform's matrix block: slice from its "- os:" line to the
    # next "- os:" line, so neighbouring matrix entries can't bleed in. The
    # negative lookahead keeps "Windows-MSVC" from matching "Windows-MSVC-arm64".
    $block = $null
    $osOpenings = [regex]::Matches($raw, '(?m)^\s*-\s+os:')
    $namePattern = 'artifact-name:\s*' + [regex]::Escape($spec.artifact) + '(?!-)'
    foreach ($am in [regex]::Matches($raw, $namePattern)) {
        $openStart = $null
        $openEnd = $null
        foreach ($o in $osOpenings) {
            if ($o.Index -lt $am.Index) { $openStart = $o.Index; continue }
            $openEnd = $o.Index
            break
        }
        if ($null -eq $openStart) { continue }
        if ($null -eq $openEnd) { $openEnd = $raw.Length }
        $slice = $raw.Substring($openStart, $openEnd - $openStart)
        if ($slice -match [regex]::Escape($spec.runner)) {
            $block = $slice
            break
        }
    }
    if ($null -eq $block) {
        throw "Could not find the $($spec.artifact) matrix entry in build.yml at $Ref"
    }

    $qtVersion = $spec.qtFallback
    $qm = [regex]::Match($block, 'qt-version:\s*([0-9]+\.[0-9]+\.[0-9]+)')
    if ($qm.Success) { $qtVersion = $qm.Groups[1].Value }

    $preset = $spec.presetFallback
    $pm = [regex]::Match($block, 'cmake-preset:\s*([A-Za-z0-9_\-]+)')
    if ($pm.Success) { $preset = $pm.Groups[1].Value }

    # validate against CMakePresets.json at this ref; fall back sensibly
    $presets = Invoke-RestMethod -Uri "$base/CMakePresets.json" -Headers $headers
    $names = @($presets.configurePresets | ForEach-Object { $_.name })
    $chosen = @($preset, $spec.presetFallback) | Where-Object { $names -contains $_ } | Select-Object -First 1
    if (-not $chosen) {
        throw "No known $Platform cmake preset exists in CMakePresets.json at $Ref (looked for $preset, $($spec.presetFallback))"
    }

    $vcvars = ''
    $qtArch = ''
    $macosxTarget = ''
    if ($Platform -eq 'windows') {
        $vcvars = 'amd64'
        $vm = [regex]::Match($block, 'vcvars-arch:\s*([a-z0-9_]+)')
        if ($vm.Success) { $vcvars = $vm.Groups[1].Value }

        # Qt < 6.6 did not ship an msvc2022 binary package
        $qtArch = 'win64_msvc2019_64'
        $parts = $qtVersion.Split('.')
        if (([int]$parts[0] -gt 6) -or ([int]$parts[0] -eq 6 -and [int]$parts[1] -ge 6)) {
            $qtArch = 'win64_msvc2022_64'
        }
    }
    if ($Platform -eq 'macos') {
        $macosxTarget = '12.0'
        $dm = [regex]::Match($block, 'macosx-deployment-target:\s*([0-9]+\.[0-9]+)')
        if ($dm.Success) { $macosxTarget = $dm.Groups[1].Value }
    }

    return [pscustomobject]@{
        platform      = $Platform
        os            = $spec.runner
        artifact_name = $spec.artifact
        qt_version    = $qtVersion
        qt_arch       = $qtArch
        vcvars        = $vcvars
        macosx_target = $macosxTarget
        preset        = $chosen
    }
}

function Get-UpstreamWindowsRecipe {
    # Legacy-shaped helper: only the Windows-MSVC recipe (qt_version, qt_arch,
    # vcvars, preset). Thin wrapper around Get-UpstreamPlatformRecipe.
    param(
        [Parameter(Mandatory = $true)][string]$Ref,
        [AllowEmptyString()][string]$Token
    )

    $r = Get-UpstreamPlatformRecipe -Ref $Ref -Platform 'windows' -Token $Token
    return [pscustomobject]@{
        qt_version = $r.qt_version
        qt_arch    = $r.qt_arch
        vcvars     = $r.vcvars
        preset     = $r.preset
    }
}
