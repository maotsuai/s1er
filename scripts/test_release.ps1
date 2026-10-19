# Release helper metadata regression tests; never builds app binaries.
$ErrorActionPreference = 'Stop'
$SourceRoot = Split-Path -Parent $PSScriptRoot
$FixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("s1er-release-test-" + [guid]::NewGuid().ToString('N'))
$Utf8 = [System.Text.UTF8Encoding]::new($false)

function Invoke-Helper([string[]]$HelperArgs) {
    & pwsh -NoProfile -File (Join-Path $FixtureRoot 'scripts/release.ps1') @HelperArgs
    if ($LASTEXITCODE -ne 0) { throw "release helper failed: $HelperArgs" }
}

try {
    New-Item -ItemType Directory -Force (Join-Path $FixtureRoot 'scripts'), (Join-Path $FixtureRoot 'docs/release') | Out-Null
    Copy-Item (Join-Path $PSScriptRoot 'release.ps1') (Join-Path $FixtureRoot 'scripts/release.ps1')
    [System.IO.File]::WriteAllText((Join-Path $FixtureRoot 'pubspec.yaml'), "version: 1.2.3+9`n", $Utf8)
    [System.IO.File]::WriteAllText((Join-Path $FixtureRoot 'CHANGELOG.md'), "## [1.3.0]`n`n### Added`n`n- Metadata test`n", $Utf8)
    $seed = @{
        latest = '1.2.3'; minSupported = '0.3.2'; publishedAt = '2026-01-01'; notes = 'old'
        channels = @{
            github = 'old'; androidApk = 'old'; androidArm64V8aApk = 'old'
            androidArmeabiV7aApk = 'old'; androidX8664Apk = 'old'; windows = 'old'
            ios = $null; androidNetdisk = 'upstream-only'; netdiskHint = 'upstream-only'
        }
    }
    $manifestPath = Join-Path $FixtureRoot 'docs/release/latest.json'
    [System.IO.File]::WriteAllText($manifestPath, ($seed | ConvertTo-Json -Depth 6), $Utf8)

    Invoke-Helper @('bump-name', '-BumpName', 'minor', '-Repository', 'maotsuai/s1er')
    $version = [System.IO.File]::ReadAllText((Join-Path $FixtureRoot 'pubspec.yaml'), $Utf8)
    if ($version -notmatch 'version: 1\.3\.0\+10') { throw 'Minor bump reset the monotonic build number' }

    Invoke-Helper @('manifest', '-Repository', 'maotsuai/s1er', '-ManifestNotes', 'Metadata test')
    $manifest = [System.IO.File]::ReadAllText($manifestPath, $Utf8) | ConvertFrom-Json
    if ($manifest.latest -ne '1.3.0' -or $manifest.minSupported -ne '0.3.2') { throw 'Manifest version mismatch' }
    if ($manifest.notes -ne 'Metadata test') { throw 'Manifest notes mismatch' }
    foreach ($key in @('androidApk', 'androidArm64V8aApk', 'androidArmeabiV7aApk', 'androidX8664Apk', 'windows')) {
        $url = $manifest.channels.$key
        if ($url -notlike 'https://github.com/maotsuai/s1er/releases/download/v1.3.0+10/*1.3.0%2B10*') {
            throw "Missing or wrong fork asset URL: $key"
        }
    }
    if ($manifest.channels.ios -ne 'https://github.com/maotsuai/s1er/releases/tag/v1.3.0+10') { throw 'Wrong iOS release URL' }
    if ($manifest.channels.androidNetdisk -or $manifest.channels.netdiskHint) { throw 'Fork inherited upstream netdisk links' }

    # 同一产品版本重打 build 必须有独立的 fork 标签；上游保留原 vName 规则。
    Invoke-Helper @('bump-build', '-Repository', 'maotsuai/s1er')
    Invoke-Helper @('manifest', '-Repository', 'maotsuai/s1er')
    $next = [System.IO.File]::ReadAllText($manifestPath, $Utf8) | ConvertFrom-Json
    if ($next.channels.ios -ne 'https://github.com/maotsuai/s1er/releases/tag/v1.3.0+11') { throw 'Build-only release reused the previous tag' }
    Invoke-Helper @('manifest', '-Repository', 'Shirolin/s1er')
    $upstream = [System.IO.File]::ReadAllText($manifestPath, $Utf8) | ConvertFrom-Json
    if ($upstream.channels.ios -ne 'https://github.com/Shirolin/s1er/releases/tag/v1.3.0') { throw 'Upstream tag convention changed' }

    $before = [System.IO.File]::ReadAllText($manifestPath, $Utf8)
    Invoke-Helper @('manifest', '-Repository', 'other/repo', '-DryRun')
    if ([System.IO.File]::ReadAllText($manifestPath, $Utf8) -ne $before) { throw 'DryRun modified the manifest' }
    Write-Host 'Release metadata regression tests passed.'
} finally {
    Set-Location $SourceRoot
    if (Test-Path $FixtureRoot) { Remove-Item $FixtureRoot -Recurse -Force }
}
