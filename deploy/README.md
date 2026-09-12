# MiRust.com Root-Discovery Publication

This repository publishes only the exact files in the deployment manifest. It
never uploads, merges, clears, or treats the live WordPress tree as source.

```powershell
node tools/build-site-deployment-manifest.js <content-commit>
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/deploy-site.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/deploy-site.ps1 -Publish
```

The publisher command without `-Publish` is a local validation; its
operation-owned local snapshot is removed before success. During source review only,
`-AllowUncommittedValidation` admits changes limited to the publisher,
authority descriptor, documentation, and publisher tests. That switch is
rejected when `-Publish` is present. Publication always requires a clean,
remote-exact checkout.

Before reading Git or creating a directory, the manifest generator runs the
canonical TinyRustLM source-authority verifier in clean, remote-exact mode. It
then reconstructs canonical Git blob bytes into an ignored,
create-only `2.6.1` staging root and writes only
`deploy/site-deployment-manifest-2.6.1.v1.json`. It first verifies the immutable
`2.6.0` manifest and terminal receipt byte identities, then derives every
authenticated current-file before-state from that preserved evidence. The
historical `2.6.0` manifest and receipt are never overwritten.

Until a terminal `2.6.1` publication receipt and exact HTTPS readback exist,
`2.6.0` remains the currently published MiRust root-discovery release. Prepared
source, a content commit, or a generated manifest is not deployment evidence.

`deploy/publication-authority-2.6.1.v1.json` is public-safe target authority. It
contains no credential, username, or private path. It binds the immutable C1
content commit, its single-file C2 manifest commit, the manifest bytes, the
public origin, exact FileZilla profile name, explicit-FTPS host and port, the
stable remote-root sentinel, the exact 2.6.0 predecessor closure, and the
canonical source verifier's repository, branch, origin, commit, tree, blob,
length, and SHA-256 identity.

Publication first runs that same canonical verifier with `--require-clean
--require-remote-exact`, before HTTP, credential, or FTPS access. It binds the
exact source, manifest, publisher, builder, verifier, Node, and Git identities
into an operation-owned sealed snapshot and rechecks them before write
admission and marker publication. A create-only, process-held publication lease
under the ignored staging root excludes a second invocation from owning the
operation or its terminal receipt before credentials or network state are
read. After lease acquisition, the credential profile must match
`ftp.mirust.com`, profile `MiRust.com`, and explicit-FTPS port 21. The
publisher then reads and verifies the unchanged
`/.well-known/security.txt` root sentinel and proves the 2.6.0 public
predecessor over bounded no-cache HTTPS. Every active FTPS identity, all twelve
historical absences, every operation auxiliary absence, and a second sentinel
read must pass before mutation helpers are enabled. A listing omission is
accepted as absence only when bounded `LIST`, `SIZE`, and download probes agree;
mixed or inaccessible evidence fails closed.

It publishes only registered files. The release-wide journal retains the exact
observed predecessor bytes locally, so operation auxiliary files are removed
before `/.well-known/site-release.json` is promoted. The marker promotion is
therefore the last successful remote mutation. Exact HTTPS bytes,
private-path denial, the root sentinel, and all final remote identities are
then checked read-only. Any failure restores the marker first, restores every
changed path in reverse order, and verifies the full active and retired
before-state. Only after snapshot cleanup and publication-lease release does
the owner commit one append-only terminal receipt. A lease loser cannot write
that receipt. A terminal operation is never retried or repaired; any later
action requires a new identity and manifest.

## Local Tests

Run `npm test` for every repository test, or `npm run test:deployment-custody`
for the publication-safety gate. The latter also runs
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/deployment-custody.test.ps1`.
These tests cover directory-list identity, first-file journaling, injected
upload/promotion failures, exact rollback, and marker-last completion with
mocked transport. They read no credentials, contact no network, and do not
inspect sibling repositories or external evidence. Bounded local custody
fixtures are removed after use; no deployment candidate is staged.
Passing local tests does not establish source authority, remote equality,
target custody, publication, or live readback.
