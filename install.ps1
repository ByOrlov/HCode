# HCode installer — Windows (PowerShell).
# Usage:  irm https://raw.githubusercontent.com/ByOrlov/HCode/main/install.ps1 | iex
#Requires -Version 5.1
[CmdletBinding()] param()

$ErrorActionPreference = 'Stop'

$Repo = 'ByOrlov/HCode'
$InstallDir = if ($env:HCODE_INSTALL_DIR) { $env:HCODE_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'hcode\bin' }
$BinName = 'hcode.exe'

function Write-Info($msg) { Write-Host "  $msg" }
function Write-Err($msg)  { Write-Host "✗ $msg" -ForegroundColor Red }

# --- Detect arch --------------------------------------------------------------
$Arch = $env:PROCESSOR_ARCHITECTURE
if ($Arch -eq 'AMD64' -or $Arch -eq 'x64') {
    $arch = 'x86_64'
} else {
    Write-Err "Unsupported architecture: $Arch (this installer covers x86_64)"
    exit 1
}

$Asset = "hcode-${arch}-windows.zip"
$Url = "https://github.com/$Repo/releases/latest/download/$Asset"

Write-Host "Installing HCode for ${arch}-windows…" -ForegroundColor White
Write-Info "Release asset: $Asset"
Write-Info "Install dir:   $InstallDir"

# --- Download -----------------------------------------------------------------
$Tmp = New-Item -ItemType Directory -Path ([System.IO.Path]::GetTempPath() + "hcode-$(New-Guid)") -Force
try {
    $ZipPath = Join-Path $Tmp.FullName $Asset
    Write-Info "Downloading $Url…"
    try {
        Invoke-WebRequest -Uri $Url -OutFile $ZipPath -UseBasicParsing
    } catch {
        Write-Err "Download failed."
        Write-Err "If you're on ${arch}-windows, the asset may not be published yet."
        Write-Err "Check available assets at: https://github.com/$Repo/releases/latest"
        exit 1
    }

    # --- Verify + extract -----------------------------------------------------
    Write-Info "Extracting…"
    Expand-Archive -Path $ZipPath -DestinationPath $Tmp.FullName -Force

    # --- Install --------------------------------------------------------------
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    $Src = Join-Path $Tmp.FullName $BinName
    $Dest = Join-Path $InstallDir $BinName
    Move-Item -Path $Src -Destination $Dest -Force
    Write-Info "Installed $Dest"

    # --- PATH -----------------------------------------------------------------
    $UserPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    if ($UserPath -notlike "*$InstallDir*") {
        $NewPath = if ($UserPath) { "$UserPath;$InstallDir" } else { $InstallDir }
        [Environment]::SetEnvironmentVariable('PATH', $NewPath, 'User')
        # Also update the current session.
        $env:PATH = "$env:PATH;$InstallDir"
        Write-Info "Added $InstallDir to user PATH."
        Write-Info "Restart your terminal for PATH to take effect."
    }

    # --- Done -----------------------------------------------------------------
    Write-Host "✓ HCode installed." -ForegroundColor Green
    try {
        $Version = & $Dest --version 2>$null
        Write-Info "Version: $Version"
    } catch {
        Write-Info "Version: unknown"
    }
    Write-Info "Run 'hcode' to start. Use '/upgrade' inside the TUI to update later."
}
finally {
    Remove-Item -Recurse -Force $Tmp.FullName -ErrorAction SilentlyContinue
}
