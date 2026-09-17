#!/bin/bash
set -euo pipefail

# CloudXR 6 on AWS — Deployment Script
# Reads config.env, deploys CloudFormation stack, uploads web client, creates test user.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"
STACK_NAME="cloudxr-infrastructure"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[deploy]${NC} $1"; }
warn() { echo -e "${YELLOW}[deploy]${NC} $1"; }
error() { echo -e "${RED}[deploy]${NC} $1" >&2; }

# ============================================================================
# Parse arguments
# ============================================================================
DELETE_MODE=false
if [[ "${1:-}" == "--delete" ]]; then
    DELETE_MODE=true
fi

# ============================================================================
# Load and validate config
# ============================================================================
if [[ ! -f "$CONFIG_FILE" ]]; then
    error "config.env not found at $CONFIG_FILE"
    exit 1
fi

# Source config. Strips whole-line comments, inline trailing comments, and
# surrounding whitespace, so both "KEY=value" and "KEY=value  # note" work.
while IFS='=' read -r key value; do
    key="${key%%#*}"
    value="${value%%#*}"
    key=$(echo "$key" | tr -d '[:space:]')
    value=$(echo "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    if [[ -n "$key" ]]; then
        export "$key=$value"
    fi
done < <(grep -v '^[[:space:]]*#' "$CONFIG_FILE" | grep -v '^[[:space:]]*$')

# Derive region from GPU_ZONE
# us-west-2-lax-1b → us-west-2 (Local Zone)
# us-west-2a → us-west-2 (standard AZ)
derive_region() {
    local zone="$1"
    # If it contains more than one hyphen-separated segment after the region (Local Zone pattern)
    # e.g., us-west-2-lax-1b → strip -lax-1b
    # Standard AZ: us-west-2a → strip trailing letter
    if [[ "$zone" =~ ^([a-z]+-[a-z]+-[0-9]+)-[a-z]+-[0-9]+[a-z]?$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "$zone" =~ ^([a-z]+-[a-z]+-[0-9]+)[a-z]$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        error "Cannot derive region from GPU_ZONE: $zone"
        exit 1
    fi
}

# Validate before deriving, otherwise `set -u` reports "GPU_ZONE: unbound variable"
# instead of the actionable message below.
if [[ -z "${GPU_ZONE:-}" ]]; then
    error "Required config value missing: GPU_ZONE"
    error "Please fill out all required values in config.env"
    exit 1
fi

REGION=$(derive_region "$GPU_ZONE")
log "Derived region: $REGION (from GPU_ZONE: $GPU_ZONE)"

# ============================================================================
# Delete mode
# ============================================================================
if [[ "$DELETE_MODE" == true ]]; then
    log "Deleting CloudXR infrastructure..."
    warn "Note: CloudFront teardown takes 15-30 minutes for global edge propagation."

    # Step 1: Scale down ASG (GPU instances) to 0
    log "  Scaling ASG to 0..."
    for asg_name in $(aws autoscaling describe-auto-scaling-groups --region "$REGION" \
        --query "AutoScalingGroups[?contains(Tags[?Key=='aws:cloudformation:stack-name'].Value, '$STACK_NAME')].AutoScalingGroupName" --output text 2>/dev/null); do
        aws autoscaling update-auto-scaling-group --auto-scaling-group-name "$asg_name" \
            --min-size 0 --desired-capacity 0 --region "$REGION" 2>/dev/null || true
    done

    # Step 2: Scale down ECS service to 0
    log "  Scaling ECS service to 0..."
    aws ecs update-service --cluster cloudxr-cluster --service cloudxr-proxy \
        --desired-count 0 --region "$REGION" --output text > /dev/null 2>&1 || true

    # Step 3: Wait for instances and tasks to terminate
    log "  Waiting for ECS tasks to drain..."
    aws ecs wait services-stable --cluster cloudxr-cluster --services cloudxr-proxy \
        --region "$REGION" 2>/dev/null || true

    # Step 4: Wait for GPU instances to actually terminate, then for ENIs to release.
    # A flat sleep is not enough: the target group's deregistration delay gates Fargate
    # ENI release, and a Local Zone Windows instance takes minutes to terminate.
    ASG_INSTANCES=$(aws ec2 describe-instances --region "$REGION" \
        --filters "Name=tag:aws:cloudformation:stack-name,Values=$STACK_NAME" \
                  "Name=instance-state-name,Values=running,stopping,shutting-down" \
        --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || echo "")
    if [[ -n "$ASG_INSTANCES" ]]; then
        log "  Waiting for GPU instances to terminate: $ASG_INSTANCES"
        aws ec2 wait instance-terminated --instance-ids $ASG_INSTANCES --region "$REGION" 2>/dev/null || true
    fi

    log "  Waiting for network interfaces to release..."
    for _ in $(seq 1 24); do
        ENI_COUNT=$(aws ec2 describe-network-interfaces --region "$REGION" \
            --filters "Name=group-name,Values=cloudxr-*" \
            --query 'length(NetworkInterfaces)' --output text 2>/dev/null || echo "0")
        [[ "$ENI_COUNT" == "0" ]] && break
        sleep 10
    done

    # Step 5: Empty S3 web client bucket (CloudFormation can't delete non-empty buckets)
    # Read the real bucket name from the stack — do not reconstruct it, or a naming
    # change silently skips the empty step and the stack delete then fails.
    WEB_BUCKET=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
        --query "Stacks[0].Outputs[?OutputKey=='WebClientBucketName'].OutputValue" \
        --output text 2>/dev/null || echo "")
    if [[ -n "$WEB_BUCKET" && "$WEB_BUCKET" != "None" ]]; then
        log "  Emptying S3 bucket: $WEB_BUCKET"
        aws s3 rm "s3://$WEB_BUCKET" --recursive --region "$REGION" > /dev/null 2>&1 || \
            warn "  Could not fully empty $WEB_BUCKET — stack deletion may fail on it."
    else
        warn "  Could not resolve the web client bucket from stack outputs; skipping empty step."
    fi

    # Step 6: Delete CloudFormation stack
    log "  Deleting CloudFormation stack: $STACK_NAME"
    aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"

    # Step 7: Poll for completion (up to 45 minutes for CloudFront)
    log "  Waiting for stack deletion (may take 15-30 min for CloudFront)..."
    ELAPSED=0
    MAX_WAIT=2700  # 45 minutes
    while [[ $ELAPSED -lt $MAX_WAIT ]]; do
        STATUS=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
            --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "GONE")
        if [[ "$STATUS" == "GONE" || "$STATUS" == "DELETE_COMPLETE" ]]; then
            log "  Stack deleted successfully."
            exit 0
        elif [[ "$STATUS" == "DELETE_FAILED" ]]; then
            warn "  Stack deletion failed. Retrying with retained resources..."
            # Get failed resources (accumulate across retries)
            # Read CURRENT resource state, not cumulative event history — retrying with a
            # logical ID that already deleted is a ValidationError, and an unguarded call
            # would abort teardown with the ALB and distribution still billing.
            FAILED=$(aws cloudformation describe-stack-resources --stack-name "$STACK_NAME" --region "$REGION" \
                --query "StackResources[?ResourceStatus=='DELETE_FAILED'].LogicalResourceId" --output text 2>/dev/null \
                | tr '\t' '\n' | sort -u | tr '\n' ' ')
            if [[ -n "${FAILED// /}" ]]; then
                log "  Retaining: $FAILED"
                aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION" \
                    --retain-resources $FAILED 2>/dev/null || \
                    warn "  Retry with retained resources was rejected; continuing to poll."
                sleep 30
                # Continue polling (don't break — cascading failures may need multiple retries)
            else
                warn "  No specific failed resources identified. Manual cleanup may be needed."
                break
            fi
        fi
        sleep 30
        ELAPSED=$((ELAPSED + 30))
        if [[ $((ELAPSED % 120)) -eq 0 ]]; then
            log "  Still waiting... ($((ELAPSED / 60)) min elapsed, status: $STATUS)"
        fi
    done

    # Step 8: Try to clean up retained resources (SGs, subnets, VPC)
    RETAINED_SGS=$(aws ec2 describe-security-groups --region "$REGION" \
        --filters "Name=tag:aws:cloudformation:stack-name,Values=$STACK_NAME" \
        --query 'SecurityGroups[].GroupId' --output text 2>/dev/null)
    if [[ -n "$RETAINED_SGS" ]]; then
        log "  Cleaning up retained security groups..."
        for sg in $RETAINED_SGS; do
            for i in $(seq 1 10); do
                aws ec2 delete-security-group --group-id "$sg" --region "$REGION" 2>/dev/null && break
                sleep 15
            done
        done
    fi

    # Try to delete retained subnets and VPC
    RETAINED_SUBNETS=$(aws ec2 describe-subnets --region "$REGION" \
        --filters "Name=tag:aws:cloudformation:stack-name,Values=$STACK_NAME" \
        --query 'Subnets[].SubnetId' --output text 2>/dev/null)
    for subnet in $RETAINED_SUBNETS; do
        aws ec2 delete-subnet --subnet-id "$subnet" --region "$REGION" 2>/dev/null || true
    done

    RETAINED_VPCS=$(aws ec2 describe-vpcs --region "$REGION" \
        --filters "Name=tag:aws:cloudformation:stack-name,Values=$STACK_NAME" \
        --query 'Vpcs[].VpcId' --output text 2>/dev/null)
    for vpc in $RETAINED_VPCS; do
        # Delete IGW attachment first
        IGW=$(aws ec2 describe-internet-gateways --region "$REGION" \
            --filters "Name=attachment.vpc-id,Values=$vpc" \
            --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null)
        if [[ -n "$IGW" && "$IGW" != "None" ]]; then
            aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$vpc" --region "$REGION" 2>/dev/null || true
            aws ec2 delete-internet-gateway --internet-gateway-id "$IGW" --region "$REGION" 2>/dev/null || true
        fi
        aws ec2 delete-vpc --vpc-id "$vpc" --region "$REGION" 2>/dev/null || true
    done

    # Final status check
    FINAL_STATUS=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
        --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "GONE")
    if [[ "$FINAL_STATUS" == "GONE" || "$FINAL_STATUS" == "DELETE_COMPLETE" ]]; then
        log "Cleanup complete."
    else
        warn "Some resources may remain. Check the AWS Console for stack '$STACK_NAME' in $REGION."
        warn "IMPORTANT: retained resources are usually free (security groups, subnets, VPC),"
        warn "but a failed teardown can also retain the load balancer and CloudFront"
        warn "distribution, which DO bill. Verify in the console before walking away."
    fi
    exit 0
