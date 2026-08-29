# 02-configure-os.ps1
# Configures Windows Server for CloudXR: display adapter, disk, logging
# NOTE: Auto-logon is configured in 06-install-startup.ps1 (after all provisioning is complete).

Write-Host "Configuring OS for CloudXR..."

# Verify GPU is detected
nvidia-smi
if ($LASTEXITCODE -ne 0) {
    Write-Error "NVIDIA GPU not detected. Driver installation may have failed."
    exit 1
}

# Expand partition to fill disk.
# build-ami.sh launches with a 200GB root volume against a ~30GB base partition. A
# silent no-op here leaves the build running VS Build Tools plus a full LOVR build on
# 30GB, so verify the result instead of assuming it.
$before = (Get-Partition -DriveLetter C).Size
$maxSize = (Get-PartitionSupportedSize -DriveLetter C).SizeMax
if ($maxSize -gt $before) {
    Resize-Partition -DriveLetter C -Size $maxSize -ErrorAction SilentlyContinue
    $after = (Get-Partition -DriveLetter C).Size
    if ($after -gt $before) {
        Write-Host "Expanded C: from $([math]::Round($before/1GB,1))GB to $([math]::Round($after/1GB,1))GB"
    } else {
        Write-Warning "Could not expand C: (still $([math]::Round($after/1GB,1))GB of $([math]::Round($maxSize/1GB,1))GB available). The build may run out of disk."
    }
} else {
    Write-Host "C: already fills the disk ($([math]::Round($before/1GB,1))GB)"
}

# Disable Basic Display Adapter (prevents conflicts with NVIDIA GPU).
# Note: -ErrorAction Stop is required for the catch to be reachable - Disable-PnpDevice
# raises non-terminating errors by default, which would otherwise skip the catch and
# fall through to the success message.
$adapters = Get-PnpDevice | Where-Object FriendlyName -like "*Microsoft Basic*" | Where-Object Class -eq "Display"
if (-not $adapters) {
    Write-Host "No Microsoft Basic Display Adapter present (nothing to disable)"
}
foreach ($adapter in $adapters) {
    try {
        Disable-PnpDevice -InstanceId $adapter.InstanceId -Confirm:$false -ErrorAction Stop
        Write-Host "Disabled: $($adapter.FriendlyName)"
    } catch {
        Write-Warning "Could not disable $($adapter.FriendlyName) - may already be inactive: $($_.Exception.Message)"
    }
}

# Enable CloudXR file logging
[System.Environment]::SetEnvironmentVariable("NV_CXR_FILE_LOGGING", "1", "Machine")
[System.Environment]::SetEnvironmentVariable("NV_CXR_OUTPUT_DIR", "C:\cxr-logs", "Machine")
New-Item -ItemType Directory -Path C:\cxr-logs -Force

Write-Host "OS configuration complete. Reboot required."
