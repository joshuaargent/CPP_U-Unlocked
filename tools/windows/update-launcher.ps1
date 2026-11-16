# Verified Windows launcher updater. User game data and configuration are never replaced.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$InstallDirectory,
    [Parameter(Mandatory=$true)][string]$CurrentVersion,
    [ValidateSet('stable','beta')][string]$Channel='stable',
    [Parameter(Mandatory=$true)][ValidateRange(1,2147483647)][int]$ParentProcessId
)

$ErrorActionPreference='Stop'
$repo='joshuaargent/CPP_U-Unlocked'
$work=Join-Path $env:LOCALAPPDATA 'UUnlocked/updates'
$log=Join-Path $work 'update.log'
$download=$null
$stage=$null
$archive=$null

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Write-Log([string]$Message) {
    Add-Content -LiteralPath $log -Value ('[{0:u}] {1}' -f [DateTime]::UtcNow,$Message) -Encoding UTF8
}

function Show-Message([string]$Message,[bool]$Failed=$false) {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $icon=[System.Windows.Forms.MessageBoxIcon]::Information
        if($Failed){$icon=[System.Windows.Forms.MessageBoxIcon]::Error}
        [System.Windows.Forms.MessageBox]::Show($Message,'U Unlocked updater',[System.Windows.Forms.MessageBoxButtons]::OK,$icon) | Out-Null
    } catch {
        Write-Log "Could not display message: $($_.Exception.Message)"
    }
}

function Get-VersionInfo([string]$Text) {
    $clean=$Text.TrimStart([char[]]@('v','V'))
    $suffix=[regex]::Match($clean,'-([A-Za-z]+)[.]?([0-9]+)?$')
    $rank=4
    $sequence=0
    if($suffix.Success) {
        $label=$suffix.Groups[1].Value.ToLowerInvariant()
        if($label -eq 'rc'){$rank=3}
        elseif($label -eq 'beta'){$rank=2}
        elseif($label -eq 'alpha'){$rank=1}
        else{$rank=0}
        if($suffix.Groups[2].Success){$sequence=[int]$suffix.Groups[2].Value}
        $clean=$clean.Substring(0,$suffix.Index)
    }
    $number=[version]::Parse($clean)
    return [pscustomobject]@{Number=$number;Rank=$rank;Sequence=$sequence}
}

function Compare-Version([string]$Left,[string]$Right) {
    $a=Get-VersionInfo $Left
    $b=Get-VersionInfo $Right
    $comparison=$a.Number.CompareTo($b.Number)
    if($comparison -ne 0){return $comparison}
    if($a.Rank -gt $b.Rank){return 1}
    if($a.Rank -lt $b.Rank){return -1}
    if($a.Sequence -gt $b.Sequence){return 1}
    if($a.Sequence -lt $b.Sequence){return -1}
    return 0
}

function Validate-ArchiveEntry([System.IO.Compression.ZipArchiveEntry]$Entry) {
    $name=$Entry.FullName.Replace([char]92,[char]47)
    $parts=$name.Split([char]47)
    if([string]::IsNullOrWhiteSpace($name) -or $name.StartsWith('/') -or $name.Contains(':') -or
       ($parts -contains '..') -or ($parts -contains '.')) {
        throw "Unsafe path in update archive: $($Entry.FullName)"
    }
    $kind=($Entry.ExternalAttributes -shr 16) -band 0xF000
    if($kind -eq 0xA000){throw "Symbolic link in update archive: $name"}
}

