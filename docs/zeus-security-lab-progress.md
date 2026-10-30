# ZEUS security laboratory implementation and acceptance

Branch: feature/zeus-security-lab-20261030 (base 224f043).
User approved continuing development/testing without a production host.

Existing verified foundations retained: real ADB input + Unicode IME, WebRTC,
manual takeover, APK/JADX/Apktool pipeline, isolated tool processes, authenticated
network feed, account/conversation gateway, immutable originals, actual AVD CI.

Implementation sequence:
1. Durable action timeline + session/run attribution + capture limitations and dropped-event accounting.
2. Structured APK audit (manifest/components/permissions/DEX/native libraries/source evidence), source search, endpoint correlation, JSON/HTML/PDF reports, reproducible comparison/export.
3. Bounded Logcat/PCAP/recording and explicitly approved dynamic instrumentation, capability checks and genuine unsupported/error results.
4. Integrated iPad workspace with timeline, analysis, logs, network inspector, reports, files and durable user control.
5. Agent workflows and permission contracts; GitHub repository CI adapter with bounded execution, distinct from persistent interactive hosting.
6. Backup/restore and hard quotas; actual emulator/build/browser regression checks.

Acceptance requires actual evidence per feature. Fixtures validate contracts only.
No production host is available; cellular TURN/iPad hardware and live deployment
cannot be marked complete. Do not provision paid infrastructure or repurpose the
current Railway cloud-agent service. Keep GitHub Actions to bounded repository tests.

## Checkpoint A — implemented and locally verified
- Account/conversation action timeline with bounded retention, actor and failure records.
- Emergency takeover interrupts a stalled agent action without waiting behind ADB; interrupted mutations remain uncertain and are not retried.
- Static analysis can run without starting Android: apksigner + Apktool + JADX, structured manifest/permissions/components/DEX/native inventory, bounded source indexing/search and host-level runtime correlations.
- JSON/HTML/PDF report export and original/rebuilt static comparison. Static heuristics remain observations/unresolved, not confirmed exploits.
- Bounded actual Logcat/PCAP/video subprocess recorders, real capability checks and signature validation for PCAP output; no synthetic fallback.
- Project-scoped ten-minute modification consent; agents cannot self-approve, and takeover revokes it. Cloud explicit approvals issue the worker consent through the trusted gateway.
- iPad/iPhone web panels for analysis, timeline, logs and recordings; native lab now reuses the existing message list/composer in an adjacent pane. Native changes still require macOS compilation and device acceptance.

Evidence: 33 local laboratory tests and 47 cloud tests passed; Chromium iPhone/iPad layout/navigation/upload tests passed. A real signed APK from previously verified CI was verified/decompiled with actual apksigner/Apktool/JADX and exported to real JSON/HTML/PDF under /workspace/outputs/security-lab-actual. These are not yet current-branch Android emulator or native Swift acceptance results.

Still pending: current-branch actual emulator acceptance; native build/test; MobSF adapter and authorized Frida lifecycle; GitHub repository CI orchestration; durable external backup/restore and hard quotas; optional video container/export improvements; production host/TURN/physical iPad remain unavailable.

## Runtime direction changed by user: temporary GitHub Actions sessions

The user selected GitHub Actions as the primary current runtime with no paid host.
The new transport work targets bounded repository APK tests and temporary free
Cloudflare relay URLs, not a permanent emulator service. Quick Tunnels do not
support SSE; WebSocket feeds and H.264/fMP4 MSE video avoid that limitation. The
original WebRTC node transport remains available. An explicitly labelled successive
JPEG fallback is implemented for unsupported/failed MSE playback.

Actual local evidence: a real Chromium MSE client decoded genuine fragmented MP4
frames sent over authenticated WebSocket from a synthetic H.264 process. This is
codec/transport evidence, not an Android emulator claim. A new actual AVD32 tunnel
acceptance workflow is being prepared; its success must be observed separately.

The ZEUS repository is public. Connection credentials and checkpoints are sealed
to a client X25519 public key with HKDF-SHA256/AES-GCM before artifact publication.
Streaming archive encryption validates complete frames/end markers; corruption,
wrong keys and truncated restores fail without overwriting an existing target.
The test workflow uses one standard Linux runner, one session, a 15-minute session
limit and 28-minute overall job limit, 1-day artifacts and a 50-MiB aggregate test
artifact budget. These acceptance limits are not a complete account-wide billing
or durable project retention implementation.

References:
- https://developers.cloudflare.com/tunnel/get-started/quick-tunnels/
- https://developers.cloudflare.com/sandbox/sdk/api/tunnels/
- https://docs.github.com/en/billing/concepts/product-billing/github-actions
- https://developer.apple.com/documentation/safari-release-notes/safari-17-release-notes
