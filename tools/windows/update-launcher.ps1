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
$download=$null; $stage=$null; $archive=$null

function Log([string]$Text){Add-Content -LiteralPath $log -Value ('[{0:u}] {1}' -f [DateTime]::UtcNow,$Text) -Encoding UTF8}
function Notify([string]$Text,[bool]$Failed=$false){
 try{
  Add-Type -AssemblyName System.Windows.Forms
  $icon=if($Failed){[System.Windows.Forms.MessageBoxIcon]::Error}else{[System.Windows.Forms.MessageBoxIcon]::Information}
  [System.Windows.Forms.MessageBox]::Show($Text,'U Unlocked updater',[System.Windows.Forms.MessageBoxButtons]::OK,$icon)|Out-Null
 }catch{Log "Dialog error: $($_.Exception.Message)"}
}
function VersionObject([string]$Text){
 $clean=$Text.TrimStart('v','V').Split('-','+')[0]
 $v=[version]::new($clean)
 $suffix=[regex]::Match($Text,'-(?<pre>[0-9A-Za-z.-]+)
function ValidateEntry([System.IO.Compression.ZipArchiveEntry]$Entry){
 $name=$Entry.FullName.Replace([char]92,[char]47)
 if([string]::IsNullOrWhiteSpace($name) -or $name.StartsWith('/') -or $name.Contains(':') -or
    $name -match '(^|/)\.\.?(/|$)' -or $name -match '^[A-Za-z]:'){
  throw "Unsafe path in update archive: $($Entry.FullName)"
 }
 if((($Entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000){throw "Archive contains a symbolic link: $name"}
}

try{
 New-Item -ItemType Directory -Force -Path $work|Out-Null
 Log "Starting $Channel update from $CurrentVersion."
 $InstallDirectory=[IO.Path]::GetFullPath($InstallDirectory)
 if(-not(Test-Path -LiteralPath $InstallDirectory -PathType Container)){throw 'Install directory does not exist.'}
 $probe=Join-Path $InstallDirectory ('.u-unlocked-write-'+[guid]::NewGuid().ToString('N'))
 [IO.File]::WriteAllText($probe,'test'); Remove-Item -LiteralPath $probe -Force

 $headers=@{'Accept'='application/vnd.github+json';'User-Agent'='U-Unlocked-Updater';'X-GitHub-Api-Version'='2022-11-28'}
 $releases=@(Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases?per_page=30" -Headers $headers -TimeoutSec 30)
 $release=$releases|Where-Object{-not $_.draft -and ($Channel -eq 'beta' -or -not $_.prerelease)}|Select-Object -First 1
 if(-not $release){throw "No $Channel release is published."}
 $version=([string]$release.tag_name).TrimStart('v','V')
 if((CompareVersion $version $CurrentVersion) -le 0){Log "Already current: $CurrentVersion";Notify "U Unlocked is already up to date (version $CurrentVersion).";return}
 $null=VersionObject $version
 $assetName="U-Unlocked-v$version-Windows-Launcher.zip"
 $asset=$release.assets|Where-Object{$_.name -eq $assetName}|Select-Object -First 1
 if(-not $asset -or [string]$asset.browser_download_url -notmatch '^https://github\.com/'){throw "Release package $assetName is missing or has an unsafe URL."}
 if([int64]$asset.size -le 0 -or [int64]$asset.size -gt 2GB){throw 'Release package size is invalid or too large.'}
 $download=Join-Path $work ($assetName+'.'+[guid]::NewGuid().ToString('N'))
 Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $download -Headers @{'User-Agent'='U-Unlocked-Updater'} -TimeoutSec 180 -UseBasicParsing

 $expected=''
 if([string]$asset.digest -match '^sha256:([0-9a-fA-F]{64})$'){$expected=$Matches[1].ToLowerInvariant()}
 else{
  $sumAsset=$release.assets|Where-Object{$_.name -eq "$assetName.sha256"}|Select-Object -First 1
  if(-not $sumAsset -or [string]$sumAsset.browser_download_url -notmatch '^https://github\.com/'){throw 'No trusted SHA-256 digest or checksum asset; refusing update.'}
  $sum=(Invoke-WebRequest -Uri $sumAsset.browser_download_url -Headers @{'User-Agent'='U-Unlocked-Updater'} -TimeoutSec 30 -UseBasicParsing).Content
  $expected=([regex]::Match([string]$sum,'[0-9a-fA-F]{64}')).Value.ToLowerInvariant()
  if($expected.Length -ne 64){throw 'Release checksum is malformed.'}
 }
 if((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected){throw 'Downloaded package failed SHA-256 verification.'}

 Add-Type -AssemblyName System.IO.Compression
 Add-Type -AssemblyName System.IO.Compression.FileSystem
 $archive=[IO.Compression.ZipFile]::OpenRead($download)
 if($archive.Entries.Count -gt 4096){throw 'Update archive has too many entries.'}
 $entries=[Collections.Generic.Dictionary[string,IO.Compression.ZipArchiveEntry]]::new([StringComparer]::OrdinalIgnoreCase)
 [int64]$expanded=0
 foreach($entry in $archive.Entries){
  ValidateEntry $entry
  if($entries.ContainsKey($entry.FullName)){throw "Duplicate archive entry: $($entry.FullName)"}
  $entries.Add($entry.FullName,$entry);$expanded += [int64]$entry.Length
  if($expanded -gt 3GB){throw 'Expanded update archive exceeds 3 GiB.'}
 }
 if(-not $entries.ContainsKey('package-manifest.json')){throw 'Package manifest is missing.'}
 $stream=$entries['package-manifest.json'].Open()
 try{$reader=[IO.StreamReader]::new($stream);try{$manifest=$reader.ReadToEnd()|ConvertFrom-Json}finally{$reader.Dispose()}}finally{$stream.Dispose()}
 if($manifest.schema_version -ne 1 -or [string]$manifest.version -ne $version -or -not $manifest.files){throw 'Package manifest is invalid or mismatched.'}
 $files=@($manifest.files)
 if($files.Count -lt 2 -or $files.Count -gt 256){throw 'Manifest file count is invalid.'}
 $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
 $hasExe=$false
 $stage=Join-Path $InstallDirectory ('.u-unlocked-update-'+[guid]::NewGuid().ToString('N'))
 $new=Join-Path $stage 'new';New-Item -ItemType Directory -Force -Path $new|Out-Null
 foreach($file in $files){
  $name=[string]$file.name;$hash=[string]$file.sha256
  if($name -notmatch '^(U Unlocked\.exe|update-launcher\.ps1|[A-Za-z0-9_.+-]+\.dll)$' -or $name.Contains('..') -or
     -not $seen.Add($name) -or $hash -notmatch '^(?i:[0-9a-f]{64})$'){throw "Invalid manifest file: $name"}
  if(-not $entries.ContainsKey($name)){throw "Manifest file missing from archive: $name"}
  $entry=$entries[$name]
  if($entry.FullName -ne $name -or $entry.Length -gt 512MB){throw "Invalid binary entry: $name"}
  $input=$entry.Open();$output=[IO.File]::Open((Join-Path $new $name),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  try{$input.CopyTo($output);$output.Flush($true)}finally{$output.Dispose();$input.Dispose()}
  if((Get-FileHash -LiteralPath (Join-Path $new $name) -Algorithm SHA256).Hash -ne $hash.ToUpperInvariant()){throw "File hash mismatch: $name"}
  if($name -eq 'U Unlocked.exe'){$hasExe=$true}
 }
 if(-not $hasExe){throw 'Manifest has no launcher executable.'}
 $archive.Dispose();$archive=$null

 $deadline=[DateTime]::UtcNow.AddSeconds(120)
 while([DateTime]::UtcNow -lt $deadline -and (Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue)){Start-Sleep -Milliseconds 250}
 if(Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue){throw 'Launcher is still running; close it and retry.'}

 $rollbackRoot=Join-Path $work 'rollback';New-Item -ItemType Directory -Force -Path $rollbackRoot|Out-Null
 $oldSafe=$CurrentVersion -replace '[^0-9A-Za-z._-]','_'
 $rollback=Join-Path $rollbackRoot ($oldSafe+'-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
 New-Item -ItemType Directory -Force -Path $rollback|Out-Null
 $changed=[Collections.Generic.List[string]]::new()
 try{
  foreach($file in $files){
   $name=[string]$file.name;$target=Join-Path $InstallDirectory $name;$backup=Join-Path $rollback $name
   if(Test-Path -LiteralPath $target -PathType Leaf){Copy-Item -LiteralPath $target -Destination $backup}
   $changed.Add($name)
   Move-Item -LiteralPath (Join-Path $new $name) -Destination $target -Force
  }
  Start-Process -FilePath (Join-Path $InstallDirectory 'U Unlocked.exe') -WorkingDirectory $InstallDirectory|Out-Null
 }catch{
  foreach($name in $changed){
   $target=Join-Path $InstallDirectory $name;$backup=Join-Path $rollback $name
   if(Test-Path -LiteralPath $backup -PathType Leaf){Copy-Item -LiteralPath $backup -Destination $target -Force}
   elseif(Test-Path -LiteralPath $target -PathType Leaf){Remove-Item -LiteralPath $target -Force}
  }
  throw
 }
 Get-ChildItem -LiteralPath $rollbackRoot -Directory|Sort-Object LastWriteTimeUtc -Descending|Select-Object -Skip 3|Remove-Item -Recurse -Force
 Log "Updated $CurrentVersion to $version; rollback saved at $rollback."
 Notify "U Unlocked was updated to version $version. Game files, mods, saves and settings were preserved."
}catch{
 $message=$_.Exception.Message
 try{if(-not(Test-Path -LiteralPath $work -PathType Container)){New-Item -ItemType Directory -Force -Path $work|Out-Null};Log "Update failed: $message"}catch{}
 Notify ("The launcher could not be updated."+[Environment]::NewLine+[Environment]::NewLine+$message+[Environment]::NewLine+"Log: "+$log) $true
 exit 1
}finally{
 if($archive){$archive.Dispose()}
 if($stage -and (Test-Path -LiteralPath $stage)){Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue}
 if($download -and (Test-Path -LiteralPath $download)){Remove-Item -LiteralPath $download -Force -ErrorAction SilentlyContinue}
}
)
 $rank=4; $preNumber=0
 if($suffix.Success){
  $pre=$suffix.Groups['pre'].Value.ToLowerInvariant()
  if($pre.StartsWith('rc')){$rank=3}
  elseif($pre.StartsWith('beta')){$rank=2}
  elseif($pre.StartsWith('alpha')){$rank=1}
  else{$rank=0}
  $number=[regex]::Match($pre,'([0-9]+)
function ValidateEntry([System.IO.Compression.ZipArchiveEntry]$Entry){
 $name=$Entry.FullName.Replace([char]92,[char]47)
 if([string]::IsNullOrWhiteSpace($name) -or $name.StartsWith('/') -or $name.Contains(':') -or
    $name -match '(^|/)\.\.?(/|$)' -or $name -match '^[A-Za-z]:'){
  throw "Unsafe path in update archive: $($Entry.FullName)"
 }
 if((($Entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000){throw "Archive contains a symbolic link: $name"}
}

try{
 New-Item -ItemType Directory -Force -Path $work|Out-Null
 Log "Starting $Channel update from $CurrentVersion."
 $InstallDirectory=[IO.Path]::GetFullPath($InstallDirectory)
 if(-not(Test-Path -LiteralPath $InstallDirectory -PathType Container)){throw 'Install directory does not exist.'}
 $probe=Join-Path $InstallDirectory ('.u-unlocked-write-'+[guid]::NewGuid().ToString('N'))
 [IO.File]::WriteAllText($probe,'test'); Remove-Item -LiteralPath $probe -Force

 $headers=@{'Accept'='application/vnd.github+json';'User-Agent'='U-Unlocked-Updater';'X-GitHub-Api-Version'='2022-11-28'}
 $releases=@(Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases?per_page=30" -Headers $headers -TimeoutSec 30)
 $release=$releases|Where-Object{-not $_.draft -and ($Channel -eq 'beta' -or -not $_.prerelease)}|Select-Object -First 1
 if(-not $release){throw "No $Channel release is published."}
 $version=([string]$release.tag_name).TrimStart('v','V')
 if((CompareVersion $version $CurrentVersion) -le 0){Log "Already current: $CurrentVersion";Notify "U Unlocked is already up to date (version $CurrentVersion).";return}
 $null=VersionObject $version
 $assetName="U-Unlocked-v$version-Windows-Launcher.zip"
 $asset=$release.assets|Where-Object{$_.name -eq $assetName}|Select-Object -First 1
 if(-not $asset -or [string]$asset.browser_download_url -notmatch '^https://github\.com/'){throw "Release package $assetName is missing or has an unsafe URL."}
 if([int64]$asset.size -le 0 -or [int64]$asset.size -gt 2GB){throw 'Release package size is invalid or too large.'}
 $download=Join-Path $work ($assetName+'.'+[guid]::NewGuid().ToString('N'))
 Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $download -Headers @{'User-Agent'='U-Unlocked-Updater'} -TimeoutSec 180 -UseBasicParsing

 $expected=''
 if([string]$asset.digest -match '^sha256:([0-9a-fA-F]{64})$'){$expected=$Matches[1].ToLowerInvariant()}
 else{
  $sumAsset=$release.assets|Where-Object{$_.name -eq "$assetName.sha256"}|Select-Object -First 1
  if(-not $sumAsset -or [string]$sumAsset.browser_download_url -notmatch '^https://github\.com/'){throw 'No trusted SHA-256 digest or checksum asset; refusing update.'}
  $sum=(Invoke-WebRequest -Uri $sumAsset.browser_download_url -Headers @{'User-Agent'='U-Unlocked-Updater'} -TimeoutSec 30 -UseBasicParsing).Content
  $expected=([regex]::Match([string]$sum,'[0-9a-fA-F]{64}')).Value.ToLowerInvariant()
  if($expected.Length -ne 64){throw 'Release checksum is malformed.'}
 }
 if((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected){throw 'Downloaded package failed SHA-256 verification.'}

 Add-Type -AssemblyName System.IO.Compression
 $archive=[IO.Compression.ZipFile]::OpenRead($download)
 if($archive.Entries.Count -gt 4096){throw 'Update archive has too many entries.'}
 $entries=[Collections.Generic.Dictionary[string,IO.Compression.ZipArchiveEntry]]::new([StringComparer]::OrdinalIgnoreCase)
 [int64]$expanded=0
 foreach($entry in $archive.Entries){
  ValidateEntry $entry
  if($entries.ContainsKey($entry.FullName)){throw "Duplicate archive entry: $($entry.FullName)"}
  $entries.Add($entry.FullName,$entry);$expanded += [int64]$entry.Length
  if($expanded -gt 3GB){throw 'Expanded update archive exceeds 3 GiB.'}
 }
 if(-not $entries.ContainsKey('package-manifest.json')){throw 'Package manifest is missing.'}
 $stream=$entries['package-manifest.json'].Open()
 try{$reader=[IO.StreamReader]::new($stream);try{$manifest=$reader.ReadToEnd()|ConvertFrom-Json}finally{$reader.Dispose()}}finally{$stream.Dispose()}
 if($manifest.schema_version -ne 1 -or [string]$manifest.version -ne $version -or -not $manifest.files){throw 'Package manifest is invalid or mismatched.'}
 $files=@($manifest.files)
 if($files.Count -lt 2 -or $files.Count -gt 256){throw 'Manifest file count is invalid.'}
 $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
 $hasExe=$false
 $stage=Join-Path $InstallDirectory ('.u-unlocked-update-'+[guid]::NewGuid().ToString('N'))
 $new=Join-Path $stage 'new';New-Item -ItemType Directory -Force -Path $new|Out-Null
 foreach($file in $files){
  $name=[string]$file.name;$hash=[string]$file.sha256
  if($name -notmatch '^(U Unlocked\.exe|update-launcher\.ps1|[A-Za-z0-9_.+-]+\.dll)$' -or $name.Contains('..') -or
     -not $seen.Add($name) -or $hash -notmatch '^(?i:[0-9a-f]{64})$'){throw "Invalid manifest file: $name"}
  if(-not $entries.ContainsKey($name)){throw "Manifest file missing from archive: $name"}
  $entry=$entries[$name]
  if($entry.FullName -ne $name -or $entry.Length -gt 512MB){throw "Invalid binary entry: $name"}
  $input=$entry.Open();$output=[IO.File]::Open((Join-Path $new $name),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  try{$input.CopyTo($output);$output.Flush($true)}finally{$output.Dispose();$input.Dispose()}
  if((Get-FileHash -LiteralPath (Join-Path $new $name) -Algorithm SHA256).Hash -ne $hash.ToUpperInvariant()){throw "File hash mismatch: $name"}
  if($name -eq 'U Unlocked.exe'){$hasExe=$true}
 }
 if(-not $hasExe){throw 'Manifest has no launcher executable.'}
 $archive.Dispose();$archive=$null

 $deadline=[DateTime]::UtcNow.AddSeconds(120)
 while([DateTime]::UtcNow -lt $deadline -and (Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue)){Start-Sleep -Milliseconds 250}
 if(Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue){throw 'Launcher is still running; close it and retry.'}

 $rollbackRoot=Join-Path $work 'rollback';New-Item -ItemType Directory -Force -Path $rollbackRoot|Out-Null
 $oldSafe=$CurrentVersion -replace '[^0-9A-Za-z._-]','_'
 $rollback=Join-Path $rollbackRoot ($oldSafe+'-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
 New-Item -ItemType Directory -Force -Path $rollback|Out-Null
 $changed=[Collections.Generic.List[string]]::new()
 try{
  foreach($file in $files){
   $name=[string]$file.name;$target=Join-Path $InstallDirectory $name;$backup=Join-Path $rollback $name
   if(Test-Path -LiteralPath $target -PathType Leaf){Copy-Item -LiteralPath $target -Destination $backup}
   $changed.Add($name)
   Move-Item -LiteralPath (Join-Path $new $name) -Destination $target -Force
  }
  Start-Process -FilePath (Join-Path $InstallDirectory 'U Unlocked.exe') -WorkingDirectory $InstallDirectory|Out-Null
 }catch{
  foreach($name in $changed){
   $target=Join-Path $InstallDirectory $name;$backup=Join-Path $rollback $name
   if(Test-Path -LiteralPath $backup -PathType Leaf){Copy-Item -LiteralPath $backup -Destination $target -Force}
   elseif(Test-Path -LiteralPath $target -PathType Leaf){Remove-Item -LiteralPath $target -Force}
  }
  throw
 }
 Get-ChildItem -LiteralPath $rollbackRoot -Directory|Sort-Object LastWriteTimeUtc -Descending|Select-Object -Skip 3|Remove-Item -Recurse -Force
 Log "Updated $CurrentVersion to $version; rollback saved at $rollback."
 Notify "U Unlocked was updated to version $version. Game files, mods, saves and settings were preserved."
}catch{
 $message=$_.Exception.Message
 try{if(-not(Test-Path -LiteralPath $work -PathType Container)){New-Item -ItemType Directory -Force -Path $work|Out-Null};Log "Update failed: $message"}catch{}
 Notify ("The launcher could not be updated."+[Environment]::NewLine+[Environment]::NewLine+$message+[Environment]::NewLine+"Log: "+$log) $true
 exit 1
}finally{
 if($archive){$archive.Dispose()}
 if($stage -and (Test-Path -LiteralPath $stage)){Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue}
 if($download -and (Test-Path -LiteralPath $download)){Remove-Item -LiteralPath $download -Force -ErrorAction SilentlyContinue}
}
)
  if($number.Success){$preNumber=[int]$number.Groups[1].Value}
 }
 [pscustomobject]@{Number=$v;Rank=$rank;PreNumber=$preNumber}
}
function CompareVersion([string]$A,[string]$B){
 $aObj=VersionObject $A; $bObj=VersionObject $B
 $cmp=$aObj.Number.CompareTo($bObj.Number)
 if($cmp -ne 0){return $cmp}
 if($aObj.Rank -gt $bObj.Rank){return 1}
 if($aObj.Rank -lt $bObj.Rank){return -1}
 if($aObj.PreNumber -gt $bObj.PreNumber){return 1}
 if($aObj.PreNumber -lt $bObj.PreNumber){return -1}
 return 0
}
function ValidateEntry([System.IO.Compression.ZipArchiveEntry]$Entry){
 $name=$Entry.FullName.Replace([char]92,[char]47)
 if([string]::IsNullOrWhiteSpace($name) -or $name.StartsWith('/') -or $name.Contains(':') -or
    $name -match '(^|/)\.\.?(/|$)' -or $name -match '^[A-Za-z]:'){
  throw "Unsafe path in update archive: $($Entry.FullName)"
 }
 if((($Entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000){throw "Archive contains a symbolic link: $name"}
}

try{
 New-Item -ItemType Directory -Force -Path $work|Out-Null
 Log "Starting $Channel update from $CurrentVersion."
 $InstallDirectory=[IO.Path]::GetFullPath($InstallDirectory)
 if(-not(Test-Path -LiteralPath $InstallDirectory -PathType Container)){throw 'Install directory does not exist.'}
 $probe=Join-Path $InstallDirectory ('.u-unlocked-write-'+[guid]::NewGuid().ToString('N'))
 [IO.File]::WriteAllText($probe,'test'); Remove-Item -LiteralPath $probe -Force

 $headers=@{'Accept'='application/vnd.github+json';'User-Agent'='U-Unlocked-Updater';'X-GitHub-Api-Version'='2022-11-28'}
 $releases=@(Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases?per_page=30" -Headers $headers -TimeoutSec 30)
 $release=$releases|Where-Object{-not $_.draft -and ($Channel -eq 'beta' -or -not $_.prerelease)}|Select-Object -First 1
 if(-not $release){throw "No $Channel release is published."}
 $version=([string]$release.tag_name).TrimStart('v','V')
 if((CompareVersion $version $CurrentVersion) -le 0){Log "Already current: $CurrentVersion";Notify "U Unlocked is already up to date (version $CurrentVersion).";return}
 $null=VersionObject $version
 $assetName="U-Unlocked-v$version-Windows-Launcher.zip"
 $asset=$release.assets|Where-Object{$_.name -eq $assetName}|Select-Object -First 1
 if(-not $asset -or [string]$asset.browser_download_url -notmatch '^https://github\.com/'){throw "Release package $assetName is missing or has an unsafe URL."}
 if([int64]$asset.size -le 0 -or [int64]$asset.size -gt 2GB){throw 'Release package size is invalid or too large.'}
 $download=Join-Path $work ($assetName+'.'+[guid]::NewGuid().ToString('N'))
 Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $download -Headers @{'User-Agent'='U-Unlocked-Updater'} -TimeoutSec 180 -UseBasicParsing

 $expected=''
 if([string]$asset.digest -match '^sha256:([0-9a-fA-F]{64})$'){$expected=$Matches[1].ToLowerInvariant()}
 else{
  $sumAsset=$release.assets|Where-Object{$_.name -eq "$assetName.sha256"}|Select-Object -First 1
  if(-not $sumAsset -or [string]$sumAsset.browser_download_url -notmatch '^https://github\.com/'){throw 'No trusted SHA-256 digest or checksum asset; refusing update.'}
  $sum=(Invoke-WebRequest -Uri $sumAsset.browser_download_url -Headers @{'User-Agent'='U-Unlocked-Updater'} -TimeoutSec 30 -UseBasicParsing).Content
  $expected=([regex]::Match([string]$sum,'[0-9a-fA-F]{64}')).Value.ToLowerInvariant()
  if($expected.Length -ne 64){throw 'Release checksum is malformed.'}
 }
 if((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected){throw 'Downloaded package failed SHA-256 verification.'}

 Add-Type -AssemblyName System.IO.Compression
 $archive=[IO.Compression.ZipFile]::OpenRead($download)
 if($archive.Entries.Count -gt 4096){throw 'Update archive has too many entries.'}
 $entries=[Collections.Generic.Dictionary[string,IO.Compression.ZipArchiveEntry]]::new([StringComparer]::OrdinalIgnoreCase)
 [int64]$expanded=0
 foreach($entry in $archive.Entries){
  ValidateEntry $entry
  if($entries.ContainsKey($entry.FullName)){throw "Duplicate archive entry: $($entry.FullName)"}
  $entries.Add($entry.FullName,$entry);$expanded += [int64]$entry.Length
  if($expanded -gt 3GB){throw 'Expanded update archive exceeds 3 GiB.'}
 }
 if(-not $entries.ContainsKey('package-manifest.json')){throw 'Package manifest is missing.'}
 $stream=$entries['package-manifest.json'].Open()
 try{$reader=[IO.StreamReader]::new($stream);try{$manifest=$reader.ReadToEnd()|ConvertFrom-Json}finally{$reader.Dispose()}}finally{$stream.Dispose()}
 if($manifest.schema_version -ne 1 -or [string]$manifest.version -ne $version -or -not $manifest.files){throw 'Package manifest is invalid or mismatched.'}
 $files=@($manifest.files)
 if($files.Count -lt 2 -or $files.Count -gt 256){throw 'Manifest file count is invalid.'}
 $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
 $hasExe=$false
 $stage=Join-Path $InstallDirectory ('.u-unlocked-update-'+[guid]::NewGuid().ToString('N'))
 $new=Join-Path $stage 'new';New-Item -ItemType Directory -Force -Path $new|Out-Null
 foreach($file in $files){
  $name=[string]$file.name;$hash=[string]$file.sha256
  if($name -notmatch '^(U Unlocked\.exe|update-launcher\.ps1|[A-Za-z0-9_.+-]+\.dll)$' -or $name.Contains('..') -or
     -not $seen.Add($name) -or $hash -notmatch '^(?i:[0-9a-f]{64})$'){throw "Invalid manifest file: $name"}
  if(-not $entries.ContainsKey($name)){throw "Manifest file missing from archive: $name"}
  $entry=$entries[$name]
  if($entry.FullName -ne $name -or $entry.Length -gt 512MB){throw "Invalid binary entry: $name"}
  $input=$entry.Open();$output=[IO.File]::Open((Join-Path $new $name),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  try{$input.CopyTo($output);$output.Flush($true)}finally{$output.Dispose();$input.Dispose()}
  if((Get-FileHash -LiteralPath (Join-Path $new $name) -Algorithm SHA256).Hash -ne $hash.ToUpperInvariant()){throw "File hash mismatch: $name"}
  if($name -eq 'U Unlocked.exe'){$hasExe=$true}
 }
 if(-not $hasExe){throw 'Manifest has no launcher executable.'}
 $archive.Dispose();$archive=$null

 $deadline=[DateTime]::UtcNow.AddSeconds(120)
 while([DateTime]::UtcNow -lt $deadline -and (Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue)){Start-Sleep -Milliseconds 250}
 if(Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue){throw 'Launcher is still running; close it and retry.'}

 $rollbackRoot=Join-Path $work 'rollback';New-Item -ItemType Directory -Force -Path $rollbackRoot|Out-Null
 $oldSafe=$CurrentVersion -replace '[^0-9A-Za-z._-]','_'
 $rollback=Join-Path $rollbackRoot ($oldSafe+'-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
 New-Item -ItemType Directory -Force -Path $rollback|Out-Null
 $changed=[Collections.Generic.List[string]]::new()
 try{
  foreach($file in $files){
   $name=[string]$file.name;$target=Join-Path $InstallDirectory $name;$backup=Join-Path $rollback $name
   if(Test-Path -LiteralPath $target -PathType Leaf){Copy-Item -LiteralPath $target -Destination $backup}
   $changed.Add($name)
   Move-Item -LiteralPath (Join-Path $new $name) -Destination $target -Force
  }
  Start-Process -FilePath (Join-Path $InstallDirectory 'U Unlocked.exe') -WorkingDirectory $InstallDirectory|Out-Null
 }catch{
  foreach($name in $changed){
   $target=Join-Path $InstallDirectory $name;$backup=Join-Path $rollback $name
   if(Test-Path -LiteralPath $backup -PathType Leaf){Copy-Item -LiteralPath $backup -Destination $target -Force}
   elseif(Test-Path -LiteralPath $target -PathType Leaf){Remove-Item -LiteralPath $target -Force}
  }
  throw
 }
 Get-ChildItem -LiteralPath $rollbackRoot -Directory|Sort-Object LastWriteTimeUtc -Descending|Select-Object -Skip 3|Remove-Item -Recurse -Force
 Log "Updated $CurrentVersion to $version; rollback saved at $rollback."
 Notify "U Unlocked was updated to version $version. Game files, mods, saves and settings were preserved."
}catch{
 $message=$_.Exception.Message
 try{if(-not(Test-Path -LiteralPath $work -PathType Container)){New-Item -ItemType Directory -Force -Path $work|Out-Null};Log "Update failed: $message"}catch{}
 Notify ("The launcher could not be updated."+[Environment]::NewLine+[Environment]::NewLine+$message+[Environment]::NewLine+"Log: "+$log) $true
 exit 1
}finally{
 if($archive){$archive.Dispose()}
 if($stage -and (Test-Path -LiteralPath $stage)){Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue}
 if($download -and (Test-Path -LiteralPath $download)){Remove-Item -LiteralPath $download -Force -ErrorAction SilentlyContinue}
}