fi

# ============================================================================
# Validate required config values
# ============================================================================
REQUIRED_VARS=("GPU_ZONE" "GPU_TYPE" "DOMAIN" "HOSTED_ZONE_ID" "CERT_ARN" "CERT_ARN_REGIONAL" "AMI_ID")
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        error "Required config value missing: $var"
        error "Please fill out all required values in config.env"
        exit 1
    fi
done

if [[ "$AMI_ID" == "" || "$AMI_ID" == "ami-" ]]; then
    error "AMI_ID is not set. Run './ami/build-ami.sh' first, then paste the AMI ID into config.env."
    exit 1
fi

log "Configuration validated:"
log "  GPU Zone:        $GPU_ZONE"
log "  GPU Type:        $GPU_TYPE"
log "  AMI:             $AMI_ID"
log "  Domain:          $DOMAIN"
log "  Origin host:     origin.$DOMAIN (CloudFront -> ALB, HTTPS)"
log "  Region:          $REGION"
log "  WebRTC Pool:     ${WEBRTC_POOL_SIZE:-1}"
log "  Native Pool:     ${NATIVE_POOL_SIZE:-0}"

# ============================================================================
# Deploy CloudFormation stack
# ============================================================================
# Look up CloudFront's origin-facing managed prefix list. The ALB security group is
# restricted to these ranges so clients cannot reach the ALB directly over plain HTTP
# and bypass CloudFront. The prefix list ID differs per region, hence the lookup.
# `|| true` matters: under `set -e` an assignment from a failing command substitution
# aborts the script, so without it the error below would be unreachable.
CLOUDFRONT_PREFIX_LIST=$(aws ec2 describe-managed-prefix-lists --region "$REGION" \
    --filters "Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing" \
    --query 'PrefixLists[0].PrefixListId' --output text 2>&1 || true)
