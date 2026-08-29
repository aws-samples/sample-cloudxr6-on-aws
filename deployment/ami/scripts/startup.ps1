# CloudXR Instance Startup Script
# Runs on boot via scheduled task in the interactive session (Session 1).
# Self-discovers configuration from instance metadata and tags.
#
# Runtime properties (enable-ice, stun-server-ip, stun-server-port) are set via
# the Runtime Management API (Lua bindings) per NVIDIA's recommended approach.

$logPath = "C:\cxr-logs\startup.log"
New-Item -ItemType Directory -Path "C:\cxr-logs" -Force | Out-Null

# STUN server used by ICE for public endpoint discovery.
# Change these two values to point at your own STUN infrastructure if preferred.
$stunServer = "stun.l.google.com"
$stunPort   = 19302

function Log($msg) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $msg" | Out-File -Append $logPath
    Write-Host $msg
}

try {
    Log "Starting CloudXR instance configuration..."

    # Load AWS PowerShell module
    Import-Module AWSPowerShell -ErrorAction Stop
    Log "AWS PowerShell module loaded"

    # Get instance metadata (IMDSv2)
    $token = Invoke-RestMethod -Uri "http://169.254.169.254/latest/api/token" -Method PUT -Headers @{"X-aws-ec2-metadata-token-ttl-seconds"="60"}
    $instanceId = Invoke-RestMethod -Uri "http://169.254.169.254/latest/meta-data/instance-id" -Headers @{"X-aws-ec2-metadata-token"=$token}
    $privateIp = Invoke-RestMethod -Uri "http://169.254.169.254/latest/meta-data/local-ipv4" -Headers @{"X-aws-ec2-metadata-token"=$token}
    $az = Invoke-RestMethod -Uri "http://169.254.169.254/latest/meta-data/placement/availability-zone" -Headers @{"X-aws-ec2-metadata-token"=$token}
    $regionMeta = Invoke-RestMethod -Uri "http://169.254.169.254/latest/meta-data/placement/region" -Headers @{"X-aws-ec2-metadata-token"=$token}
    Log "Instance: $instanceId, PrivateIP: $privateIp, AZ: $az, Region: $regionMeta"

    # Get public IP from metadata (auto-assigned from subnet).
    # The instance must be publicly reachable for direct UDP media; ICE discovers the
    # public mapping via STUN. This value is recorded in the registry for observability.
    $publicIp = Invoke-RestMethod -Uri "http://169.254.169.254/latest/meta-data/public-ipv4" -Headers @{"X-aws-ec2-metadata-token"=$token} -ErrorAction SilentlyContinue
    if (-not $publicIp) {
        Log "ERROR: No public IP found. Ensure subnet has MapPublicIpOnLaunch enabled."
        exit 1
    }
    Log "Public IP: $publicIp"

    # Get pool type from instance tags
    $tags = Get-EC2Tag -Filter @{Name="resource-id";Values=$instanceId} -Region $regionMeta
    $poolTag = ($tags | Where-Object Key -eq "Pool").Value
    if (-not $poolTag) { $poolTag = "webrtc" }
    Log "Pool: $poolTag"

    # Configure CloudXR runtime properties in cloudxr_manager.lua
    # Per NVIDIA's cloud deployment guide: enable ICE, and configure a STUN server so
    # the runtime can discover its public-facing media candidate.
    # Properties set via Runtime Management API (Lua bindings):
    #   - enable-ice: true (set explicitly — the default is false for auto-native)
    #   - stun-server-ip / stun-server-port: STUN endpoint for ICE candidate discovery
    # endpoint-ip is intentionally left unset (default: bind all interfaces) and
    # media-port is left at its default (0 = auto-assign) — ICE negotiates the media path.
    $luaPath = "C:\lovr\plugins\nvidia\examples\cloudxr\cloudxr_manager.lua"
    if (Test-Path $luaPath) {
        $luaContent = Get-Content $luaPath -Raw
        if ($luaContent -notmatch "stun-server-ip") {
            $insertBlock = "`n-- Cloud deployment configuration (auto-configured by startup script)`n"
            $insertBlock += "-- Per NVIDIA cloud deployment guide: ICE + STUN for media establishment`n"
            $insertBlock += "nv_cxr.setRuntimeBooleanProperty(`"enable-ice`", true)`n"
            $insertBlock += "nv_cxr.setRuntimeStringProperty(`"stun-server-ip`", `"$stunServer`")`n"
            $insertBlock += "nv_cxr.setRuntimeInt64Property(`"stun-server-port`", $stunPort)`n"
            $luaContent = $luaContent -replace "(if not nv_cxr\.startRuntime\(\))", "$insertBlock`$1"
            Set-Content -Path $luaPath -Value $luaContent
            Log "Configured enable-ice=true, stun-server=${stunServer}:${stunPort} in cloudxr_manager.lua"
        } else {
            Log "ICE + STUN configuration already present in cloudxr_manager.lua"
        }
    } else {
        Log "WARNING: cloudxr_manager.lua not found at $luaPath"
    }

    # Lock GPU clocks (for g7e/Blackwell instances with lightweight workloads)
    nvidia-smi -lgc 2000,2520 2>$null
    Log "GPU clocks locked (if supported)"

    # Determine device profile and signaling port
    if ($poolTag -eq "native") {
        $deviceProfile = "auto-native"
        $signalingPort = 48010
    } else {
        $deviceProfile = "auto-webrtc"
        $signalingPort = 49100
    }
    Log "Device profile: $deviceProfile, Signaling port: $signalingPort"

    # Start LOVR with CloudXR (headless — no display window needed on cloud instances)
    $lovrExe = "C:\lovr\build\Debug\lovr.exe"
    if (Test-Path $lovrExe) {
        Start-Process -FilePath $lovrExe -ArgumentList "C:\lovr\plugins\nvidia\examples\cloudxr --device-profile=$deviceProfile --headless" -WorkingDirectory "C:\lovr\build\Debug"
        Log "lovr.exe started with --device-profile=$deviceProfile --headless"
    } else {
        Log "WARNING: lovr.exe not found"
    }

    # Register in DynamoDB.
    # Optional by design: the instance registry only exists in the full architecture. The
    # MVP topology has no table and its instance role has no DynamoDB permissions, so a
    # failure here must not fail startup — the runtime is already running and serving.
    try {
        $dynamoTable = "CloudXRInstances"
        $attrS = { param($val) $a = New-Object Amazon.DynamoDBv2.Model.AttributeValue; $a.S = $val; $a }
        $attrN = { param($val) $a = New-Object Amazon.DynamoDBv2.Model.AttributeValue; $a.N = $val; $a }

        $item = New-Object 'System.Collections.Generic.Dictionary[String,Amazon.DynamoDBv2.Model.AttributeValue]'
        $item.Add("instanceId", (& $attrS $instanceId))
        $item.Add("status", (& $attrS "available"))
        $item.Add("pool", (& $attrS $poolTag))
        $item.Add("privateIp", (& $attrS $privateIp))
        $item.Add("publicIp", (& $attrS $publicIp))
        $item.Add("signalingPort", (& $attrN "$signalingPort"))
        $item.Add("lastUpdated", (& $attrS (Get-Date -Format "o")))

        $ddbClient = New-Object Amazon.DynamoDBv2.AmazonDynamoDBClient(
            (New-Object Amazon.Runtime.InstanceProfileAWSCredentials),
            [Amazon.RegionEndpoint]::GetBySystemName($regionMeta)
        )
        $putRequest = New-Object Amazon.DynamoDBv2.Model.PutItemRequest
        $putRequest.TableName = $dynamoTable
        $putRequest.Item = $item
        $ddbClient.PutItem($putRequest) | Out-Null
        Log "Registered in DynamoDB as available"
    } catch {
        Log "WARNING: DynamoDB registration failed - this instance will NOT be routable by the proxy."
        Log "  Expected in the MVP topology, which has no registry table."
        Log "  In the full architecture, check the GPU instance role's dynamodb:PutItem permission."
        Log "  Detail: $($_.Exception.Message.Split([Environment]::NewLine)[0])"
    }

    Log "Startup complete."
} catch {
    Log "ERROR: $($_.Exception.Message)"
    Log "STACK: $($_.ScriptStackTrace)"
    exit 1
}
