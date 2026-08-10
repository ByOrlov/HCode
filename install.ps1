# HCode installer — Windows (PowerShell).
# Usage:  irm https://raw.githubusercontent.com/ByOrlov/HCode/master/install.ps1 | iex
#Requires -Version 5.1
[CmdletBinding()] param()

$ErrorActionPreference = 'Stop'

$Repo = 'ByOrlov/HCode'
$InstallDir = if ($env:HCODE_INSTALL_DIR) { $env:HCODE_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'hcode\bin' }
$BinName = 'hcode.exe'

function Write-Info($msg) { Write-Host "  $msg" }
function Write-Err($msg)  { Write-Host "✗ $msg" -ForegroundColor Red }

# Returns $true if the binary starts and prints a version (i.e. all its DLL
# dependencies resolve). Used to decide whether we need to install deps.
function Test-HcodeStarts($path) {
    try {
        $out = & $path --version 2>&1
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

# Installs the Windows runtime dependencies (OpenSSL, libyaml, pcre2) required
# by hcode.exe. Tries winget/choco for OpenSSL first, then unconditionally
# extracts the pinned DLL bundle next to the binary so all four DLLs are
# present regardless of which package manager (if any) is available.
function Ensure-WindowsDeps($binPath) {
    if (Test-HcodeStarts $binPath) {
        Write-Info "Runtime dependencies already available."
        return
    }
    Write-Info "Binary failed to start (likely missing DLLs). Installing runtime dependencies…"

    $installDir = Split-Path $binPath -Parent

    # OpenSSL via a system package manager, best-effort. Covers libcrypto/libssl
    # system-wide; pcre2/yaml are not in winget/choco and come from the bundle.
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        Write-Info "Trying: winget install OpenSSL.OpenSSL"
        & winget install --id OpenSSL.OpenSSL --silent --accept-package-agreements --accept-source-agreements 2>&1 |
            Out-Host
    } elseif (Get-Command choco -ErrorAction SilentlyContinue) {
        Write-Info "Trying: choco install openssl -y"
        & choco install openssl -y 2>&1 | Out-Host
    }

    # Guaranteed fallback: the pinned DLL bundle from the latest release.
    $depsUrl = "https://github.com/$Repo/releases/latest/download/hcode-deps-windows.zip"
    $depsZip = Join-Path $installDir "hcode-deps-windows.zip"
    try {
        Write-Info "Downloading runtime DLL bundle: $depsUrl"
        Invoke-WebRequest -Uri $depsUrl -OutFile $depsZip -UseBasicParsing
    } catch {
        Write-Err "Could not download runtime DLL bundle."
        Write-Err "Install OpenSSL (libcrypto/libssl), libyaml and pcre2 manually next to hcode.exe."
        return
    }
    try {
        Expand-Archive -Path $depsZip -DestinationPath $installDir -Force
        Write-Info "Extracted runtime DLLs to $installDir"
    } catch {
        Write-Err "Failed to extract runtime DLL bundle: $_"
        return
    } finally {
        Remove-Item $depsZip -ErrorAction SilentlyContinue
    }

    if (Test-HcodeStarts $binPath) {
        Write-Info "Runtime dependencies installed."
    } else {
        Write-Err "Binary still fails to start after installing dependencies."
        Write-Err "Run '$binPath --version' manually to see the missing DLL."
    }
}

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

    # --- Runtime dependencies -------------------------------------------------
    # hcode.exe links dynamically against OpenSSL (libcrypto/libssl), libyaml
    # and pcre2. These DLLs are not present on a stock Windows install, so we
    # detect a missing-DLL failure by trying to run the binary and, on failure,
    # install the dependencies: OpenSSL via winget/choco when available, then
    # always drop the pinned runtime DLL bundle next to the binary.
    Ensure-WindowsDeps $Dest

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
