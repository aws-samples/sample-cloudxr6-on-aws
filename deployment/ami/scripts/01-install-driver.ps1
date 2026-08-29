# 01-install-driver.ps1
# Installs NVIDIA GRID driver from Amazon's S3 bucket

Write-Host "Installing NVIDIA GRID driver..."

$Bucket = "ec2-windows-nvidia-drivers"
$KeyPrefix = "latest"
$Region = "us-east-1"

Write-Host "Listing objects in s3://$Bucket/$KeyPrefix ..."
$Objects = Get-S3Object -BucketName $Bucket -KeyPrefix $KeyPrefix -Region $Region
$DriverCandidates = @($Objects | Where-Object Key -like "*.exe")

if ($DriverCandidates.Count -eq 0) {
    Write-Error "No driver .exe found in s3://$Bucket/$KeyPrefix"
    exit 1
}

# Be explicit about which driver was chosen. If Amazon ever publishes more than one
# variant under this prefix, silently taking the first key would install an
# unpredictable driver - so log every candidate and pick the newest deterministically.
if ($DriverCandidates.Count -gt 1) {
    Write-Host "Multiple driver candidates found:"
    $DriverCandidates | ForEach-Object { Write-Host "  $($_.Key)  ($($_.LastModified))" }
}
$DriverKey = ($DriverCandidates | Sort-Object LastModified -Descending | Select-Object -First 1).Key
Write-Host "Selected driver: $DriverKey"

Write-Host "Downloading: $DriverKey"
Read-S3Object -BucketName $Bucket -Key $DriverKey -File "C:\nvidia-driver.exe" -Region $Region

if (-not (Test-Path "C:\nvidia-driver.exe")) {
    Write-Error "Driver download failed"
    exit 1
}

$size = (Get-Item "C:\nvidia-driver.exe").Length / 1MB
Write-Host "Downloaded driver: $([math]::Round($size, 1)) MB"

Write-Host "Installing driver (silent)..."
$proc = Start-Process -FilePath "C:\nvidia-driver.exe" -ArgumentList "-s" -Wait -PassThru
Write-Host "Driver installer exit code: $($proc.ExitCode)"

# 0 = success, 1 = success/reboot required for the NVIDIA installer. Anything else is a
# real failure. The nvidia-smi gate in 02-configure-os.ps1 is the definitive check, but
# failing here attributes the problem to the driver install rather than surfacing it one
# reboot later as a confusing "GPU not detected".
if ($proc.ExitCode -notin @(0, 1)) {
    Write-Error "NVIDIA driver installation failed with exit code $($proc.ExitCode)"
    exit 1
}

Write-Host "Driver installation complete. Reboot required."
