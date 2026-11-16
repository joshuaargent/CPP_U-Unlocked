# Applies the U Unlocked-owned branding overlay to an isolated Smash4PC source copy.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SourceRoot
)

$ErrorActionPreference = 'Stop'
$sourceRoot = (Resolve-Path -LiteralPath $SourceRoot).Path
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Replace-RequiredText {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$OldText,
        [Parameter(Mandatory = $true)][string]$NewText,
        [Parameter(Mandatory = $true)][int]$ExpectedCount
    )

    $filePath = Join-Path $sourceRoot $RelativePath
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        throw "Branding target is missing: $RelativePath"
    }

    $content = [System.IO.File]::ReadAllText($filePath)
    $actualCount = ([regex]::Matches($content, [regex]::Escape($OldText))).Count
    if ($actualCount -ne $ExpectedCount) {
        throw "Branding patch drift in $RelativePath. Expected $ExpectedCount occurrence(s) of '$OldText', found $actualCount. Refusing a partial or unsafe patch."
    }

    $updated = $content.Replace($OldText, $NewText)
    [System.IO.File]::WriteAllText($filePath, $updated, $utf8NoBom)
}

# Executable, window, error-dialog, settings-header and HTTP user-agent identity.
Replace-RequiredText 'launcher/smash/main.cpp' 'Smash 4 PC' 'U Unlocked' 9
Replace-RequiredText 'launcher/smash/main.cpp' 'SMASH 4 PC' 'U UNLOCKED' 1
Replace-RequiredText 'launcher/smash/main.cpp' 'constexpr const char* kVersion = "0.1.2";' 'constexpr const char* kVersion = "0.1.0-dev";' 1
Replace-RequiredText 'launcher/smash/main.cpp' 'paint_.rect(0, 0, W, H, {0.10f, 0.14f, 0.32f}, {0.04f, 0.06f, 0.16f}, {0.01f, 0.01f, 0.04f}, {0.03f, 0.04f, 0.12f});' 'paint_.rect(0, 0, W, H, {0.055f, 0.065f, 0.09f}, {0.035f, 0.045f, 0.07f}, {0.012f, 0.018f, 0.028f}, {0.02f, 0.03f, 0.045f});' 1
Replace-RequiredText 'CMakeLists.txt' 'Smash 4 PC' 'U Unlocked' 2
Replace-RequiredText 'runtime/src/smash_main.cpp' 'Smash 4 PC' 'U Unlocked' 5
Replace-RequiredText 'runtime/src/smash_overlay.cpp' 'Smash 4 PC' 'U Unlocked' 2
Replace-RequiredText 'runtime/src/smash_overlay.cpp' 'SMASH 4 PC' 'U UNLOCKED' 1
Replace-RequiredText 'runtime/src/host/http.cpp' 'Smash 4 PC' 'U Unlocked' 2
Replace-RequiredText 'runtime/src/host/netplay.cpp' 'Smash 4 PC' 'U Unlocked' 2
Replace-RequiredText 'runtime/src/host/display_settings.h' 'Smash 4 PC' 'U Unlocked' 1
Replace-RequiredText 'runtime/src/host/paint.h' 'Smash 4 PC' 'U Unlocked' 1
Replace-RequiredText 'runtime/src/host/window.h' 'Smash 4 PC' 'U Unlocked' 1
Replace-RequiredText 'runtime/src/smash_logo.cpp' 'Smash 4 PC' 'U Unlocked' 1
Replace-RequiredText 'runtime/res/smash.rc' 'Smash 4 PC' 'U Unlocked' 1
Replace-RequiredText 'runtime/res/smash.rc' 'smash.ico' 'u-unlocked.ico' 1

# The upstream build script must copy the renamed launcher and must not copy its own game artwork.
Replace-RequiredText 'tools/windows/build-smash.ps1' 'Smash 4 PC' 'U Unlocked' 2
Replace-RequiredText 'tools/windows/build-smash.ps1' 'Copy-Item (Join-Path $upstream ''assets\smash\logo.png'') (Join-Path $play ''title-logo.png'')' '# U Unlocked supplies its own launcher identity; upstream title artwork is not copied.' 1
Replace-RequiredText 'tools/windows/build-smash.ps1' 'Copy-Item (Join-Path $upstream ''assets\smash\launcher-background.jpg'') $play' '# U Unlocked supplies its own launcher background; upstream game artwork is not copied.' 1

$iconScript = Join-Path $PSScriptRoot 'new-u-unlocked-icon.ps1'
if (-not (Test-Path -LiteralPath $iconScript -PathType Leaf)) {
    throw "The U Unlocked icon generator is missing: $iconScript"
}
& $iconScript -SourceRoot $sourceRoot

Write-Host 'Applied the pinned U Unlocked branding overlay.' -ForegroundColor Green