if [[ "$CLOUDFRONT_PREFIX_LIST" == *"error"* || "$CLOUDFRONT_PREFIX_LIST" == *"Error"* ]]; then
    error "Prefix list lookup failed: $CLOUDFRONT_PREFIX_LIST"
    CLOUDFRONT_PREFIX_LIST=""
fi
if [[ -z "$CLOUDFRONT_PREFIX_LIST" || "$CLOUDFRONT_PREFIX_LIST" == "None" ]]; then
    error "Could not find the CloudFront origin-facing managed prefix list in $REGION."
    error "Check with: aws ec2 describe-managed-prefix-lists --region $REGION \\"
    error "  --filters Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing"
    exit 1
fi
log "  CloudFront prefix list: $CLOUDFRONT_PREFIX_LIST (ALB ingress restricted to CloudFront)"

# If GPU_ZONE is a Local Zone that is not opted in, GpuSubnet fails to create — but
# only AFTER CloudFormation has built the VPC, IGW and route tables, so the user waits
# through a rollback for an opaque error. Check first.
ZONE_OPTIN=$(aws ec2 describe-availability-zones --region "$REGION" --all-availability-zones \
    --filters "Name=zone-name,Values=$GPU_ZONE" \
    --query 'AvailabilityZones[0].OptInStatus' --output text 2>/dev/null || echo "")
