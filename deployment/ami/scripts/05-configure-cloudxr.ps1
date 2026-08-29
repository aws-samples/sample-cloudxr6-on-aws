# 05-configure-cloudxr.ps1
# Configures CloudXR Runtime: OpenXR registry fix + Windows Firewall rules
# Note: enable-ice and the STUN server properties are set at boot time via the
# Runtime Management API (Lua bindings in cloudxr_manager.lua) — not via env vars.
# This follows NVIDIA's recommended approach per the Runtime Management API docs.

Write-Host "Configuring CloudXR Runtime..."

# Register OpenXR runtime in Windows registry
# Required because the OpenXR loader ignores XR_RUNTIME_JSON when running as Administrator
# (which is always the case on Windows Server)
$runtimePath = "C:\lovr\build\Debug\openxr_cloudxr.json"
if (Test-Path $runtimePath) {
    reg add "HKLM\SOFTWARE\Khronos\OpenXR\1" /v ActiveRuntime /t REG_SZ /d $runtimePath /f
    Write-Host "OpenXR runtime registered: $runtimePath"
} else {
    Write-Warning "OpenXR runtime JSON not found at expected path. Ensure your app build produces this file."
}

# Configure Windows Firewall for CloudXR ports
# (per NVIDIA Network Setup docs — required for both signaling and media)
netsh advfirewall firewall add rule name="CloudXR WebRTC Signaling" dir=in action=allow protocol=TCP localport=49100
netsh advfirewall firewall add rule name="CloudXR Native Signaling" dir=in action=allow protocol=TCP localport=48010
netsh advfirewall firewall add rule name="CloudXR Media" dir=in action=allow protocol=UDP localport=47998-48012
Write-Host "Firewall rules added for ports 49100/TCP, 48010/TCP, 47998-48012/UDP"

Write-Host "CloudXR configuration complete."
