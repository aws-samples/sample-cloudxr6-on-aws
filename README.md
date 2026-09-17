# Streaming Immersive Digital Worlds with NVIDIA CloudXR 6 on AWS

An AWS-specific reference architecture and deployment guide for [NVIDIA CloudXR 6](https://docs.nvidia.com/cloudxr-sdk/), optimized for ultra-low latency XR streaming via [AWS Local Zones](https://aws.amazon.com/about-aws/global-infrastructure/localzones/).

## Overview

This architecture enables streaming high-fidelity VR/AR content from AWS GPU instances to XR headsets (Meta Quest, Apple Vision Pro, Pico) over the internet. Using NVIDIA-recommended GPU instances in AWS Local Zones, pose-to-render latency of ~35-40ms is achievable — within the range that CloudXR 6's compensation techniques (pose prediction, ATW) can mask effectively.

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
| [mvp-lovr-demos/](mvp-lovr-demos/) | (Optional Resource) Minimal single-instance demo: one GPU instance streaming the LÖVR sample directly to one Quest 3, end-to-end tested. Intentionally bare-bones — no HTTPS, no proxy, no auth |

## Status

✅ **Quest 3 / WebRTC path** — Deployed and tested end-to-end at ~90 FPS (the headset's target refresh rate) and 35-40ms pose-to-render from a g7e in the LAX Local Zone. Also validated on a `g6e.8xlarge` in the us-east-2 Region, confirming the parent-Region path.

✅ **Apple Vision Pro / native path** — Auth, instance selection, signaling, ICE-negotiated UDP media, the data channel and session lifecycle all confirmed against a live deployment at 60 FPS with 21ms network latency to the LAX Local Zone. Both paths ran concurrently on one deployment.

  Tested on the **visionOS Simulator**, not hardware. It runs the same CloudXR Framework binary, so the protocol path is exercised identically — but visual quality and bitrate are **not** representative (software decode), and real hand and eye tracking are untested. Full breakdown in [the validation status table](deployment/full-architecture-deployment-guide.md#validation-status-of-the-native-path); [avp-client-guide.md](deployment/avp-client-guide.md) to reproduce.

## Based On

- [NVIDIA CloudXR SDK Documentation](https://docs.nvidia.com/cloudxr-sdk/release/6/index.html)
- [NVIDIA CloudXR Cloud Deployment Guide](https://docs.nvidia.com/cloudxr-sdk/release/6/integration/cloud_deployment.html)
- [NVIDIA CloudXR.js Documentation](https://docs.nvidia.com/cloudxr-sdk/release/6/usr_guide/cloudxr_js/index.html)
- [NVIDIA CloudXR LÖVR Sample](https://github.com/NVIDIA/cloudxr-lovr-sample) (v1.2.0 — pinned to commit `6b30ddc`; upstream publishes no tags)
- [NVIDIA CloudXR.js Samples](https://github.com/NVIDIA/cloudxr-js-samples) (harvested at deploy time by `deploy.sh`, not vendored here)
- [NVIDIA CloudXR Apple Generic Viewer](https://github.com/NVIDIA/cloudxr-apple-generic-viewer) (pinned to commit `3c8653a`; fetched and patched by `deployment/avp-client/setup-avp-client.sh`, not vendored here — see [avp-client-guide.md](deployment/avp-client-guide.md))
- [NVIDIA CloudXR Release Notes](https://docs.nvidia.com/cloudxr-sdk/release/6/release_notes/release_notes.html)

## License

This sample is licensed under the MIT-0 License. See the [LICENSE](LICENSE) file.

It is not an official product or offering from Amazon or AWS.
