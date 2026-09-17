#!/usr/bin/env bash
#
# Prepares NVIDIA's CloudXR Generic Viewer sample to talk to a CloudXR-on-AWS deployment.
#
# Clones the upstream sample at a pinned commit, applies cloudxr-aws.patch, and substitutes your
# deployment's signaling hostname. Nothing here is vendored — the sample is fetched from NVIDIA,
# matching how deploy.sh harvests the CloudXR.js sample rather than carrying a copy in this repo.
#
# Usage:
#   ./setup-avp-client.sh --domain cloudxr.example.com [--dest <path>]
#
#   --domain   Your deployment's domain, i.e. the DomainName parameter of the stack. The client
#              signals to <domain>:443 through CloudFront, which is the stack's
#              NativeSignalingHost output. The script appends the port for you — it must be
#              explicit, because CloudXR Framework otherwise defaults to port 48322, which
#              CloudFront does not serve.
#   --dest     Where to create the project. Defaults to ../../../cloudxr-apple-generic-viewer
#              relative to this script, i.e. a sibling of this repo. Deliberately outside the
#              repo so the working copy is never committed here.
#
# Afterwards, open the project in Xcode and build for a visionOS Simulator destination. See
# avp-client-guide.md for the full walkthrough, including the device-signing caveat.
#
set -euo pipefail

UPSTREAM_REPO="https://github.com/NVIDIA/cloudxr-apple-generic-viewer.git"
# Pinned deliberately. The patch touches project.pbxproj, which upstream may reformat; a moving
# target would break `git apply` in ways that are tedious to diagnose. Bump this consciously and
# regenerate the patch when you do.
UPSTREAM_COMMIT="3c8653a12e7519c0e98ead8ba0d95e72bac7abb7"
PLACEHOLDER_HOST="cloudxr.example.com:443"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_FILE="$SCRIPT_DIR/cloudxr-aws.patch"
DOMAIN=""
DEST="$SCRIPT_DIR/../../../cloudxr-apple-generic-viewer"

log() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain) DOMAIN="${2:-}"; shift 2 ;;
        --dest)   DEST="${2:-}";   shift 2 ;;
        -h|--help) sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done

[[ -n "$DOMAIN" ]] || die "--domain is required (e.g. --domain cloudxr.example.com)"
[[ -f "$PATCH_FILE" ]] || die "patch not found: $PATCH_FILE"

# Tolerate a value that already carries a port, or the legacy origin.* form, and normalise both
# to the apex domain before appending :443.
DOMAIN="${DOMAIN%%:*}"
if [[ "$DOMAIN" == origin.* ]]; then
    log "note: stripping 'origin.' prefix — native clients now go through CloudFront at the apex"
    DOMAIN="${DOMAIN#origin.}"
fi
# The port is deliberate, not cosmetic. Without it the framework dials 48322 and the connection
# times out against a CloudFront edge with no trace in the proxy log.
SIGNALING_HOST="$DOMAIN:443"

command -v git >/dev/null || die "git is required"
command -v xcodebuild >/dev/null || log "warning: xcodebuild not found — install Xcode before building"

log "Upstream:        $UPSTREAM_REPO"
log "Pinned commit:   $UPSTREAM_COMMIT"
log "Destination:     $DEST"
log "Signaling host:  $SIGNALING_HOST"
log ""

if [[ -e "$DEST" ]]; then
    die "$DEST already exists. Remove it, or pass --dest <other-path>."
fi

log "Cloning upstream sample..."
git clone --quiet "$UPSTREAM_REPO" "$DEST"
git -C "$DEST" checkout --quiet "$UPSTREAM_COMMIT"
log "  checked out $(git -C "$DEST" rev-parse --short HEAD)"

log "Applying cloudxr-aws.patch..."
# --3way gives a usable conflict state rather than a bare failure if the pin is ever moved.
if ! git -C "$DEST" apply --3way --whitespace=nowarn "$PATCH_FILE"; then
    die "patch did not apply. The pinned commit and the patch have diverged — regenerate the patch."
fi
log "  applied"

log "Setting signaling host to $SIGNALING_HOST..."
AUTH_FILE="$DEST/CloudXRViewer/Common/CloudXRAWSAuth.swift"
[[ -f "$AUTH_FILE" ]] || die "expected $AUTH_FILE after patching"
# LC_ALL=C keeps sed from choking on the file's non-ASCII characters on macOS.
LC_ALL=C sed -i '' "s|$PLACEHOLDER_HOST|$SIGNALING_HOST|g" "$AUTH_FILE"
grep -q "\"$SIGNALING_HOST\"" "$AUTH_FILE" || die "host substitution failed in $AUTH_FILE"
log "  set"

log ""
log "============================================"
log "  READY"
log "============================================"
log ""
log "Project:  $DEST/CloudXRViewer.xcodeproj"
log ""
log "Next:"
log "  1. open \"$DEST/CloudXRViewer.xcodeproj\""
log "  2. Wait for Xcode to resolve the CloudXRKit package (Swift Packages, first open only)."
log "  3. Set the run destination to an Apple Vision Pro simulator."
log "  4. Press Cmd+R, then sign in with your Cognito user and press Connect."
log ""
log "Deploy the stack with NATIVE_POOL_SIZE >= 1 first, or the proxy will have no native"
log "instance to bind and the connect will fail."
log ""
log "Command-line build (no signing needed for the simulator):"
log "  xcodebuild -project \"$DEST/CloudXRViewer.xcodeproj\" \\"
log "    -scheme CloudXRViewer-visionOS \\"
log "    -destination 'platform=visionOS Simulator,name=Apple Vision Pro' \\"
log "    -configuration Debug build CODE_SIGNING_ALLOWED=NO"
log ""
log "See avp-client-guide.md for what the patch changes and the device-signing caveat."