if [[ "$ZONE_OPTIN" == "not-opted-in" ]]; then
    error "$GPU_ZONE is a Local Zone that your account has not opted into."
    error "Opt in, wait a few minutes, then re-run:"
    error "  aws ec2 modify-availability-zone-group --group-name ${GPU_ZONE%?} \\"
    error "    --opt-in-status opted-in --region $REGION"
    exit 1
elif [[ -z "$ZONE_OPTIN" || "$ZONE_OPTIN" == "None" ]]; then
    warn "Could not confirm $GPU_ZONE exists in $REGION — continuing, but a bad GPU_ZONE"
    warn "will fail at GpuSubnet creation after the VPC is already built."
else
    log "  Zone $GPU_ZONE: $ZONE_OPTIN"
fi

log "Deploying CloudFormation stack: $STACK_NAME"

aws cloudformation deploy \
    --template-file "$SCRIPT_DIR/cloudformation.yaml" \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides \
        GpuComputeZone="$GPU_ZONE" \
        GpuInstanceType="$GPU_TYPE" \
        GpuAmiId="$AMI_ID" \
        DomainName="$DOMAIN" \
        HostedZoneId="$HOSTED_ZONE_ID" \
        AcmCertificateArn="$CERT_ARN" \
        RegionalCertificateArn="$CERT_ARN_REGIONAL" \
        WebRTCPoolSize="${WEBRTC_POOL_SIZE:-1}" \
        NativePoolSize="${NATIVE_POOL_SIZE:-0}" \
        CloudFrontPrefixListId="$CLOUDFRONT_PREFIX_LIST" \
        ${PROXY_IMAGE:+ProxyImage="$PROXY_IMAGE"} \
    --no-fail-on-empty-changeset

log "Stack deployment complete."