try {
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    Write-Log "Starting $Channel update from $CurrentVersion."

    $InstallDirectory=[IO.Path]::GetFullPath($InstallDirectory)
    if(-not(Test-Path -LiteralPath $InstallDirectory -PathType Container)){throw 'Install directory does not exist.'}
    $probe=Join-Path $InstallDirectory ('.u-unlocked-write-'+[guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($probe,'write test')
    Remove-Item -LiteralPath $probe -Force

    $headers=@{
        'Accept'='application/vnd.github+json'
        'User-Agent'='U-Unlocked-Updater'
        'X-GitHub-Api-Version'='2022-11-28'
    }
    $releases=@(Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases?per_page=30" -Headers $headers -TimeoutSec 30)
    $release=$releases | Where-Object { -not $_.draft -and ($Channel -eq 'beta' -or -not $_.prerelease) } | Select-Object -First 1
    if(-not $release){throw "No $Channel release is published."}

    $version=([string]$release.tag_name).TrimStart('v','V')
    if((Compare-Version $version $CurrentVersion) -le 0) {
        Write-Log "Already current at $CurrentVersion."
        Show-Message "U Unlocked is already up to date (version $CurrentVersion)."
        return
    }
    $null=Get-VersionInfo $version

    $assetName="U-Unlocked-v$version-Windows-Launcher.zip"
    $asset=$release.assets | Where-Object { $_.name -eq $assetName } | Select-Object -First 1
    if(-not $asset -or [string]$asset.browser_download_url -notlike 'https://github.com/*') {
        throw "Release package $assetName is missing or has an unsafe URL."
    }
    if([int64]$asset.size -le 0 -or [int64]$asset.size -gt 2GB){throw 'Release package size is invalid or too large.'}

    $download=Join-Path $work ($assetName+'.'+[guid]::NewGuid().ToString('N'))
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $download -Headers @{'User-Agent'='U-Unlocked-Updater'} -TimeoutSec 180 -UseBasicParsing

    $expected=''
    if([string]$asset.digest -match '^sha256:([0-9a-fA-F]{64})$') {
        $expected=$Matches[1].ToLowerInvariant()
    } else {
        $checksumName="$assetName.sha256"
        $checksumAsset=$release.assets | Where-Object { $_.name -eq $checksumName } | Select-Object -First 1
        if(-not $checksumAsset -or [string]$checksumAsset.browser_download_url -notlike 'https://github.com/*') {
            throw 'Release has no SHA-256 digest or checksum asset. Refusing an unverified update.'
        }
        $checksum=(Invoke-WebRequest -Uri $checksumAsset.browser_download_url -Headers @{'User-Agent'='U-Unlocked-Updater'} -TimeoutSec 30 -UseBasicParsing).Content
        $match=[regex]::Match([string]$checksum,'[0-9a-fA-F]{64}')
        if(-not $match.Success){throw 'Release checksum is malformed.'}
        $expected=$match.Value.ToLowerInvariant()
    }

    $actual=(Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash.ToLowerInvariant()
    if($actual -ne $expected){throw 'Downloaded package failed SHA-256 verification.'}

    $archive=[IO.Compression.ZipFile]::OpenRead($download)
    if($archive.Entries.Count -gt 4096){throw 'Update archive contains too many entries.'}

    $entries=[Collections.Generic.Dictionary[string,System.IO.Compression.ZipArchiveEntry]]::new([StringComparer]::OrdinalIgnoreCase)
    [int64]$expanded=0
    foreach($entry in $archive.Entries) {
        Validate-ArchiveEntry $entry
        if($entries.ContainsKey($entry.FullName)){throw "Duplicate archive path: $($entry.FullName)"}
        $entries.Add($entry.FullName,$entry)
        $expanded += [int64]$entry.Length
        if($expanded -gt 3GB){throw 'Expanded update archive exceeds 3 GiB.'}
    }

    if(-not $entries.ContainsKey('package-manifest.json')){throw 'Package manifest is missing.'}
    $manifestStream=$entries['package-manifest.json'].Open()
    try {
        $reader=[IO.StreamReader]::new($manifestStream)
        try {$manifest=$reader.ReadToEnd() | ConvertFrom-Json} finally {$reader.Dispose()}
    } finally {$manifestStream.Dispose()}

    if($manifest.schema_version -ne 1 -or [string]$manifest.version -ne $version -or -not $manifest.files) {
        throw 'Package manifest is invalid or does not match the release.'
    }
    $files=@($manifest.files)
    if($files.Count -lt 2 -or $files.Count -gt 256){throw 'Manifest file count is invalid.'}

    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $hasExe=$false
    $stage=Join-Path $InstallDirectory ('.u-unlocked-update-'+[guid]::NewGuid().ToString('N'))
    $newFiles=Join-Path $stage 'new'
    New-Item -ItemType Directory -Force -Path $newFiles | Out-Null

    foreach($file in $files) {
        $name=[string]$file.name
        $hash=[string]$file.sha256
        $allowed = $name -match '^(U Unlocked[.]exe|update-launcher[.]ps1|wua_extract[.]exe|[A-Za-z0-9_.+-]+[.]dll)$'
        if(-not $allowed -or $name.Contains('..') -or -not $seen.Add($name) -or $hash -notmatch '^[0-9a-fA-F]{64}$') {
            throw "Invalid file in update manifest: $name"
        }
        if(-not $entries.ContainsKey($name)){throw "Manifest file is missing from archive: $name"}
        $entry=$entries[$name]
        if($entry.FullName -ne $name -or $entry.Length -gt 512MB){throw "Invalid binary archive entry: $name"}

        $destination=Join-Path $newFiles $name
        $input=$entry.Open()
        $output=[IO.File]::Open($destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try {$input.CopyTo($output);$output.Flush($true)} finally {$output.Dispose();$input.Dispose()}

        $fileHash=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
        if($fileHash -ne $hash.ToUpperInvariant()){throw "Package file hash mismatch: $name"}
        if($name -eq 'U Unlocked.exe'){$hasExe=$true}
    }
    if(-not $hasExe){throw 'Manifest does not contain the launcher executable.'}
    $archive.Dispose()
    $archive=$null

    $deadline=[DateTime]::UtcNow.AddSeconds(120)
    while([DateTime]::UtcNow -lt $deadline -and (Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue)) {
        Start-Sleep -Milliseconds 250
    }
    if(Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue){throw 'Launcher is still running; close it and retry.'}

    $rollbackRoot=Join-Path $work 'rollback'
    New-Item -ItemType Directory -Force -Path $rollbackRoot | Out-Null
    $safeVersion=$CurrentVersion -replace '[^0-9A-Za-z._-]','_'
    $rollback=Join-Path $rollbackRoot ($safeVersion+'-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Force -Path $rollback | Out-Null
    $changed=[Collections.Generic.List[string]]::new()

    try {
        foreach($file in $files) {
            $name=[string]$file.name
            $target=Join-Path $InstallDirectory $name
            $backup=Join-Path $rollback $name
            if(Test-Path -LiteralPath $target -PathType Leaf){Copy-Item -LiteralPath $target -Destination $backup}
            $changed.Add($name)
            Move-Item -LiteralPath (Join-Path $newFiles $name) -Destination $target -Force
        }
        Start-Process -FilePath (Join-Path $InstallDirectory 'U Unlocked.exe') -WorkingDirectory $InstallDirectory | Out-Null
    } catch {
        foreach($name in $changed) {
            $target=Join-Path $InstallDirectory $name
            $backup=Join-Path $rollback $name
            if(Test-Path -LiteralPath $backup -PathType Leaf){Copy-Item -LiteralPath $backup -Destination $target -Force}
            elseif(Test-Path -LiteralPath $target -PathType Leaf){Remove-Item -LiteralPath $target -Force}
        }
        throw
    }

    Get-ChildItem -LiteralPath $rollbackRoot -Directory | Sort-Object LastWriteTimeUtc -Descending | Select-Object -Skip 3 | Remove-Item -Recurse -Force
    Write-Log "Updated $CurrentVersion to $version; rollback saved at $rollback."
    Show-Message "U Unlocked was updated to version $version. Game files, mods, saves and settings were preserved."
} catch {
    $message=$_.Exception.Message
    try {
        if(-not(Test-Path -LiteralPath $work -PathType Container)){New-Item -ItemType Directory -Force -Path $work | Out-Null}
        Write-Log "Update failed: $message"
    } catch {}
    $text="The launcher could not be updated."+[Environment]::NewLine+[Environment]::NewLine+$message+[Environment]::NewLine+"Log: "+$log
    Show-Message $text $true
    exit 1
} finally {
    if($archive){$archive.Dispose()}
    if($stage -and (Test-Path -LiteralPath $stage)){Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue}
    if($download -and (Test-Path -LiteralPath $download)){Remove-Item -LiteralPath $download -Force -ErrorAction SilentlyContinue}
}
