# 06-install-startup.ps1
# Installs the boot-time startup script and configures auto-logon.
#
# The startup script self-discovers its configuration from:
# - Instance tags (Pool = webrtc/native)
# - Instance metadata (region, availability zone, instance ID, public IP)
# - Hardcoded DynamoDB table name (CloudXRInstances)
#
# No EIPs are used. Instances get auto-assigned public IPs from the subnet.
# No UserData or EC2Launch reset is used. Auto-logon is baked directly into
# the AMI (same approach as the tested Quest 3 MVP demo).

Write-Host "Installing startup script..."

# Download the boot-time startup script from the build staging bucket.
# Verified rather than assumed: if this download fails silently, the scheduled task
# below points at a file that does not exist. The AMI then builds "successfully" and
# every instance launched from it boots to an idle desktop with no CloudXR runtime.
$startupDest = "C:\cloudxr-config\startup.ps1"
New-Item -ItemType Directory -Path "C:\cloudxr-config" -Force | Out-Null

# The bucket name is written to disk by build-ami.sh before this script runs
$s3Bucket = (Get-Content C:\cloudxr-staging-bucket.txt -ErrorAction Stop).Trim()
if (-not $s3Bucket) {
    Write-Error "Staging bucket name in C:\cloudxr-staging-bucket.txt is empty"
    exit 1
}

# Region from IMDSv2. Fail loudly - Read-S3Object with a null region errors in a way
# that is easy to miss when ErrorActionPreference is the default 'Continue'.
try {
    $imdsToken = Invoke-RestMethod -Uri "http://169.254.169.254/latest/api/token" -Method PUT `
        -Headers @{"X-aws-ec2-metadata-token-ttl-seconds"="60"} -ErrorAction Stop
    $region = Invoke-RestMethod -Uri "http://169.254.169.254/latest/meta-data/placement/region" `
        -Headers @{"X-aws-ec2-metadata-token"=$imdsToken} -ErrorAction Stop
} catch {
    Write-Error "Could not read region from instance metadata: $($_.Exception.Message)"
    exit 1
}
if (-not $region) {
    Write-Error "Instance metadata returned an empty region"
    exit 1
}

try {
    Read-S3Object -BucketName $s3Bucket -Key "build-steps/startup.ps1" -File $startupDest -Region $region -ErrorAction Stop | Out-Null
} catch {
    Write-Error "Failed to download startup.ps1 from s3://$s3Bucket/build-steps/startup.ps1 : $($_.Exception.Message)"
    exit 1
}

if (-not (Test-Path $startupDest) -or (Get-Item $startupDest).Length -eq 0) {
    Write-Error "startup.ps1 was not written to $startupDest - the AMI would boot with no CloudXR runtime"
    exit 1
}
Write-Host "Startup script installed to $startupDest ($([math]::Round((Get-Item $startupDest).Length / 1KB, 1)) KB)"

# Create a scheduled task that runs the startup script on boot
# Uses LogonType Interactive - requires auto-logon to have established Session 1
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File C:\cloudxr-config\startup.ps1"
$trigger = New-ScheduledTaskTrigger -AtLogon
$principal = New-ScheduledTaskPrincipal -UserId "Administrator" -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

Register-ScheduledTask -TaskName "CloudXR-Startup" -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force
Write-Host "Scheduled task 'CloudXR-Startup' registered (runs at logon)"

# Configure auto-logon (required for interactive desktop session / GPU access).
#
# CHANGE THIS PASSWORD before building your own AMI. It is baked into the image and
# stored in cleartext in the registry (Windows requires that for auto-logon), so the
# value below is public knowledge. It is only reachable from the instance itself -
# no security group in this architecture opens RDP (3389) - but treat it as a
# placeholder, not a secret. For production, fetch a per-instance password from
# Secrets Manager at boot instead of baking one in (see architecture.md ->
# Production Considerations -> Security).
$password = "CloudXR-Instance-2026!"

net user Administrator $password
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to set the Administrator password (net user exit $LASTEXITCODE). Auto-logon would silently fail."
    exit 1
}

# These three values must be REG_SZ. Winlogon reads AutoAdminLogon as a string; if the
# value does not already exist, Set-ItemProperty without -Type would create it as
# REG_DWORD and Winlogon would ignore it. That would mean no interactive Session 1, so
# the scheduled task above never fires and the instance never starts streaming.
$RegPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
Set-ItemProperty -Path $RegPath -Name AutoAdminLogon  -Value "1"             -Type String
Set-ItemProperty -Path $RegPath -Name DefaultUserName -Value "Administrator" -Type String
Set-ItemProperty -Path $RegPath -Name DefaultPassword -Value $password       -Type String

# Verify what actually landed, since a silent failure here disables the whole boot chain
$winlogon = Get-ItemProperty -Path $RegPath
if ($winlogon.AutoAdminLogon -ne "1" -or $winlogon.DefaultUserName -ne "Administrator") {
    Write-Error "Auto-logon registry values did not apply (AutoAdminLogon='$($winlogon.AutoAdminLogon)', DefaultUserName='$($winlogon.DefaultUserName)')"
    exit 1
}
Write-Host "Auto-logon configured for Administrator (AutoAdminLogon=1)"

Write-Host "Startup script, scheduled task, and auto-logon configured."