# ============================================================================
# Get stack outputs
# ============================================================================
log "Retrieving stack outputs..."

get_output() {
    aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
        --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}

COGNITO_USER_POOL_ID=$(get_output "CognitoUserPoolId")
COGNITO_CLIENT_ID=$(get_output "CognitoAppClientId")
PROXY_URL=$(get_output "ProxyUrl")
WEB_BUCKET=$(get_output "WebClientBucketName")
CF_DIST_ID=$(get_output "CloudFrontDistributionId")
VPC_ID=$(get_output "VpcId")

log "  Cognito Pool:    $COGNITO_USER_POOL_ID"
log "  Cognito Client:  $COGNITO_CLIENT_ID"
log "  Proxy URL:       $PROXY_URL"
log "  Web Bucket:      $WEB_BUCKET"

# ============================================================================
# Upload web client to S3
# ============================================================================
# The web client consists of:
# - index.html: login page (authenticates, calls /api/session, redirects to React sample)
# - config.json: Cognito IDs (generated below)
# - cloudxr/: NVIDIA CloudXR.js React sample (harvested from GPU instance at deploy time)
#
# The React sample is built as part of the AMI (by LÖVR's build.bat) and copied
# directly from the running GPU instance to S3. After harvest, we patch its
# index.html with a script that auto-populates the connection parameter from the
# URL (proxyUrl) — enabling the login page to redirect seamlessly into the
# streaming client. Media is negotiated by ICE, so no media address is passed.
log "Writing web client config (Cognito IDs for login page)..."

cat > "$SCRIPT_DIR/proxy/public/config.json" <<EOF
{
  "region": "$REGION",
  "userPoolId": "$COGNITO_USER_POOL_ID",
  "clientId": "$COGNITO_CLIENT_ID",
  "apiEndpoint": "https://$DOMAIN"
}
EOF

log "Uploading login page + config to S3: $WEB_BUCKET"
aws s3 cp "$SCRIPT_DIR/proxy/public/index.html" "s3://$WEB_BUCKET/index.html" --region "$REGION" --content-type "text/html"
aws s3 cp "$SCRIPT_DIR/proxy/public/config.json" "s3://$WEB_BUCKET/config.json" --region "$REGION" --content-type "application/json"

# ============================================================================
# Harvest CloudXR.js React sample from GPU instance → S3
# ============================================================================
# The AMI build produces the React sample at a known path. We copy it directly
# from the GPU instance to the S3 web client bucket, then patch index.html.
# The harvest reads the React sample off a webrtc-pool instance. With
# WEBRTC_POOL_SIZE=0 there is nothing to harvest from, so skip rather than burn 15
# minutes waiting for an instance that will never appear.
if [[ "${WEBRTC_POOL_SIZE:-1}" == "0" ]]; then
    warn "WEBRTC_POOL_SIZE=0 — skipping React sample harvest (no webrtc instance to copy from)."
    warn "The CloudXR.js client at /cloudxr/ will not be populated."
    GPU_INSTANCE_ID=""
