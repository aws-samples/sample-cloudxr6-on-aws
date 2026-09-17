# CloudXR 6 on AWS — A Reference Architecture and Deployment Guide

An AWS-specific reference architecture and deployment guide for [NVIDIA CloudXR 6](https://docs.nvidia.com/cloudxr-sdk/), optimized for ultra-low latency XR streaming via [AWS Local Zones](https://aws.amazon.com/about-aws/global-infrastructure/localzones/).

## Overview

This architecture enables streaming high-fidelity VR/AR content from AWS GPU instances to XR headsets (Meta Quest, Apple Vision Pro, Pico) over the internet. Using NVIDIA-recommended GPU instances in AWS Local Zones, pose-to-render latency of ~35-40ms is achievable — within the range that CloudXR 6's compensation techniques (pose prediction, ATW) can mask effectively.

Signaling is tunneled through a single HTTPS/WSS entry point that authenticates every request against Cognito — both the session API and the WebSocket upgrade — while media is established directly between client and GPU instance using ICE with a STUN server, the media establishment approach in [NVIDIA's cloud deployment guide](https://docs.nvidia.com/cloudxr-sdk/release/6/integration/cloud_deployment.html). Every client path, web and Apple native alike, arrives through CloudFront on 443.

The full architecture design document begins with an overview of the two primary considerations at play when deploying CloudXR as a cloud-hosted service: latency and cost — to help you adapt this reference architecture to your specific use case(s) and needs.

## Target SDK Versions

| Component | Version | Release Date |
|-----------|---------|--------------|
| CloudXR Runtime | 6.2.1 | June 26, 2026 |
| CloudXR.js | 6.2.0 | May 22, 2026 |
| CloudXR Framework | 6.2.0 | June 26, 2026 |
| LÖVR Sample | 1.2.0 | July 2026 |

## Contents

| File | Description |
|------|-------------|
| [architecture/](architecture/) | Full architecture design document and Mermaid diagram |
| [deployment/](deployment/) | Full architecture deployment guide - complete steps to deploy full architecture. Also contains [avp-client-guide.md](deployment/avp-client-guide.md), which covers building and testing an Apple Vision Pro client against a deployment |
| [mvp-lovr-demos/](mvp-lovr-demos/) | (Optional Resource) Minimal single-instance demo: one GPU instance streaming the LÖVR sample directly to one headset. The **Quest 3 guide is complete and end-to-end tested**; the Apple Vision Pro guide is a placeholder (see Status below). Intentionally bare-bones — no HTTPS, no proxy, no auth |

## Status

✅ **Validated (Quest 3 / WebRTC path)** — The full architecture has been deployed and tested end-to-end. Quest 3 streams at ~90 FPS (the headset's target refresh rate) and 35-40ms pose-to-render from a g7e instance in the LAX Local Zone. Also validated on a `g6e.8xlarge` in the us-east-2 Region, confirming the parent-Region path.

✅ **Validated (Apple Vision Pro / native path)** — Authentication, instance selection, signaling, ICE-negotiated UDP media, the bidirectional data channel, and session lifecycle all confirmed against a live deployment, streaming at 60 FPS with 21ms network latency to the LAX Local Zone. Both paths were exercised on the same deployment concurrently.

  Tested with the **visionOS Simulator**, not physical hardware. The simulator runs the same CloudXR Framework binary, so the protocol path is exercised identically — but visual quality and bitrate are **not** representative (software decode caps the stream well below available bandwidth), and real hand and eye tracking are untested. See [the validation status table](deployment/full-architecture-deployment-guide.md#validation-status-of-the-native-path) for the precise breakdown, and [avp-client-guide.md](deployment/avp-client-guide.md) to reproduce it.

🚧 Coming soon:
- AVP / native path MVP demo instructions (the single-instance demo under `mvp-lovr-demos/`; the full architecture path above is validated)

## Based On

- [NVIDIA CloudXR SDK Documentation](https://docs.nvidia.com/cloudxr-sdk/release/6/index.html)
- [NVIDIA CloudXR Cloud Deployment Guide](https://docs.nvidia.com/cloudxr-sdk/release/6/integration/cloud_deployment.html)
- [NVIDIA CloudXR.js Documentation](https://docs.nvidia.com/cloudxr-sdk/release/6/usr_guide/cloudxr_js/index.html)
- [NVIDIA CloudXR LÖVR Sample](https://github.com/NVIDIA/cloudxr-lovr-sample) (v1.2.0 — pinned to commit `6b30ddc`; upstream publishes no tags)
- [NVIDIA CloudXR.js Samples](https://github.com/NVIDIA/cloudxr-js-samples) (harvested at deploy time by `deploy.sh`, not vendored here)
- [NVIDIA CloudXR Apple Generic Viewer](https://github.com/NVIDIA/cloudxr-apple-generic-viewer) (pinned to commit `3c8653a`; fetched and patched by `deployment/avp-client/setup-avp-client.sh`, not vendored here — see [avp-client-guide.md](deployment/avp-client-guide.md))
- [NVIDIA CloudXR Release Notes](https://docs.nvidia.com/cloudxr-sdk/release/6/release_notes/release_notes.html)

## License

This project is provided as-is for reference purposes only, and is not an official product or offering from Amazon or AWS.
