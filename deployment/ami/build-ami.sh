#!/bin/bash
set -euo pipefail

# CloudXR 6 on AWS — AMI Build Script
# Automates the MVP demo steps via SSM send-command.
# Each step is uploaded to S3 and executed on the instance.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config.env"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
log() { echo -e "${GREEN}[ami-build]${NC} $1"; }
warn() { echo -e "${YELLOW}[ami-build]${NC} $1"; }
error() { echo -e "${RED}[ami-build]${NC} $1" >&2; }

# Load config. Must behave identically to deploy.sh's parser — strips whole-line
# comments, inline trailing comments, and surrounding whitespace. If these two
# diverge, a config.env that deploys fine can fail here (or vice versa).
while IFS='=' read -r key value; do
    key="${key%%#*}"
    value="${value%%#*}"
    key=$(echo "$key" | tr -d '[:space:]')
    value=$(echo "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    if [[ -n "$key" ]]; then
        export "$key=$value"
    fi
done < <(grep -v '^[[:space:]]*#' "$CONFIG_FILE" | grep -v '^[[:space:]]*$')

# Derive region
if [[ "$GPU_ZONE" =~ ^([a-z]+-[a-z]+-[0-9]+)-[a-z]+-[0-9]+[a-z]?$ ]]; then
    REGION="${BASH_REMATCH[1]}"
elif [[ "$GPU_ZONE" =~ ^([a-z]+-[a-z]+-[0-9]+)[a-z]$ ]]; then
    REGION="${BASH_REMATCH[1]}"
else
    error "Cannot derive region from GPU_ZONE: $GPU_ZONE"
    exit 1
fi

log "Region: $REGION, Zone: $GPU_ZONE, Type: $GPU_TYPE"

# ============================================================================
# Compose the AMI name and description up front
# ============================================================================
# Deliberately computed before launching anything. CreateImage runs at the very end
# of a 40-50 minute build, so a malformed name or description discovered there costs
# the entire build. Validating here makes that class of failure cost seconds.
#
# AMIs are GPU-hardware-specific, so the name and description record the family and
# GPU count they were built on. Without that, AMIs built on different instance types
# are indistinguishable in the console.
GPU_FAMILY="${GPU_TYPE%%.*}"
GPU_COUNT=$(aws ec2 describe-instance-types --instance-types "$GPU_TYPE" --region "$REGION" \
    --query 'InstanceTypes[0].GpuInfo.Gpus[0].Count' --output text 2>/dev/null || echo "")
if [[ -z "$GPU_COUNT" || "$GPU_COUNT" == "None" ]]; then GPU_COUNT="unknown"; fi
AMI_NAME="cloudxr6-base-win2022-${GPU_FAMILY}-${GPU_COUNT}gpu-${REGION}-$(date +%Y%m%d-%H%M%S)"
AMI_DESC="CloudXR 6 Runtime base AMI - built on ${GPU_TYPE} (${GPU_FAMILY}, ${GPU_COUNT}x GPU) in ${GPU_ZONE}. GPU-hardware-specific: use only with matching instance types."

# CreateImage rejects non-ASCII in both Name and Description ("Character sets beyond
# ASCII are not supported"). Strip anything outside printable ASCII so an edit that
# reintroduces a character like an em dash cannot fail the build 40 minutes in.
ascii_only() { printf '%s' "$1" | LC_ALL=C tr -cd '\40-\176'; }
AMI_NAME=$(ascii_only "$AMI_NAME")
AMI_DESC=$(ascii_only "$AMI_DESC")

# AMI names must be 3-128 chars. CreateImage also allows ( ) [ ] / @ ' but this
# generator only ever emits letters, digits, dots, underscores and hyphens, so check
# against that narrower set - anything else means the generator was edited and should
# be reviewed. (Note: '-' is last and ']' is absent so the bracket expression is safe;
# inside POSIX brackets a backslash does not escape and ']' would close the class.)
if [[ "$AMI_NAME" =~ [^A-Za-z0-9._-] ]] || (( ${#AMI_NAME} < 3 || ${#AMI_NAME} > 128 )); then
    error "Generated AMI name is not valid for CreateImage: '$AMI_NAME'"
    exit 1
fi
log "  Planned AMI name: $AMI_NAME"

# S3 bucket for staging build scripts (auto-created if it doesn't exist)
ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
# Region-scoped: S3 bucket names are global, so an account-only name created in one
# region would be reused cross-region and every Read-S3Object would fail with
# PermanentRedirect.
S3_BUCKET="cloudxr-staging-${ACCOUNT_ID}-${REGION}"
aws s3 mb "s3://$S3_BUCKET" --region "$REGION" 2>/dev/null || true
log "Staging bucket: $S3_BUCKET"

# Helper: run a PowerShell script on the instance via S3
run_step() {
    local instance_id="$1"
    local step_name="$2"
    local script_file="$3"
    local timeout="${4:-600}"

    log "  Running: $step_name"

    # Upload script to S3
    aws s3 cp "$script_file" "s3://$S3_BUCKET/build-steps/$(basename $script_file)" --region "$REGION" > /dev/null

    # Execute via SSM: download from S3 and run
    local cmd_id
    cmd_id=$(aws ssm send-command \
        --instance-ids "$instance_id" \
        --document-name AWS-RunPowerShellScript \
        --parameters "{\"commands\":[\"Read-S3Object -BucketName $S3_BUCKET -Key build-steps/$(basename $script_file) -File C:\\\\build-step.ps1 -Region $REGION\",\"powershell.exe -ExecutionPolicy Bypass -File C:\\\\build-step.ps1\"]}" \
        --region "$REGION" \
        --timeout-seconds "$timeout" \
        --query 'Command.CommandId' --output text)

    # Wait for completion
    local status="InProgress"
    local elapsed=0
    while [[ "$status" == "InProgress" || "$status" == "Pending" || "$status" == "Delayed" ]]; do
        sleep 15
        elapsed=$((elapsed + 15))
        status=$(aws ssm get-command-invocation \
            --command-id "$cmd_id" \
            --instance-id "$instance_id" \
            --region "$REGION" \
            --query 'Status' --output text 2>/dev/null || echo "Pending")
        if [[ $elapsed -gt $((timeout + 60)) ]]; then
            error "  Timeout waiting for command"
            return 1
        fi
    done

    if [[ "$status" != "Success" ]]; then
        error "  FAILED ($status)"
        aws ssm get-command-invocation \
            --command-id "$cmd_id" \
            --instance-id "$instance_id" \
            --region "$REGION" \
            --query 'StandardErrorContent' --output text 2>/dev/null
        return 1
    fi

    # Print last few lines of output
    aws ssm get-command-invocation \
        --command-id "$cmd_id" \
        --instance-id "$instance_id" \
        --region "$REGION" \
        --query 'StandardOutputContent' --output text 2>/dev/null | tail -5

    log "  Done: $step_name"
}

# Wait for SSM to be online
wait_ssm() {
    local instance_id="$1"
    log "  Waiting for SSM..."
    local count=0
    while true; do
        local ping
        # `|| echo` is required: under `set -e` a failing command substitution aborts
        # the script, and the EXIT trap would then discard a 40-minute build over a
        # transient throttle.
        ping=$(aws ssm describe-instance-information \
            --filters "Key=InstanceIds,Values=$instance_id" \
            --region "$REGION" \
            --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo "Pending")
        if [[ "$ping" == "Online" ]]; then
            log "  SSM online"
            sleep 10  # Extra buffer for PowerShell to be ready
            return 0
        fi
        count=$((count + 1))
        if [[ $count -gt 40 ]]; then
            error "  SSM timeout"
            return 1
        fi
        sleep 15
    done
}

# ============================================================================
# Launch build instance
# ============================================================================
log "Launching build instance ($GPU_TYPE in $GPU_ZONE)..."

BASE_AMI=$(aws ec2 describe-images \
    --owners amazon \
    --filters "Name=name,Values=Windows_Server-2022-English-Full-Base-*" \
              "Name=state,Values=available" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --region "$REGION" --output text)
log "  Base AMI: $BASE_AMI"

# The build instance always uses this dedicated profile — never the deployed fleet's
# GpuInstanceProfile. That role is scoped for a running instance (SSM, DescribeTags,
# PutItem) and intentionally has no S3 read, so the driver download in
# 01-install-driver.ps1 would fail with it.
setup_build_instance_profile() {
    # Create a temporary IAM role + instance profile for the build instance
    TEMP_ROLE_NAME="cloudxr-ami-build-temp-role"
    TEMP_PROFILE_NAME="cloudxr-ami-build-temp-profile"

    # Create role (ignore if exists)
    aws iam create-role --role-name "$TEMP_ROLE_NAME" \
        --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
        2>/dev/null || true
    aws iam attach-role-policy --role-name "$TEMP_ROLE_NAME" \
        --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" 2>/dev/null || true
    aws iam attach-role-policy --role-name "$TEMP_ROLE_NAME" \
        --policy-arn "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess" 2>/dev/null || true
    aws iam attach-role-policy --role-name "$TEMP_ROLE_NAME" \
        --policy-arn "arn:aws:iam::aws:policy/AmazonEC2ReadOnlyAccess" 2>/dev/null || true

    # Create instance profile (ignore if exists)
    aws iam create-instance-profile --instance-profile-name "$TEMP_PROFILE_NAME" 2>/dev/null || true
    aws iam add-role-to-instance-profile --instance-profile-name "$TEMP_PROFILE_NAME" \
        --role-name "$TEMP_ROLE_NAME" 2>/dev/null || true
    INSTANCE_PROFILE="$TEMP_PROFILE_NAME"

    # Wait for instance profile to propagate (IAM is eventually consistent)
    # Must verify the role is actually attached before launching
    log "  Waiting for IAM instance profile to propagate..."
    for i in $(seq 1 12); do
        ROLE_COUNT=$(aws iam get-instance-profile --instance-profile-name "$TEMP_PROFILE_NAME" \
            --query 'InstanceProfile.Roles | length(@)' --output text 2>/dev/null || echo "0")
        if [[ "$ROLE_COUNT" -gt 0 ]]; then
            log "  IAM role attached to instance profile (confirmed)"
            break
        fi
        sleep 10
    done
    # Extra buffer for cross-service propagation (EC2 caches IAM)
    sleep 15
}

# Try to get infrastructure from existing CloudFormation stack (if it exists)
# If the stack doesn't exist yet, create temporary build infrastructure
STACK_EXISTS=false
GPU_SUBNET=$(aws cloudformation describe-stacks \
    --stack-name cloudxr-infrastructure --region "$REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`GpuSubnetId`].OutputValue' --output text 2>/dev/null) || true
if [[ -n "$GPU_SUBNET" && "$GPU_SUBNET" != "None" ]]; then
    STACK_EXISTS=true
    GPU_SG=$(aws cloudformation describe-stacks \
        --stack-name cloudxr-infrastructure --region "$REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`GpuSecurityGroupId`].OutputValue' --output text)
    setup_build_instance_profile
    log "  Using existing stack infrastructure (subnet: $GPU_SUBNET)"
else
    log "  CloudFormation stack not found. Creating temporary build infrastructure..."

    # Use default VPC
    VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" \
        --region "$REGION" --query 'Vpcs[0].VpcId' --output text)
    if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
        error "No default VPC found in $REGION."
        error "This script builds in the default VPC when the cloudxr-infrastructure stack"
        error "does not exist yet. Create one with:"
        error "  aws ec2 create-default-vpc --region $REGION"
        exit 1
    fi

    # Check if a usable GPU_ZONE subnet already exists in the default VPC, or create one.
    # The subnet must auto-assign public IPs — the build instance needs internet access to
    # reach SSM. A subnet in the right zone with MapPublicIpOnLaunch=false would leave the
    # instance unreachable and the build would hang waiting for SSM.
    GPU_SUBNET=$(aws ec2 describe-subnets --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=availability-zone,Values=$GPU_ZONE" \
                  "Name=map-public-ip-on-launch,Values=true" \
        --query 'Subnets[0].SubnetId' --output text 2>/dev/null)
    if [[ -z "$GPU_SUBNET" || "$GPU_SUBNET" == "None" ]]; then
        # Find a free /24 within the VPC's CIDR. Default VPCs use 172.31.0.0/16 with /20
        # subnets, so the .200+ range is normally free — but don't assume it. create-subnet
        # rejects overlaps, so try candidates until one succeeds.
        VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --region "$REGION" \
            --query 'Vpcs[0].CidrBlock' --output text)
        VPC_PREFIX=$(echo "$VPC_CIDR" | cut -d. -f1,2)
        GPU_SUBNET=""
        for OCTET in $(seq 200 254); do
            CANDIDATE="${VPC_PREFIX}.${OCTET}.0/24"
            GPU_SUBNET=$(aws ec2 create-subnet --vpc-id "$VPC_ID" \
                --cidr-block "$CANDIDATE" --availability-zone "$GPU_ZONE" \
                --region "$REGION" --query 'Subnet.SubnetId' --output text 2>/dev/null) || GPU_SUBNET=""
            if [[ -n "$GPU_SUBNET" && "$GPU_SUBNET" != "None" ]]; then break; fi
        done
        if [[ -z "$GPU_SUBNET" || "$GPU_SUBNET" == "None" ]]; then
            error "Could not create a subnet in $GPU_ZONE — no free /24 found in $VPC_CIDR."
            exit 1
        fi
        aws ec2 modify-subnet-attribute --subnet-id "$GPU_SUBNET" \
            --map-public-ip-on-launch --region "$REGION"
        log "  Created subnet: $GPU_SUBNET ($CANDIDATE) in $GPU_ZONE"
        TEMP_SUBNET="$GPU_SUBNET"
    fi

    # Create a temporary security group (allow SSM outbound only)
    GPU_SG=$(aws ec2 create-security-group --group-name "cloudxr-ami-build-temp" \
        --description "Temporary SG for CloudXR AMI build" \
        --vpc-id "$VPC_ID" --region "$REGION" --query 'GroupId' --output text 2>/dev/null) || \
        GPU_SG=$(aws ec2 describe-security-groups --region "$REGION" \
            --filters "Name=group-name,Values=cloudxr-ami-build-temp" "Name=vpc-id,Values=$VPC_ID" \
            --query 'SecurityGroups[0].GroupId' --output text)
    TEMP_SG="$GPU_SG"
    log "  Security group: $GPU_SG"
    setup_build_instance_profile

fi

# Tagged Pool=build, NOT webrtc: deploy.sh selects its harvest source on tag:Pool=webrtc,
# so a builder running in the same VPC could otherwise be harvested from mid-build.
# Keep comments outside the command: a comment between backslash-continued lines ends the
# logical line, turning the remaining arguments into a separate command. `bash -n` does not
# catch it, and it would launch an untagged instance and then abort before the EXIT trap
# below is armed, leaking a running GPU instance.
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$BASE_AMI" \
    --instance-type "$GPU_TYPE" \
    --subnet-id "$GPU_SUBNET" \
    --security-group-ids "$GPU_SG" \
    --iam-instance-profile "Name=$INSTANCE_PROFILE" \
    --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=200,VolumeType=gp3,DeleteOnTermination=true}' \
    --metadata-options 'HttpEndpoint=enabled,HttpTokens=required,HttpPutResponseHopLimit=2' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=CloudXR-AMI-Builder},{Key=Pool,Value=build}]" \
    --region "$REGION" \
    --query 'Instances[0].InstanceId' --output text)

log "  Instance: $INSTANCE_ID"

# Safety net: terminate the build instance if the script exits early (error or
# interrupt). Without this, a failure after launch leaves a GPU instance billing.
# The success path terminates explicitly and clears INSTANCE_ID, disarming this.
cleanup_build_instance() {
    if [[ -n "${INSTANCE_ID:-}" ]]; then
        aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION" > /dev/null 2>&1 || true
    fi
}
trap cleanup_build_instance EXIT

aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"
wait_ssm "$INSTANCE_ID"

# ============================================================================
# Run build steps
# ============================================================================
run_step "$INSTANCE_ID" "Install NVIDIA driver" "$SCRIPT_DIR/scripts/01-install-driver.ps1" 600

log "  Rebooting after driver install..."
aws ssm send-command --instance-ids "$INSTANCE_ID" --document-name AWS-RunPowerShellScript \
    --parameters '{"commands":["Restart-Computer -Force"]}' --region "$REGION" > /dev/null 2>&1
sleep 60
wait_ssm "$INSTANCE_ID"

run_step "$INSTANCE_ID" "Configure OS" "$SCRIPT_DIR/scripts/02-configure-os.ps1" 300

log "  Rebooting after OS config..."
aws ssm send-command --instance-ids "$INSTANCE_ID" --document-name AWS-RunPowerShellScript \
    --parameters '{"commands":["Restart-Computer -Force"]}' --region "$REGION" > /dev/null 2>&1
sleep 60
wait_ssm "$INSTANCE_ID"

# Timeouts are generous on purpose. Measured on a 32-vCPU g7e.8xlarge, the build-tools
# step took ~12 min and the LOVR build ~5 min - but both scale with vCPU count, so on a
# smaller instance (e.g. g7e.2xlarge, 8 vCPU) a 15-min budget can be exceeded. A timeout
# here returns 1, and under `set -e` that aborts the run and the EXIT trap discards the
# whole build, so erring high costs nothing while erring low costs ~40 minutes.
run_step "$INSTANCE_ID" "Install build tools" "$SCRIPT_DIR/scripts/03-install-build-tools.ps1" 2400

run_step "$INSTANCE_ID" "Build LOVR sample" "$SCRIPT_DIR/scripts/04-install-app.ps1" 2400

run_step "$INSTANCE_ID" "Configure CloudXR" "$SCRIPT_DIR/scripts/05-configure-cloudxr.ps1" 120

# Upload the standalone startup script to S3 (06-install-startup.ps1 downloads it)
log "  Uploading startup.ps1 to S3..."
aws s3 cp "$SCRIPT_DIR/scripts/startup.ps1" "s3://$S3_BUCKET/build-steps/startup.ps1" --region "$REGION" > /dev/null

# Write the staging bucket name to the instance so 06-install-startup.ps1 knows where to download from
aws ssm send-command --instance-ids "$INSTANCE_ID" --document-name AWS-RunPowerShellScript \
    --parameters "{\"commands\":[\"Set-Content -Path C:\\\\cloudxr-staging-bucket.txt -Value '$S3_BUCKET'\"]}" \
    --region "$REGION" --timeout-seconds 30 > /dev/null 2>&1
sleep 5

run_step "$INSTANCE_ID" "Install startup script" "$SCRIPT_DIR/scripts/06-install-startup.ps1" 120

# Configure EC2Launch to NOT reset admin password on next boot (preserves auto-logon)
# NOTE: We do NOT run "ec2launch reset" — it wipes user-installed content.
# We only modify the config file to set password handling to doNothing.
log "  Configuring EC2Launch agent-config.yml (no reset)..."
aws ssm send-command --instance-ids "$INSTANCE_ID" --document-name AWS-RunPowerShellScript \
    --parameters '{"commands":["$configPath = \"C:\\ProgramData\\Amazon\\EC2Launch\\config\\agent-config.yml\"","$config = Get-Content $configPath -Raw","$config = $config -replace \"type: random\",\"type: doNothing\"","Set-Content -Path $configPath -Value $config","Write-Host agent-config.yml updated: password type set to doNothing (no reset run)"]}' \
    --region "$REGION" --timeout-seconds 60 --query 'Command.CommandId' --output text > /dev/null 2>&1
sleep 20

# Verify it actually applied. If EC2Launch keeps resetting the Administrator password,
# auto-logon fails, no interactive session exists, the CloudXR-Startup task never fires,
# and every instance from this AMI boots idle and never registers. Too important to
# leave unchecked.
EC2L_CHECK=$(aws ssm send-command --instance-ids "$INSTANCE_ID" --document-name AWS-RunPowerShellScript \
    --parameters '{"commands":["$c = Get-Content C:\\ProgramData\\Amazon\\EC2Launch\\config\\agent-config.yml -Raw","if ($c -match \"type: doNothing\") { Write-Host OK } else { Write-Host NOTAPPLIED }"]}' \
    --region "$REGION" --timeout-seconds 60 --query 'Command.CommandId' --output text 2>/dev/null || echo "")
if [[ -z "$EC2L_CHECK" ]]; then
    # Don't skip silently. Not being able to run the check is not the same as passing it,
    # and this gate guards the mechanism the entire boot chain depends on.
    error "Could not issue the EC2Launch verification command over SSM."
    error "Refusing to bake an AMI whose password-reset behaviour is unverified. Aborting."
    exit 1
fi

# Poll to a terminal state instead of sleeping a fixed interval. StandardOutputContent is
# empty while a command is still InProgress, which would read as a failed check and abort
# a 40-minute build for a timing reason rather than a real fault.
EC2L_STATUS="Pending"
EC2L_WAIT=0
while [[ "$EC2L_STATUS" == "Pending" || "$EC2L_STATUS" == "InProgress" || "$EC2L_STATUS" == "Delayed" ]] \
      && (( EC2L_WAIT < 180 )); do
    sleep 6
    EC2L_WAIT=$((EC2L_WAIT + 6))
    EC2L_STATUS=$(aws ssm get-command-invocation --command-id "$EC2L_CHECK" --instance-id "$INSTANCE_ID" \
        --region "$REGION" --query 'Status' --output text 2>/dev/null || echo "Pending")
done
EC2L_RESULT=$(aws ssm get-command-invocation --command-id "$EC2L_CHECK" --instance-id "$INSTANCE_ID" \
    --region "$REGION" --query 'StandardOutputContent' --output text 2>/dev/null || echo "")
if [[ "$EC2L_RESULT" == *OK* ]]; then
    log "  EC2Launch password reset disabled (verified)"
else
    error "EC2Launch agent-config.yml was NOT patched (no 'type: doNothing' found)."
    error "  SSM command status: $EC2L_STATUS (after ${EC2L_WAIT}s)"
    error "  SSM command output: ${EC2L_RESULT:-<empty>}"
    error "Instances from this AMI would have their Administrator password reset on boot,"
    error "breaking auto-logon and therefore the CloudXR startup task. Aborting."
    exit 1
fi

# Set up Startup folder bat as a fallback (scheduled task is primary launch mechanism)
# Only create this as a safety net — the scheduled task in 06-install-startup.ps1 is the primary launcher
log "  Creating Startup folder fallback script..."
aws ssm send-command --instance-ids "$INSTANCE_ID" --document-name AWS-RunPowerShellScript \
    --parameters '{"commands":["$startupDir = \"C:\\Users\\Administrator\\AppData\\Roaming\\Microsoft\\Windows\\Start Menu\\Programs\\Startup\"","$lines = @(\"@echo off\",\"REM Fallback launcher - primary is CloudXR-Startup scheduled task\",\"if not exist C:\\cxr-logs\\startup.log (\",\"  powershell.exe -ExecutionPolicy Bypass -File C:\\cloudxr-config\\startup.ps1\",\")\")","$lines | Out-File -FilePath \"$startupDir\\cloudxr-startup.bat\" -Encoding ascii","Write-Host Startup fallback bat created"]}' \
    --region "$REGION" --timeout-seconds 60 --query 'Command.CommandId' --output text > /dev/null 2>&1
sleep 30

# ============================================================================
# Create AMI
# ============================================================================
log "Stopping instance..."
aws ec2 stop-instances --instance-ids "$INSTANCE_ID" --region "$REGION" > /dev/null
aws ec2 wait instance-stopped --instance-ids "$INSTANCE_ID" --region "$REGION"

log "Creating AMI..."
log "  Name: $AMI_NAME"
AMI_ID=$(aws ec2 create-image \
    --instance-id "$INSTANCE_ID" \
    --name "$AMI_NAME" \
    --description "$AMI_DESC" \
    --region "$REGION" \
    --query 'ImageId' --output text)

aws ec2 create-tags --resources "$AMI_ID" --region "$REGION" \
    --tags "Key=Name,Value=$AMI_NAME" "Key=GpuType,Value=$GPU_TYPE" > /dev/null 2>&1 || true

# Poll for availability rather than using `aws ec2 wait image-available`, whose default
# timeout (~10 min) is far shorter than a 200GB Windows snapshot needs. A timed-out waiter
# under `set -e` would abort the script even though the build succeeded.
log "  AMI: $AMI_ID (waiting for availability — a 200GB Windows AMI can take 20-40 min)..."
AMI_STATE="pending"
WAIT_ELAPSED=0
while [[ "$AMI_STATE" == "pending" && $WAIT_ELAPSED -lt 3600 ]]; do
    sleep 30
    WAIT_ELAPSED=$((WAIT_ELAPSED + 30))
    AMI_STATE=$(aws ec2 describe-images --image-ids "$AMI_ID" --region "$REGION" \
        --query 'Images[0].State' --output text 2>/dev/null || echo "pending")
    if (( WAIT_ELAPSED % 300 == 0 )); then
        log "    still $AMI_STATE ($((WAIT_ELAPSED / 60)) min elapsed)"
    fi
done

if [[ "$AMI_STATE" == "failed" || "$AMI_STATE" == "error" ]]; then
    error "AMI registration FAILED (state: $AMI_STATE). This AMI is not usable."
    error "Inspect it with: aws ec2 describe-images --image-ids $AMI_ID --region $REGION"
    error "Do not put $AMI_ID into config.env."
    exit 1
elif [[ "$AMI_STATE" != "available" ]]; then
    warn "AMI has not reached 'available' after $((WAIT_ELAPSED / 60)) min (state: $AMI_STATE)."
    warn "The snapshot is likely still completing — the build itself succeeded."
    warn "Check with: aws ec2 describe-images --image-ids $AMI_ID --region $REGION"
fi

# Terminate the build instance and wait for it to fully release its ENI.
# This must happen before deleting the temp subnet/security group: a stopped
# instance still holds an ENI in the subnet and a membership in the SG, so
# deleting either first fails with DependencyViolation.
log "Terminating build instance..."
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION" > /dev/null
aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" --region "$REGION" 2>/dev/null || true
INSTANCE_ID=""   # disarm the EXIT trap — the instance is already gone

# Clean up temporary build infrastructure (if we created it)
if [[ "$STACK_EXISTS" == false ]]; then
    log "Cleaning up temporary build infrastructure..."
    # ENI detachment can lag slightly behind instance termination, so retry.
    if [[ -n "${TEMP_SG:-}" ]]; then
        for _ in 1 2 3 4 5 6; do
            aws ec2 delete-security-group --group-id "$TEMP_SG" --region "$REGION" > /dev/null 2>&1 && break
            sleep 10
        done
    fi
    if [[ -n "${TEMP_SUBNET:-}" ]]; then
        for _ in 1 2 3 4 5 6; do
            aws ec2 delete-subnet --subnet-id "$TEMP_SUBNET" --region "$REGION" > /dev/null 2>&1 && break
            sleep 10
        done
    fi
    # Leave the IAM role/profile — they're reusable and zero-cost
fi

log "============================================"
log "  AMI BUILD COMPLETE"
log "  AMI ID: $AMI_ID"
log "============================================"
log ""
log "  Update config.env:"
log "    AMI_ID=$AMI_ID"