else
log "Waiting for GPU instance SSM to come online for React sample harvest..."
HARVEST_WAIT=0
GPU_INSTANCE_ID=""
while true; do
    GPU_INSTANCE_ID=$(aws ec2 describe-instances --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" \
                  "Name=instance-state-name,Values=running" \
                  "Name=tag:Pool,Values=webrtc" \
        --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || echo "")
    if [[ -n "$GPU_INSTANCE_ID" && "$GPU_INSTANCE_ID" != "None" ]]; then
        PING=$(aws ssm describe-instance-information \
            --filters "Key=InstanceIds,Values=$GPU_INSTANCE_ID" \
            --region "$REGION" \
            --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null)
        if [[ "$PING" == "Online" ]]; then
            break
        fi
    fi
    HARVEST_WAIT=$((HARVEST_WAIT + 1))
    if [[ $HARVEST_WAIT -gt 60 ]]; then
        warn "GPU instance SSM timeout. Skipping React sample harvest."
        warn "The CloudXR.js client at /cloudxr/ will not be available."
        GPU_INSTANCE_ID=""
        break
    fi
    sleep 15
done

if [[ -n "$GPU_INSTANCE_ID" && "$GPU_INSTANCE_ID" != "None" ]]; then
    log "  Harvesting CloudXR.js React sample from $GPU_INSTANCE_ID..."
    CMD_ID=$(aws ssm send-command \
        --instance-ids "$GPU_INSTANCE_ID" \
        --document-name AWS-RunPowerShellScript \
        --parameters "{\"commands\":[\"Write-S3Object -BucketName $WEB_BUCKET -KeyPrefix cloudxr/ -Folder 'C:\\\\lovr\\\\build\\\\cloudxr\\\\cloudxr-js-samples\\\\react\\\\build' -Recurse -Region $REGION\"]}" \
        --region "$REGION" \
        --timeout-seconds 120 \
        --query 'Command.CommandId' --output text)

    SSM_STATUS="InProgress"
    SSM_ELAPSED=0
    while [[ "$SSM_STATUS" == "InProgress" || "$SSM_STATUS" == "Pending" || "$SSM_STATUS" == "Delayed" ]]; do
        sleep 10
        SSM_ELAPSED=$((SSM_ELAPSED + 10))
        SSM_STATUS=$(aws ssm get-command-invocation \
            --command-id "$CMD_ID" \
            --instance-id "$GPU_INSTANCE_ID" \
            --region "$REGION" \
            --query 'Status' --output text 2>/dev/null || echo "Pending")
        if [[ $SSM_ELAPSED -gt 300 ]]; then
            warn "SSM harvest timeout."
            break
        fi
    done

    if [[ "$SSM_STATUS" == "Success" ]]; then
        log "  React sample harvested to s3://$WEB_BUCKET/cloudxr/"

        # Patch index.html with URL param auto-configuration script
        # The stock React sample doesn't read URL params. Our login page passes
        # proxyUrl via the redirect URL — this script injects it into the React
        # sample's input field on page load and selects VR immersive mode.
        # The media address/port fields are intentionally left blank so the
        # client negotiates the media path via ICE.
        log "  Patching cloudxr/index.html with URL param injection..."
        aws s3 cp "s3://$WEB_BUCKET/cloudxr/index.html" "/tmp/cloudxr-index-patch.html" --region "$REGION" > /dev/null 2>&1 || \
            warn "  Could not fetch cloudxr/index.html to patch; the client may not auto-configure."
        if [[ -f /tmp/cloudxr-index-patch.html ]]; then
        perl -i -pe 'BEGIN{$s=q{    <script>
    window.addEventListener("DOMContentLoaded", () => {
      const params = new URLSearchParams(window.location.search);
      const proxyUrl = params.get("proxyUrl");
      if (proxyUrl) { const el = document.getElementById("proxyUrl"); if (el) { el.value = proxyUrl; el.dispatchEvent(new Event("input")); el.dispatchEvent(new Event("change")); } }
      const immersive = document.getElementById("immersive"); if (immersive) { immersive.value = "vr"; immersive.dispatchEvent(new Event("change")); }
    });
    </script>
}} s|</body>|$s</body>|' /tmp/cloudxr-index-patch.html
        aws s3 cp "/tmp/cloudxr-index-patch.html" "s3://$WEB_BUCKET/cloudxr/index.html" --region "$REGION" --content-type "text/html" > /dev/null 2>&1 || \
            warn "  Could not upload the patched index.html."
        rm -f /tmp/cloudxr-index-patch.html
        log "  Patched cloudxr/index.html."
        fi
    else
        warn "  Harvest failed (status: $SSM_STATUS). The /cloudxr/ path may be empty."
    fi

    # Reboot the GPU instance after harvest to ensure a clean runtime state.
    # The SSM activity during harvest can leave lovr.exe in a partial state that
    # causes the first user connection to fail. Rebooting guarantees a fresh start.
    log "  Rebooting GPU instance for clean runtime state..."
    aws ssm send-command --instance-ids "$GPU_INSTANCE_ID" \
        --document-name AWS-RunPowerShellScript \
        --parameters '{"commands":["Restart-Computer -Force"]}' \
        --region "$REGION" --timeout-seconds 30 > /dev/null 2>&1
    log "  Reboot initiated. Instance will re-register in DynamoDB after startup (~7 min)."
