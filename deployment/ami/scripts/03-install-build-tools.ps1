# 03-install-build-tools.ps1
# Installs build prerequisites: Git, Node.js, Python, VS Build Tools, CMake
#
# Every download and installer is checked. Without these checks the script exits 0
# even when nothing installed (PowerShell's default ErrorActionPreference is
# 'Continue'), SSM reports the step as Success, and the failure only surfaces later
# as an opaque build.bat error in 04-install-app.ps1.

$ErrorActionPreference = "Stop"

Write-Host "Installing build prerequisites..."

# Download a file and fail loudly if it did not arrive.
function Get-Installer {
    param([string]$Uri, [string]$OutFile)
    Write-Host "  Downloading $(Split-Path $OutFile -Leaf)..."
    try {
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing
    } catch {
        Write-Error "Download failed: $Uri`n$($_.Exception.Message)"
        exit 1
    }
    if (-not (Test-Path $OutFile) -or (Get-Item $OutFile).Length -eq 0) {
        Write-Error "Download produced no usable file: $OutFile"
        exit 1
    }
    Write-Host "    $([math]::Round((Get-Item $OutFile).Length / 1MB, 1)) MB"
}

# Run an installer and fail on any exit code outside the allowed set.
# 3010 = success, reboot required (normal for VS Build Tools and some MSIs).
function Invoke-Installer {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [int[]]$AllowedExitCodes = @(0, 3010)
    )
    $proc = Start-Process -FilePath $FilePath -ArgumentList $Arguments -Wait -PassThru
    if ($AllowedExitCodes -notcontains $proc.ExitCode) {
        Write-Error "$(Split-Path $FilePath -Leaf) failed with exit code $($proc.ExitCode)"
        exit 1
    }
    Write-Host "    exit code $($proc.ExitCode)"
}

# Git
Write-Host "Installing Git..."
Get-Installer -Uri "https://github.com/git-for-windows/git/releases/download/v2.47.1.windows.2/Git-2.47.1.2-64-bit.exe" -OutFile C:\git-installer.exe
Invoke-Installer -FilePath C:\git-installer.exe -Arguments @("/VERYSILENT", "/NORESTART")

# Node.js v20 LTS
Write-Host "Installing Node.js..."
Get-Installer -Uri "https://nodejs.org/dist/v20.19.0/node-v20.19.0-x64.msi" -OutFile C:\nodejs.msi
Invoke-Installer -FilePath msiexec.exe -Arguments @("/i", "C:\nodejs.msi", "/quiet", "/norestart")

# Python 3 (required by LOVR's glslang dependency)
Write-Host "Installing Python..."
Get-Installer -Uri "https://www.python.org/ftp/python/3.12.8/python-3.12.8-amd64.exe" -OutFile C:\python-installer.exe
Invoke-Installer -FilePath C:\python-installer.exe -Arguments @("/quiet", "InstallAllUsers=1", "PrependPath=1")

# Visual Studio 2022 Build Tools (CMake + C++)
Write-Host "Installing VS Build Tools (this takes several minutes)..."
Get-Installer -Uri "https://aka.ms/vs/17/release/vs_BuildTools.exe" -OutFile C:\vs_buildtools.exe
Invoke-Installer -FilePath C:\vs_buildtools.exe -Arguments @(
    "--quiet", "--wait", "--norestart",
    "--add", "Microsoft.VisualStudio.Workload.VCTools",
    "--add", "Microsoft.VisualStudio.Component.VC.CMake.Project",
    "--includeRecommended"
)

# CMake standalone (fallback)
Write-Host "Installing CMake..."
Get-Installer -Uri "https://github.com/Kitware/CMake/releases/download/v3.31.4/cmake-3.31.4-windows-x86_64.msi" -OutFile C:\cmake.msi
Invoke-Installer -FilePath msiexec.exe -Arguments @("/i", "C:\cmake.msi", "/quiet", "/norestart", "ADD_CMAKE_TO_PATH=System")

# Verify the toolchain 04-install-app.ps1 depends on actually landed
$required = @{
    "Git"          = "C:\Program Files\Git\bin\git.exe"
    "Node.js"      = "C:\Program Files\nodejs\npm.cmd"
    "Python"       = "C:\Program Files\Python312\python.exe"
    "VS BuildTools"= "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\VsDevCmd.bat"
    "CMake"        = "C:\Program Files\CMake\bin\cmake.exe"
}
$missing = @()
foreach ($name in $required.Keys) {
    if (Test-Path $required[$name]) {
        Write-Host "  OK: $name"
    } else {
        Write-Host "  MISSING: $name -> $($required[$name])"
        $missing += $name
    }
}
if ($missing.Count -gt 0) {
    Write-Error "Build prerequisites missing after install: $($missing -join ', ')"
    exit 1
}

# Append to the machine PATH, preserving its registry type.
# The default machine Path is REG_EXPAND_SZ containing tokens like %SystemRoot%;
# [Environment]::SetEnvironmentVariable would rewrite it as REG_SZ and leave those
# tokens unexpanded for later processes. Writing through the registry provider with
# an explicit ExpandString type avoids that. Also idempotent - re-running this
# script will not append duplicate entries.
$pathKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment"
$currentPath = (Get-ItemProperty -Path $pathKey -Name Path).Path
$additions = @(
    "C:\Program Files\Git\bin",
    "C:\Program Files\Git\cmd",
    "C:\Program Files\CMake\bin"
)
$existing = $currentPath -split ';'
$toAdd = $additions | Where-Object { $existing -notcontains $_ }
if ($toAdd) {
    $newPath = ($currentPath.TrimEnd(';') + ';' + ($toAdd -join ';'))
    Set-ItemProperty -Path $pathKey -Name Path -Value $newPath -Type ExpandString
    Write-Host "Added to machine PATH: $($toAdd -join ', ')"
} else {
    Write-Host "Machine PATH already contains the required entries."
}

Write-Host "Build prerequisites installed."
