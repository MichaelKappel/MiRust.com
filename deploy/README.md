# MiRust.com Root-Discovery Publication

This repository publishes only the exact files in the deployment manifest. It
never uploads, merges, clears, or treats the live WordPress tree as source.

```powershell
node tools/build-site-deployment-manifest.js <content-commit>
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/deploy-site.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/deploy-site.ps1 -Publish
```

The manifest generator reconstructs canonical Git blob bytes into an ignored,
create-only `2.6.1` staging root and writes only
`deploy/site-deployment-manifest-2.6.1.v1.json`. It first verifies the immutable
`2.6.0` manifest and terminal receipt byte identities, then derives every
authenticated current-file before-state from that preserved evidence. The
historical `2.6.0` manifest and receipt are never overwritten.

Until a terminal `2.6.1` publication receipt and exact HTTPS readback exist,
`2.6.0` remains the currently published MiRust root-discovery release. Prepared
source, a content commit, or a generated manifest is not deployment evidence.

The publisher requires a clean pushed checkout and
local/tracking/FETCH_HEAD/direct-remote equality. Before any write, it checks
every active authenticated FTPS identity, confirms all twelve historical
retirements remain absent, and checks all unoccupied staging names. It publishes
only registered files, publishes `/.well-known/site-release.json` last,
verifies exact HTTPS bytes and private-path denial, and writes one append-only
terminal receipt. A terminal operation is never retried or repaired; any later
action requires a new identity and manifest.
