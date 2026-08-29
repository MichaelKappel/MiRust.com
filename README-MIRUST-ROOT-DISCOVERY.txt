MiRust.com Root Discovery 2.6.0

This repository is the bounded source for named public root-discovery files.
It is not a complete WordPress source tree and must never be uploaded as one.

Publication is allowed only from the immutable Git content commit named by
deploy/site-deployment-manifest.v1.json, through tools/deploy-site.ps1. The
publisher authenticates every remote before-state, changes only manifest
members, retires only exact registered files, publishes the release marker
last, and writes one append-only terminal receipt.

Private .uai files, workspace.uai, deployment tools, tests, receipts, staging,
credentials, and historical ZIP packages are not public release members.
Historical implementations and superseded metadata contracts exist only in
Git history. Current source and production paths contain no legacy reader,
validator, schema, fallback, compatibility alias, or migration.
