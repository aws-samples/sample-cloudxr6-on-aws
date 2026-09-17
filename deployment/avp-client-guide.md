# Native Client for Apple Vision Pro — Build, Deploy, Test

How to build an Apple Vision Pro client for a CloudXR-on-AWS deployment and stream to it, using
NVIDIA's [CloudXR Generic Viewer](https://github.com/NVIDIA/cloudxr-apple-generic-viewer) sample
with this repo's modifications applied.

This is the native path counterpart to the web path covered in
[full-architecture-deployment-guide.md](full-architecture-deployment-guide.md). It assumes you
have already deployed the full architecture from that guide.

**Everything below was validated against a live deployment using the visionOS Simulator.** What
that does and does not establish is set out in
[Validation status of the native path](full-architecture-deployment-guide.md#validation-status-of-the-native-path).
Read that before quoting any stream-quality number from this guide.

📹 **[Watch the walkthrough](https://streamable.com/2o5bic)** — a narrated screen recording of
the whole flow in the visionOS Simulator: opening the viewer, signing in, connecting, the LÖVR
sample streaming, a tour of the HUD and Server Actions panels, and disconnecting. Useful for
knowing what success looks like before you start. It shows the happy path; a freshly booted
instance often needs a reconnect first, covered in [Troubleshooting](#troubleshooting).

---

## Contents

- [The one thing to get right: the port](#the-one-thing-to-get-right-the-port)
- [Prerequisites](#prerequisites)
- [Step 1 — Deploy with a native pool](#step-1--deploy-with-a-native-pool)
- [Step 2 — Fetch and patch the viewer](#step-2--fetch-and-patch-the-viewer)
- [Step 3 — Build for the simulator](#step-3--build-for-the-simulator)
- [Step 4 — Connect](#step-4--connect)
- [Step 5 — Read the metrics](#step-5--read-the-metrics)
- [What the patch changes](#what-the-patch-changes)
- [Building for real hardware](#building-for-real-hardware)
- [Foveation — two different features](#foveation--two-different-features)
- [Troubleshooting](#troubleshooting)
- [Tearing down](#tearing-down)

---

## The one thing to get right: the port

Native clients take the same route as web clients — CloudFront on 443, then the load balancer,
then the proxy. They differ in the signaling path: the framework's RTSP-over-WebSocket signaling
uses a fixed `/rtsp`, where the WebRTC web client uses `/sign_in`. The stack has a CloudFront
behavior for each, so this is already handled; it matters only if you change the distribution.
There is one detail you *do* have to get right, and it is the single most likely thing to go
wrong, so it is worth understanding before you start.

CloudXR Framework's connection type for a cloud proxy is:

```swift
case remoteSecure(host: String,
                  signalingHeaders: [String: String] = [:],
                  certificateValidationHandler: ...)
```

Note there is no port parameter. If you pass a bare hostname, the framework falls back to its
default secure-signaling port: it probes **322**, then **48322**. NVIDIA documents 48322 as the
secure-signaling port and describes the proxy topology as `wss://<proxy>:48322`. CloudFront
accepts viewer connections only on 80 and 443, so a bare hostname produces a connection timeout
against a CloudFront edge — surfacing as a generic `0x800B1004` in the app with **nothing at all
in the proxy log**, because the connection never arrives.

The fix is to state the port in the host string:

```swift
.remoteSecure(host: "cloudxr.example.com:443", ...)
```

`.remoteSecure` accepts a `host:port` value and honours the port. That behaviour is
**undocumented** by NVIDIA as of 6.2.x — it was confirmed by their engineering team and verified
by test. Without it, a CloudXR native client could not sit behind a CDN at all.

The stack exposes the correct value, port included, as the `NativeSignalingHost` output. The
setup script in the next step fills it in for you, so you only hit this if you are wiring a
client up by hand.

---

## Prerequisites

**A deployed stack** from
[full-architecture-deployment-guide.md](full-architecture-deployment-guide.md), with
`NATIVE_POOL_SIZE` at 1 or more.

**A Mac with Xcode.** Validated against:

| Component | Version |
|-----------|---------|
| macOS | 26.6.2 |
| Xcode | 26.6 (17F113) |
| visionOS SDK | 26.5 |
| visionOS Simulator runtime | 26.5 |

Earlier versions may work; these are what the walkthrough was run on. You need the visionOS
platform support installed — in Xcode, **Settings → Components** — which is a separate download
from Xcode itself and includes the simulator runtime.

**No Apple Developer paid membership is needed for the simulator.** Building for physical
hardware is a different matter; see [Building for real hardware](#building-for-real-hardware).

**No Vision Pro required.** The simulator is sufficient for everything in this guide.

---

## Step 1 — Deploy with a native pool

The native pool is what serves Apple clients. In `config.env`:

```bash
NATIVE_POOL_SIZE=1
WEBRTC_POOL_SIZE=0
```

**Set both.** `WEBRTC_POOL_SIZE` defaults to `1`, so setting only `NATIVE_POOL_SIZE` leaves you
paying for two GPU instances when this guide needs one. Zeroing the webrtc pool has one
consequence worth knowing: `deploy.sh` harvests the CloudXR.js web client from a webrtc-pool
instance, so with none running the `/cloudxr/` path is left unpopulated and the browser client
will not work. That does not affect the native path. Leave `WEBRTC_POOL_SIZE=1` if you want both
paths live on the same deployment, as the validation run did.

If you deployed with `NATIVE_POOL_SIZE=0`, no instance will be registered in the native pool and
the proxy will reject the connection with no instance available — the client reports a generic
connection failure, which is confusing to debug. Set it and redeploy.

No infrastructure differs between a deployment with a native pool and one without — native
clients use the same CloudFront endpoint as web clients, so there is nothing extra to provision
and no ordering dependency. `NATIVE_POOL_SIZE` only controls whether a GPU instance exists to
serve them.

Get the value your client will use as its host:

```bash
aws cloudformation describe-stacks \
  --stack-name cloudxr-infrastructure \
  --region <your-region> \
  --query 'Stacks[0].Outputs[?OutputKey==`NativeSignalingHost`].OutputValue' \
  --output text
```

That prints `<your-domain>:443` — port included, because it is required. Confirm the endpoint is
reachable before touching Xcode; this takes seconds and rules out half of what can go wrong
later:

```bash
curl -s -o /dev/null -w 'health: %{http_code}\n' https://<your-domain>/health
```

A `200` means CloudFront is serving, TLS is valid, and the proxy is behind it.

---

## Step 2 — Fetch and patch the viewer

This repo does **not** vendor NVIDIA's sample. It fetches it at a pinned commit and applies a
patch, the same philosophy `deploy.sh` uses for the CloudXR.js web sample.

```bash
cd deployment/avp-client
./setup-avp-client.sh --domain <your-domain>
```

Pass the plain domain (`cloudxr.example.com`). The script appends `:443` for you, and tolerates
you passing a value that already carries a port.

What it does:

1. Clones `https://github.com/NVIDIA/cloudxr-apple-generic-viewer` into a sibling directory of
   this repo — deliberately outside it, so the working copy is never committed here
2. Checks out commit `3c8653a12e7519c0e98ead8ba0d95e72bac7abb7`
3. Applies `cloudxr-aws.patch`
4. Rewrites `CloudXRAWSDefaults.signalingHost` to `<your-domain>:443`

Use `--dest <path>` to put it somewhere else. The script refuses to overwrite an existing
directory.

The commit pin is deliberate. The patch touches `project.pbxproj`, which upstream may reformat
at any time; a moving target would break `git apply` in ways that are tedious to diagnose. If you
bump the pin, regenerate the patch.

---

## Step 3 — Build for the simulator

Open the project:

```bash
open ../../../cloudxr-apple-generic-viewer/CloudXRViewer.xcodeproj
```

On first open, Xcode resolves the CloudXRKit Swift package from
`https://github.com/NVIDIA/cloudxr-framework`. Wait for that to finish — the progress appears in
the toolbar or under the Report navigator. Nothing will build until it completes.

Set the run destination to an **Apple Vision Pro simulator**. The destination selector sits next
to the scheme name at the top of the window. Pick the scheme `CloudXRViewer-visionOS` and a
destination whose name begins with "Apple Vision Pro".

Press **⌘R**.

To build from the command line instead:

```bash
xcodebuild -project CloudXRViewer.xcodeproj \
  -scheme CloudXRViewer-visionOS \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

`CODE_SIGNING_ALLOWED=NO` is what lets this build without a signing identity. It is safe for the
simulator and not appropriate for hardware.

---

## Step 4 — Connect

The app opens on a config panel with everything pre-filled except your credentials:

| Field | Value |
|-------|-------|
| Select Zone | `CloudXR on AWS proxy` |
| Proxy Host | `<your-domain>:443` — the port is required |
| Username | your Cognito user |
| Password | that user's password |
| Enable Hand Tracking | on |
| Resolution Preset | Standard Mode |

`deploy.sh` creates a `demo` user and prints its password at the end of the deployment.

Enter the username and password, then press **Connect**.

The app exchanges those credentials for a Cognito ID token itself and presents it on the
signaling upgrade. There is no token to mint or paste. On success it stores a refresh token in
the Keychain, so subsequent connects need no password at all — the Password field then reads
"using saved sign-in", with a **Forget saved sign-in** button to clear it. Cognito refresh tokens
are valid for 30 days by default.

When the session connects, the app opens an immersive space and the config window is replaced.
This surprises most people the first time: **the window does not disappear, it moves**, and in an
immersive space it can end up behind you.

To get it back, **right-click** (or triple-tap) anywhere in the immersive scene. That toggles the
window. If it returns somewhere awkward, use **Device → Re-Center Open Apps** in the Simulator
menu bar.

To look around the immersive scene, drag with the mouse. The Simulator's **Device** menu also
offers Look Around, Pan, Orbit and Dolly modes, plus **Reset Camera**.

---

## Step 5 — Read the metrics

The window that replaces the config screen has an **ornament** — a small floating row of buttons
attached just below its bottom edge. It is easy to miss:

```
[ HUD ]  [ Config Screen ]  [ Server Actions ]
```

**HUD** reports frame receive rate, reprojection rate and pose rate (each with p10/p5/p1 and
average), available bandwidth against actual streaming rate, and three pose-to-frame latency
measures. It also shows stream resolution and a server version string.

> Ignore that version string if it looks wrong. It reads **6.0.0** even though this
> architecture deploys CloudXR Runtime **6.2.1** — confirmed from the `VERSION` file in the SDK
> directory on the instance, which `ami/scripts/04-install-app.ps1` pins explicitly. The HUD
> value appears to be a protocol or interface version rather than the runtime build, so it is
> not evidence that your deployment installed the wrong version.

**Server Actions** drives the opaque data channel. The LÖVR sample renders a floating
"Received:" string in the scene; sending from this tab changes it. That is the cheapest way to
confirm the **client-to-server** direction, since everything else you can see only proves
server-to-client.

**Config Screen** returns you to the connection form, where a **Network Statistics** popover
reports latency, jitter and bandwidth as a summary, with a signal-strength indicator.

### Reading the numbers honestly

From the validation run, for calibration:

| Metric | Observed | Interpretation |
|--------|----------|----------------|
| Frame receive rate | 60.1 /s average | Full rate. p1 dips are worst-1%, not typical |
| Pose to frame submitted | 54.1 ms average | Includes network both ways plus encode and decode |
| Network latency | 21 ms | To a Local Zone. This is the number that reflects your AWS placement |
| Jitter | 17 ms | High relative to latency. Was traced to the Mac's Wi-Fi link, not AWS |
| Available bandwidth | 35-44 Mbps | Plenty of headroom |
| Actual streaming rate | 12 Mbps | **Well below available** — see below |
| Server load | 7% GPU, ~25% encoder | Neither the instance nor the network was the constraint |

That gap between 40+ Mbps available and 12 Mbps used is the single most important thing to
understand about testing on the simulator. Two client-side factors drive it: the simulator
decodes video in **software**, and Wi-Fi jitter makes frame arrival irregular. CloudXR's adaptive
bitrate controller responds to both by backing off. The client log shows the corroborating
evidence, its frame queue overflowing:

```
[CloudXRKit:CloudXRFrameRenderer] Discarded frames from completeFrameQueue to stay within 20 limit
```

So **do not judge visual quality from the simulator.** Frame pacing, latency and the correctness
of the whole path are all meaningful. Image fidelity is not. A wired connection removes the
jitter half; only real hardware with hardware decode removes the other.

---

## What the patch changes

`cloudxr-aws.patch` is roughly 500 added lines across five files, every hunk tagged
`CLOUDXR-AWS` so the delta from upstream stays auditable.

**`CloudXRViewer/Common/CloudXRAWSAuth.swift`** (new). Fetches `/config.json` from your
deployment to discover the Cognito region and app client ID, exchanges username and password for
an ID token via Cognito's `InitiateAuth`, and stores the refresh token in the Keychain for silent
re-authentication. No AWS SDK dependency: the app client has no client secret, so `InitiateAuth`
needs neither SigV4 signing nor a `SECRET_HASH`, and a plain `URLSession` POST suffices.

Signaling and `config.json` share the same hostname, since both arrive through CloudFront. The
file is served from S3 via CloudFront rather than by the proxy — `.dockerignore` deliberately
keeps it out of the container image so Cognito IDs are never baked into a build.

**`SessionConfigView.swift`.** Adds a `.cloudxrAwsProxy` branch that builds
`.remoteSecure(host:signalingHeaders:certificateValidationHandler:)` with an
`Authorization: Bearer` header and `x-cloudxr-device-type: native`. Certificate validation uses
`SecTrustEvaluateWithError`, i.e. normal system trust, because the client's TLS peer is a
CloudFront edge presenting a CA-signed certificate. (The ALB's regional certificate covers only
the CloudFront-to-origin hop; clients never address the load balancer directly.)

The connection type is assembled inside the existing `Task`, not in the synchronous branch above
it, because the token is fetched asynchronously. That mirrors how the sample already defers guest
mode's connection type until `getGuestAuth` resolves.

Also changes four defaults so a fresh install needs only credentials: zone becomes
`.cloudxrAwsProxy`, host becomes your signaling host, and hand tracking defaults on. Resolution
preset was already `.standardPreset`.

Host and token are **trimmed** before use. The visionOS software keyboard appends a trailing
space when pasting into a text field, which produces a hostname like `"example.com "` — URL
construction then fails and no connection is attempted at all, with no useful error.

**`SessionConfigView+extensions.swift`.** Adds the `cloudxrAwsProxy` zone case and excludes it
from guest mode.

**`SessionConfigView+visionOS.swift`.** Adds the Proxy Host, Username and Password fields, an
inline error line, and the Forget saved sign-in button.

**`project.pbxproj`.** Three things. Registers the new source file in both targets. Adds the
CloudXRKit Swift package reference — **upstream ships two dangling
`XCSwiftPackageProductDependency` entries for CloudXRKit with no package reference at all, so the
project cannot build as cloned**; the patch adds the missing
`XCRemoteSwiftPackageReference` to `github.com/NVIDIA/cloudxr-framework` and wires it to the
visionOS target. And it blanks `CODE_SIGN_ENTITLEMENTS`, discussed next.

> The patch wires the package to the **visionOS target only**. The iOS target's dangling
> dependency is left as upstream shipped it, so the iOS target is not expected to build. This
> guide covers visionOS.

---

## Building for real hardware

Everything above targets the simulator. A build for physical Vision Pro differs in one way that
is not a formality.

Upstream's visionOS target references an entitlements file containing:

```xml
<key>com.apple.developer.low-latency-streaming</key>
<true/>
```

The patch blanks `CODE_SIGN_ENTITLEMENTS` so simulator builds work without it. The simulator does
not enforce entitlements, so nothing is lost there.

**On hardware it is enforced.** `com.apple.developer.low-latency-streaming` is a restricted
entitlement: it must be granted to your Apple Developer account and included in a provisioning
profile. That is a request-and-approval process with Apple, not a checkbox. Building and
installing on a real Vision Pro requires it, along with a paid Apple Developer membership and a
signing identity.

So to go to hardware: obtain the entitlement, restore the `CODE_SIGN_ENTITLEMENTS` setting to
`CloudXRViewer/visionOS/CloudXRViewer-visionOS.entitlements`, configure signing with your team,
and drop `CODE_SIGNING_ALLOWED=NO`. Nothing about the AWS side changes.

---

## Foveation — two different features

Two different NVIDIA features share the name, and they are easy to conflate. One is a server-side
toggle you could use today; the other is a different client framework.

**`runtime-foveation`** is a server-side Runtime Management API property (Boolean, default
`false`) that enables *static center* foveated streaming — more pixel density in the middle of
the view, less in the periphery. It is set in `cloudxr_manager.lua`, the same file
`ami/scripts/startup.ps1` already writes `enable-ice` and the STUN settings into, and it needs no
client changes at all. A companion property, `runtime-foveation-unwarped-width`, tunes the
pre-distortion render resolution.

This architecture leaves it off. If you enable it, note NVIDIA's warning that it is **HMD-only**
and should not be used "when using auto-native mode with an iPad device connected." Our native
pool runs `auto-native` and is documented as serving iPhone and iPad alongside Vision Pro, so
this is a Vision Pro optimization that could break other clients sharing that pool.

**Foveated Streaming** is something else entirely: a separate client framework, not a setting.
It is Apple's own visionOS system framework (`import FoveatedStreaming`, no package to add),
built on CloudXR, using eye tracking to raise quality in the gaze region and cut peripheral
bandwidth — privately, since the OS never exposes gaze data to the application. It needs the
`com.apple.developer.foveated-streaming-session` entitlement and visionOS 26.4 or later, and it
appears as a peer product alongside CloudXR Framework in NVIDIA's feature availability matrix,
with its own Xcode template, its own Apple sample, and a formal migration guide. Adopting it
means rewriting the client, not reconfiguring it.

Before investing in that, check one thing with NVIDIA: the 6.2.1 feature availability matrix
lists **STUN for public endpoint discovery as "Not available" for Foveated Streaming**, while
CloudXR Framework has it as of 6.2.0. If accurate, that is disqualifying for a cloud deployment
like this one, whose entire media path depends on ICE plus STUN to discover the instance's public
candidate. We have not verified it, and the same matrix conflicts with other NVIDIA documents on
at least one other row, so treat it as a question to ask rather than a settled fact.

---

## Troubleshooting

### Connection fails with `0x800B1004`

`NVST_R_ERROR_UNEXPECTED_DISCONNECTION_INITIAL`. Despite the `0x800B` prefix, which is the
Windows certificate-error family, this is **not** a TLS problem. It is the generic
initial-connection failure.

Read the client log to find the actual cause:

```bash
xcrun simctl spawn <device-udid> log show --last 5m --style compact \
  --predicate 'process == "CloudXRViewer"' \
  | grep -iE 'RtspClient|SignalingHandler|connect timed out|WS upgrade'
```

The line that matters looks like:

```
Failed to create the RTSP session: HTTP Exception: WS upgrade failed: Timeout: connect timed out: <ip>:48322
```

**Look at the port.** If it says `48322` (or `322`), the Proxy Host is missing its `:443` — the
framework fell back to its default signaling port, and CloudFront does not serve it. Set the host
to `<your-domain>:443` and reconnect. This is by far the most common native misconfiguration, and
the proxy log will be completely empty for these attempts because nothing ever reaches AWS.

If the port reads `443` and it still times out, the problem is reachability rather than
configuration. Check the endpoint directly:

```bash
curl -s -o /dev/null -w 'health: %{http_code}\n' https://<your-domain>/health
```

If the address is correct and the proxy log shows the tunnel was established, this is not a
configuration problem — try reconnecting once or twice, and see
[First connection after the instance boots](#first-connection-after-the-instance-boots-fails-or-streams-badly).

### Connection fails immediately with `0x80420001`

`NVST_SIGERR_FORBIDDEN`. The client log reads:

```
RTSP/WebSocket upgrade forbidden (403): WS upgrade failed: Cannot upgrade to WebSocket connection: Forbidden
```

Distinguish this from the port problem above by **how fast it fails**. A missing `:443` produces a
~20-second connect timeout; this returns in under a second, which means TCP, TLS, and an HTTP
request all completed. The endpoint is reachable and the port is right — something answered, and
what it answered was 403.

The proxy never returns 403 on an upgrade: it can only answer 401, 500, 502, 503, or 504, and it
logs every upgrade before running any check. So an empty proxy log alongside a 403 means CloudFront
answered, not the proxy — the request matched no ALB cache behavior, fell through to the default
behavior pointing at S3, and S3 returned `AccessDenied` for a key it does not hold.

Confirm which hop answered by checking the `Server` header:

```bash
curl -sS -o /dev/null -D - --http1.1 \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' -H 'Sec-WebSocket-Version: 13' \
  https://<your-domain>/rtsp | grep -iE '^HTTP|^server'
```

`401` with no `Server: AmazonS3` is correct — the upgrade reached the proxy and was refused for
lack of a credential, which is all curl can demonstrate without a token. `403` with
`Server: AmazonS3` means the `/rtsp*` cache behavior is missing from the distribution.

### Nothing appears in the proxy log

If `aws logs filter-log-events --log-group-name /ecs/cloudxr-proxy` shows nothing for your
attempt, the connection never reached the proxy. Check the client log as above. Two causes look
identical from the app: a hostname with a trailing space fails URL construction and produces no
network attempt whatsoever, and a 403 from CloudFront never reaches the proxy either — the error
code tells them apart (`0x800B1004` versus `0x80420001`).

### `Upgrade rejected (invalid header token): jwt expired`

The stored token aged out. With the Cognito sign-in in this patch you should not see this, since
the app re-mints on each connect. If you do, press **Forget saved sign-in** and sign in again —
the refresh token may have been revoked or passed its 30-day window.

Note the proxy validates the token only at the WebSocket upgrade, not continuously. An
established session is unaffected by its token expiring mid-stream.

### Connected, but the window vanished

Expected. The app opens an immersive space on connect and replaces the config window.
**Right-click in the scene** to toggle it back, then **Device → Re-Center Open Apps** if it
returns out of view. See [Step 4](#step-4--connect).

### First connection after the instance boots fails or streams badly

Not specific to the native path — it affects every client. On a freshly booted GPU instance the
first one or two attempts may error outright or connect but stream poorly, and the first attempt
can take around 30 seconds to reach connected. Disconnect and reconnect until the stream is
smooth, typically by the second or third attempt, after which the instance is stable for the rest
of its life.

Full detail, including what the server logs show and the current investigation status, is in
[Notes from Validation](full-architecture-deployment-guide.md#notes-from-validation).

### Stream looks soft or low quality

First rule out the boot warm-up above by reconnecting once. If it persists, it is almost
certainly the simulator rather than your deployment. Check the HUD: if available bandwidth is far
above actual streaming rate, adaptive bitrate has backed off because the client cannot keep up.
See [Reading the numbers honestly](#reading-the-numbers-honestly). Wired ethernet helps by
removing jitter; only real hardware fixes decode.

### Testing the upgrade with `curl`

Useful for isolating whether a problem is client-side or server-side. Two things to get right.

**Use the `/rtsp` path.** That is where the native framework signals, and it is the path with a
CloudFront behavior routing to the ALB. A bare `https://<your-domain>/` matches only the default
behavior and is served from S3, so you get the login page with a `200` no matter how healthy the
proxy is.

**Force HTTP/1.1.** Over HTTP/2 the `Connection: Upgrade` header is invalid, so the request is
sent as an ordinary `GET` and never becomes an upgrade — you learn nothing about the tunnel.

```bash
TOKEN=$(aws cognito-idp initiate-auth --auth-flow USER_PASSWORD_AUTH \
  --client-id <app-client-id> \
  --auth-parameters USERNAME=demo,PASSWORD='<password>' \
  --region <region> --query 'AuthenticationResult.IdToken' --output text)

curl -s -i --http1.1 --max-time 15 \
  -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  -H "Authorization: Bearer $TOKEN" -H "x-cloudxr-device-type: native" \
  "https://<your-domain>/rtsp"
```

`401` means auth is being enforced and your token was rejected. `503` means you authenticated but
no native-pool instance was free — check `NATIVE_POOL_SIZE` and the registry. A `403` with
`Server: AmazonS3` means the `/rtsp*` cache behavior is missing from the distribution. A `501` is
actually the good outcome here: the proxy authenticated you and opened the tunnel, and the CloudXR
Runtime then rejected `curl` because it does not speak CloudXR's protocol. Confirm in the proxy
log:

```
Upgrade authenticated via header
Signaling session: i-... (native) → 10.0.x.x:48010
  Tunnel established: client ↔ 10.0.x.x:48010
```

### Checking that media actually flowed

Client side, look for the frame renderer discarding frames. You cannot discard frames you never
received, so these lines are positive evidence:

```bash
xcrun simctl spawn <device-udid> log show --last 5m --style compact \
  --predicate 'process == "CloudXRViewer"' | grep CloudXRFrameRenderer
```

Server side, check the hardware encoder during a session:

```bash
aws ssm send-command --instance-ids <native-instance-id> --region <region> \
  --document-name "AWS-RunPowerShellScript" \
  --parameters 'commands=["nvidia-smi --query-gpu=utilization.gpu,utilization.encoder --format=csv,noheader"]'
```

A non-zero encoder utilization means NVENC is actively encoding and shipping frames.

### Simulator screenshots are very large

`xcrun simctl io <udid> screenshot out.png` produces multi-megabyte files. Downscale before
sharing:

```bash
sips -Z 1000 -s format jpeg out.png --out out.jpg
```

### Changing app settings from the command line does not work

Writing the app's preferences plist directly has no effect: `cfprefsd` in the simulator serves a
cached copy that survives the edit, and `killall` is not available inside the simulator to flush
it. Change values in the app's UI. Uninstalling the app (`xcrun simctl uninstall`) does clear
them, which is how to test first-run defaults — though the Keychain is device-scoped and may
outlive an uninstall, so a saved sign-in can persist.

---

## Tearing down

The client needs no cleanup beyond deleting the cloned directory. To remove the AWS side, follow
the teardown section of
[full-architecture-deployment-guide.md](full-architecture-deployment-guide.md). Nothing in this
guide creates AWS resources outside that stack.