fi
fi

# Invalidate CloudFront cache
log "Invalidating CloudFront cache..."
aws cloudfront create-invalidation --distribution-id "$CF_DIST_ID" --paths "/*" --output text > /dev/null 2>&1 || \
    warn "  CloudFront invalidation failed; cached files may be stale for up to 24h."

# ============================================================================
# Start ECS service
# ============================================================================
log "Starting ECS service (setting desired count to 2)..."
aws ecs update-service \
    --cluster cloudxr-cluster \
    --service cloudxr-proxy \
    --desired-count 2 \
    --region "$REGION" \
    --output text > /dev/null

log "Waiting for ECS service to stabilize..."
aws ecs wait services-stable \
    --cluster cloudxr-cluster \
    --services cloudxr-proxy \
    --region "$REGION"

# ============================================================================
# Create test user in Cognito
# ============================================================================
log "Creating test user in Cognito..."
# Demo credential for the login page. This value is published in this repo, and the
# login page is reachable from the internet through CloudFront - so change it before
# exposing a deployment to anyone. You can rotate it at any time without redeploying:
#   aws cognito-idp admin-set-user-password --user-pool-id <pool-id> \
#     --username demo --password '<new-password>' --permanent --region <region>
TEST_PASSWORD="CloudXR-Demo-2026!"

aws cognito-idp admin-create-user \
    --user-pool-id "$COGNITO_USER_POOL_ID" \
    --username demo \
    --temporary-password "$TEST_PASSWORD" \
    --message-action SUPPRESS \
    --region "$REGION" 2>/dev/null || warn "Test user 'demo' may already exist"

aws cognito-idp admin-set-user-password \
    --user-pool-id "$COGNITO_USER_POOL_ID" \
    --username demo \
    --password "$TEST_PASSWORD" \
    --permanent \
    --region "$REGION"

# ============================================================================
# Summary
# ============================================================================
echo ""
log "============================================"
log "  DEPLOYMENT COMPLETE"
log "============================================"
echo ""
log "  Proxy URL:       https://$DOMAIN"
log "  Test User:       demo"
log "  Test Password:   $TEST_PASSWORD"
log "  App Client ID:   $COGNITO_CLIENT_ID"
echo ""
warn "  This demo password is published in the repo. Rotate it before sharing this"
warn "  deployment, with: aws cognito-idp admin-set-user-password \\"
warn "    --user-pool-id $COGNITO_USER_POOL_ID --username demo \\"
warn "    --password '<new-password>' --permanent --region $REGION"
echo ""
log "  To connect from Quest 3:"
log "    1. Open browser → https://$DOMAIN"
log "    2. Login: demo / $TEST_PASSWORD"
log "    3. Press \"Connect to VR\""
echo ""

# Native clients use the same CloudFront endpoint, but the port has to be explicit: CloudXR
# Framework otherwise defaults to 48322, which CloudFront does not serve. Only worth printing
# when a native pool exists to serve them.
if [[ "${NATIVE_POOL_SIZE:-0}" -gt 0 ]]; then
    log "  To connect from Apple Vision Pro / iOS (native path):"
    log "    Proxy Host:    $DOMAIN:443   (the :443 is required — see avp-client-guide.md)"
    log "    Login:         demo / $TEST_PASSWORD"
    log "    Build a client: see deployment/avp-client-guide.md"
    echo ""
fi

log "  To tear down:"
log "    ./deploy.sh --delete"
echo ""
