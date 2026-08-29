# 04-install-app.ps1
# ============================================================================
# YOUR XR APPLICATION GOES HERE
#
# This script installs the OpenXR application that will be streamed via CloudXR.
# By default, it builds the NVIDIA LOVR sample for demonstration purposes.
#
# REPLACE THIS SCRIPT with your own application's installation steps.
# Everything else in this AMI build is generic CloudXR infrastructure.
#
# Requirements for your application:
#   - Must be an OpenXR application
#   - Must be installed to a known path (referenced by the startup script)
#   - Should not require user interaction to launch
# ============================================================================

Write-Host "Installing XR application (LOVR sample)..."

# Refresh PATH for this session
$env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine")

# Override CloudXR Runtime version to 6.2.1 (LOVR build.bat defaults to 6.2.0)
$env:CLOUDXR_RUNTIME_VERSION = "6.2.1"

# Clone the LOVR sample at a pinned commit.
# The upstream repo publishes no git tags or releases, so "v1.2.0" cannot be pinned by
# tag name. This SHA is the commit whose message is "Release 1.2.0" (2026-07-08) and is
# what this architecture was validated against. Tracking a moving 'main' instead would
# silently change the AMI contents and break the version claims in the docs.
$lovrCommit = "6b30ddc1c20117a414d2eb5068686ad6b0fe3a31"   # LOVR sample v1.2.0
$git = "C:\Program Files\Git\bin\git.exe"

& $git clone https://github.com/NVIDIA/cloudxr-lovr-sample.git C:\lovr
if ($LASTEXITCODE -ne 0) {
    Write-Error "git clone of cloudxr-lovr-sample failed (exit $LASTEXITCODE)"
    exit 1
}

& $git -C C:\lovr checkout --quiet $lovrCommit
if ($LASTEXITCODE -ne 0) {
    Write-Error "git checkout of $lovrCommit failed (exit $LASTEXITCODE)"
    exit 1
}
Write-Host "Checked out LOVR sample at $lovrCommit (v1.2.0)"

# Build (from VS Developer Command Prompt context)
$buildCmd = @"
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\VsDevCmd.bat" -arch=amd64
set PATH=%PATH%;C:\Program Files\Git\bin;C:\Program Files\Git\cmd;C:\Program Files\nodejs;C:\Program Files\Python312;C:\Program Files\CMake\bin
cd /d C:\lovr
build.bat
"@
Set-Content -Path C:\build-lovr.bat -Value $buildCmd
cmd /c C:\build-lovr.bat
$buildExit = $LASTEXITCODE

if (-not (Test-Path "C:\lovr\build\Debug\lovr.exe")) {
    Write-Error "LOVR build failed - lovr.exe not found (build.bat exit $buildExit)"
    exit 1
}

# The OpenXR runtime manifest is what 05-configure-cloudxr.ps1 registers in the
# registry. Without it the AMI builds cleanly but no OpenXR runtime is active, and
# 05 only emits a warning - so fail loudly here instead.
if (-not (Test-Path "C:\lovr\build\Debug\openxr_cloudxr.json")) {
    Write-Error "CloudXR OpenXR runtime manifest not found at C:\lovr\build\Debug\openxr_cloudxr.json"
    exit 1
}

# Informational: record which CloudXR Runtime actually landed. The version is chosen by
# upstream's build.bat via CLOUDXR_RUNTIME_VERSION, so log the evidence rather than
# trusting the request silently. Non-fatal by design - the layout is upstream's to change.
Write-Host "Requested CloudXR Runtime version: $env:CLOUDXR_RUNTIME_VERSION"
$runtimeHits = Get-ChildItem -Path C:\lovr -Recurse -Directory -Filter "*CloudXR*" -ErrorAction SilentlyContinue |
    Select-Object -First 5 -ExpandProperty FullName
if ($runtimeHits) {
    Write-Host "CloudXR runtime paths found:"
    $runtimeHits | ForEach-Object { Write-Host "  $_" }
} else {
    Write-Warning "Could not locate a CloudXR runtime directory under C:\lovr to confirm the version."
}

Write-Host "LOVR sample built successfully."
