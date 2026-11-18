function Get-UUnlockedToolchainRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:U_UNLOCKED_TOOLCHAIN_ROOT)) {
        return [IO.Path]::GetFullPath($env:U_UNLOCKED_TOOLCHAIN_ROOT)
    }
    $base = if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $env:LOCALAPPDATA
    } else {
        $env:TEMP
    }
    if ([string]::IsNullOrWhiteSpace($base)) {
        throw 'Neither LOCALAPPDATA nor TEMP is available for the pinned toolchain.'
    }
    return Join-Path $base 'U Unlocked\Toolchain'
}
