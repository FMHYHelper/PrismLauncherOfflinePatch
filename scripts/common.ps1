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

function Get-UpstreamWindowsRecipe {
    # Read the tag's own CI configuration and return the recipe used for the
    # official Windows-MSVC build: qt-version, vcvars-arch, cmake-preset.
    # This keeps every kit build on the exact compiler and Qt line upstream
    # used for that release.
    param(
        [Parameter(Mandatory = $true)][string]$Ref,
        [AllowEmptyString()][string]$Token
    )

    $base = "https://raw.githubusercontent.com/PrismLauncher/PrismLauncher/$Ref"
    $headers = Get-UpstreamApiHeaders -Token $Token

    $ci = Invoke-RestMethod -Uri "$base/.github/workflows/build.yml" -Headers $headers
    $raw = [string]$ci

    # locate the Windows-MSVC matrix block: slice from its "- os:" line to the
    # next "- os:" line, so neighbouring matrix entries can't bleed in
    $block = $null
    $osOpenings = [regex]::Matches($raw, '(?m)^\s*-\s+os:')
    foreach ($am in [regex]::Matches($raw, 'artifact-name:\s*Windows-MSVC(?!-)')) {
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
        if ($slice -match 'windows-2022') {
            $block = $slice
            break
        }
    }
    if ($null -eq $block) {
        throw "Could not find a Windows-MSVC matrix entry in build.yml at $Ref"
    }

    $qtVersion = '6.10.2'
    $qm = [regex]::Match($block, 'qt-version:\s*([0-9]+\.[0-9]+\.[0-9]+)')
    if ($qm.Success) { $qtVersion = $qm.Groups[1].Value }

    $vcvars = 'amd64'
    $vm = [regex]::Match($block, 'vcvars-arch:\s*([a-z0-9_]+)')
    if ($vm.Success) { $vcvars = $vm.Groups[1].Value }

    $preset = $null
    $pm = [regex]::Match($block, 'cmake-preset:\s*([A-Za-z0-9_\-]+)')
    if ($pm.Success) { $preset = $pm.Groups[1].Value }
    else {
        $dm = [regex]::Match($raw, "CMAKE_PRESET:\s*\\\$\\{\\{\s*matrix\.cmake-preset\s*\|\| '([A-Za-z0-9_\-]+)'")
        if ($dm.Success) { $preset = $dm.Groups[1].Value }
        else { $preset = 'windows_msvc' }
    }

    # validate against CMakePresets.json at this ref; fall back sensibly
    $presets = Invoke-RestMethod -Uri "$base/CMakePresets.json" -Headers $headers
    $names = @($presets.configurePresets | ForEach-Object { $_.name })
    $chosen = @($preset, 'windows_msvc', 'ci') | Where-Object { $names -contains $_ } | Select-Object -First 1
    if (-not $chosen) {
        throw "No known Windows cmake preset exists in CMakePresets.json at $Ref (looked for $preset, windows_msvc, ci)"
    }

    # Qt < 6.6 did not ship an msvc2022 binary package
    $qtArch = 'win64_msvc2019_64'
    $parts = $qtVersion.Split('.')
    if (([int]$parts[0] -gt 6) -or ([int]$parts[0] -eq 6 -and [int]$parts[1] -ge 6)) {
        $qtArch = 'win64_msvc2022_64'
    }

    return [pscustomobject]@{
        qt_version = $qtVersion
        qt_arch    = $qtArch
        vcvars     = $vcvars
        preset     = $chosen
    }
}
