# MiRust.com Root-Discovery Publication

This repository publishes only the exact files in the deployment manifest. It
never uploads, merges, clears, or treats the live WordPress tree as source.

```powershell
node tools/build-site-deployment-manifest.js <content-commit>
pwsh -File tools/deploy-site.ps1
pwsh -File tools/deploy-site.ps1 -Publish
```

The manifest generator reconstructs canonical Git blob bytes into an ignored,
create-only staging root. The publisher requires a clean pushed checkout and
local/tracking/FETCH_HEAD/direct-remote equality. Before any write, it checks
every active and retired authenticated FTPS identity and all unoccupied staging
names. It publishes only registered files, retires only exact registered
historical files, publishes `/.well-known/site-release.json` last, verifies
exact HTTPS bytes and private-path denial, and writes one append-only terminal
receipt. A terminal operation is never retried or repaired; any later action
requires a new identity and manifest.
