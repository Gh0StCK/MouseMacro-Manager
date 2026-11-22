$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$branchUrl = 'https://api.github.com/repos/Gh0StCK/MouseMacro-Manager/branches/updates'
$manifestUrl = ''
$packageUrl = ''
$files = @('MouseMacro_WebView.ahk','Start_MouseMacro.ahk','web/index.html','README.txt','TEST_REPORT.txt','Update_MouseMacro.cmd','Update_MouseMacro.ps1','VERSION.txt')
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('mousemacro-update-' + [guid]::NewGuid().ToString('N'))
$archive = Join-Path $work 'package.zip'
$expanded = Join-Path $work 'expanded'
$backup = ''

function Test-MouseMacroRunning {
    $engine = [regex]::Escape((Join-Path $root 'MouseMacro_WebView.ahk'))
    @(Get-CimInstance Win32_Process -Filter "Name LIKE 'AutoHotkey%'" | Where-Object {
        $_.CommandLine -and $_.CommandLine -match $engine
    })
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    Write-Host 'MouseMacro: checking for updates...'
    $branch = Invoke-RestMethod -UseBasicParsing -Uri $branchUrl -TimeoutSec 25
    $commit = [string]$branch.commit.sha
    if ($commit -notmatch '^[0-9a-fA-F]{40}$') { throw 'Invalid commit SHA.' }
    $manifestUrl = 'https://raw.githubusercontent.com/Gh0StCK/MouseMacro-Manager/' + $commit + '/update.json'
    $packageUrl = 'https://codeload.github.com/Gh0StCK/MouseMacro-Manager/zip/' + $commit
    Write-Host ('Update commit: ' + $commit.Substring(0,12))
    $manifest = Invoke-RestMethod -UseBasicParsing -Uri $manifestUrl -TimeoutSec 25
    if (-not $manifest.version -or $manifest.channel -ne 'updates' -or -not $manifest.files) {
        throw 'The update manifest is invalid.'
    }
    $versionFile = Join-Path $root 'VERSION.txt'
    $current = if (Test-Path -LiteralPath $versionFile) { (Get-Content -Raw -LiteralPath $versionFile).Trim() } else { '' }
    $localMatches = ($current -eq [string]$manifest.version)
    if ($localMatches) {
        foreach ($rel in $files) {
            $installed = Join-Path $root $rel
            $expected = [string]$manifest.files.PSObject.Properties[$rel].Value
            if (-not (Test-Path -LiteralPath $installed -PathType Leaf) -or $expected -notmatch '^[0-9a-fA-F]{64}$' -or (Get-FileHash -Algorithm SHA256 -LiteralPath $installed).Hash -ine $expected) {
                $localMatches = $false
                break
            }
        }
    }
    if ($localMatches) {
        Write-Host ('Already up to date: ' + $current)
        exit 0
    }

    $running = @(Test-MouseMacroRunning)
    if ($running.Count -gt 0) {
        Write-Host 'MouseMacro is running. Requesting a normal shutdown...'
        foreach ($p in $running) {
            try { (Get-Process -Id $p.ProcessId -ErrorAction Stop).CloseMainWindow() | Out-Null } catch { }
        }
        Start-Sleep -Seconds 3
        if (@(Test-MouseMacroRunning).Count -gt 0) {
            throw 'Please stop playback with F9 and close MouseMacro before retrying. Nothing was changed.'
        }
    }

    Write-Host ('Downloading version ' + $manifest.version + '...')
    Invoke-WebRequest -UseBasicParsing -Uri $packageUrl -OutFile $archive -TimeoutSec 90
    Expand-Archive -LiteralPath $archive -DestinationPath $expanded -Force
    $unpackedDir = Get-ChildItem -LiteralPath $expanded -Directory | Select-Object -First 1
    if (-not $unpackedDir) { throw 'Downloaded repository archive is empty.' }
    $srcRoot = $unpackedDir.FullName
    foreach ($rel in $files) {
        $src = Join-Path $srcRoot $rel
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
            throw ('Missing file in downloaded package: ' + $rel)
        }
        $expected = [string]$manifest.files.PSObject.Properties[$rel].Value
        if ($expected -notmatch '^[0-9a-fA-F]{64}$') { throw ('Invalid checksum for: ' + $rel) }
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $src).Hash.ToLowerInvariant()
        if ($actual -ine $expected) {
            throw ('Checksum mismatch: ' + $rel + '; expected: ' + $expected + '; actual: ' + $actual + '; commit: ' + $commit)
        }
    }
    if ((Get-Content -Raw -LiteralPath (Join-Path $srcRoot 'VERSION.txt')).Trim() -ne [string]$manifest.version) {
        throw 'Package version does not match the update manifest.'
    }

    $backup = Join-Path $root ('Backups\before-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    $present = @{}
    foreach ($rel in $files) {
        $dst = Join-Path $root $rel
        $hadFile = Test-Path -LiteralPath $dst -PathType Leaf
        $present[$rel] = $hadFile
        if ($hadFile) {
            $backupDst = Join-Path $backup $rel
            New-Item -ItemType Directory -Path (Split-Path -Parent $backupDst) -Force | Out-Null
            Copy-Item -LiteralPath $dst -Destination $backupDst -Force
        }
    }

    $applied = New-Object 'System.Collections.Generic.List[string]'
    try {
        foreach ($rel in $files) {
            $src = Join-Path $srcRoot $rel
            $dst = Join-Path $root $rel
            New-Item -ItemType Directory -Path (Split-Path -Parent $dst) -Force | Out-Null
            $applied.Add($rel)
            Copy-Item -LiteralPath $src -Destination $dst -Force
        }
    } catch {
        Write-Host 'Copy failed. Restoring program files from backup...'
        foreach ($rel in $applied) {
            $dst = Join-Path $root $rel
            try {
                if ($present[$rel]) { Copy-Item -LiteralPath (Join-Path $backup $rel) -Destination $dst -Force }
                else { Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue }
            } catch { Write-Warning ('Could not restore ' + $rel) }
        }
        throw
    }

    Write-Host ('Update completed: ' + $manifest.version)
    Write-Host 'Saved macros and MouseMacro_Images were not modified.'
    try { Start-Process -FilePath (Join-Path $root 'Start_MouseMacro.ahk') -WorkingDirectory $root }
    catch { Write-Warning 'Updated, but could not automatically start the app. Open Start_MouseMacro.ahk manually.' }
} catch {
    Write-Host ('Update error: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
} finally {
    try { if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force } } catch { }
}
