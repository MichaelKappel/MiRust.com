"use strict";

const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const test = require("node:test");
const vm = require("node:vm");

const root = path.resolve(__dirname, "..");
const authorityPath = path.join(root, "deploy", "publication-authority-2.6.1.v1.json");
const manifestPath = path.join(root, "deploy", "site-deployment-manifest-2.6.1.v1.json");

function sha256(bytes) {
  return crypto.createHash("sha256").update(bytes).digest("hex");
}

test("publication authority is public-safe and binds immutable C1/C2 inputs", () => {
  const bytes = fs.readFileSync(authorityPath);
  const authority = JSON.parse(bytes);
  assert.equal(sha256(bytes), "0a20b3073d6bb0977589d3469892370369fb8b8579ed6bd76f4ed74b18e4fb97");
  assert.equal(authority.contains_credentials, false);
  assert.equal(authority.contains_private_paths, false);
  assert.equal(authority.transport.host, "ftp.mirust.com");
  assert.equal(authority.transport.port, 21);
  assert.equal(authority.transport.profile_name, "MiRust.com");
  assert.equal(authority.candidate.content_commit, "2c5763655e1ad23f812efe40365cae62a74562dd");
  assert.equal(authority.candidate.manifest_commit, "cbefce77356a59de044f42a98dc76a2f5f557173");
  assert.equal(authority.source_verifier.repository, "TinyRustLM.com");
  assert.equal(authority.source_verifier.relative_repository_path, "../TinyRustLM.com");
  assert.equal(authority.source_verifier.commit, "4f3b36fbba69d9c875a50069e866fcf673158378");
  assert.equal(authority.source_verifier.tree, "59789a32cb4f6f9e9c81f1311039f5005fb154fb");
  assert.equal(authority.source_verifier.blob, "db3ad2184e58cbb4584eb75c8d0062494ebe06d8");
  assert.equal(authority.source_verifier.bytes, 144650);
  assert.equal(authority.source_verifier.sha256, "d8005c826d3e477787a79ad4f25fbd3cf25bd37cb810b3b2bf708667e2290d47");
  assert.equal(sha256(fs.readFileSync(manifestPath)), authority.candidate.manifest_sha256);
  assert.equal(fs.existsSync(path.join(root, "deploy", "receipts", "site-deployment-mirust-root-discovery-2.6.1-20260831-v1.json")), false);

  const serialized = JSON.stringify(authority);
  assert.doesNotMatch(serialized, /"(?:password|credential|username|user_name)"\s*:/i);
  assert.doesNotMatch(serialized, /[A-Za-z]:\\|\/home\/|\/Users\//);
});

test("PowerShell publisher rejects hostile target and predecessor states", () => {
  const result = spawnSync(
    "powershell.exe",
    [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      path.join(__dirname, "deployment-custody.test.ps1"),
    ],
    { cwd: root, encoding: "utf8" },
  );
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  assert.match(result.stdout, /RESULT 44\/44 deployment-custody checks passed/);
});

test("publisher holds exact custody from source gate through marker proof", () => {
  const source = fs.readFileSync(path.join(root, "tools", "deploy-site.ps1"), "utf8");
  const main = source.slice(source.indexOf("if ($MyInvocation.InvocationName"));
  const authority = main.indexOf("Read-ExactJsonFile");
  const gate = main.indexOf("Invoke-CanonicalSourceAuthorityGate -Authority $authority -RequireRemoteExact:$Publish");
  const snapshot = main.indexOf("New-OwnedDeploymentSnapshot");
  const predecessor = main.indexOf("Assert-PublicPredecessor -Authority $authority");
  const credential = main.indexOf("Get-CredentialProfile -Path $FileZillaProfilePath");
  const sentinel = main.indexOf("Authenticated remote-root sentinel");
  const lease = main.indexOf("New-ExclusivePublicationLease");
  const admission = main.indexOf("$script:remoteWritesAdmitted = $true");
  const mutation = main.indexOf("Publish-ManifestFile -File $file");
  const marker = main.indexOf("Publish-ManifestFile -File $marker");
  const readback = main.indexOf("Assert-PostPublicationHttps");
  const finalize = main.indexOf("Complete-ReleaseTransaction -Journal $journal");
  const snapshotCleanup = main.lastIndexOf("Remove-OwnedDeploymentSnapshot -Snapshot $snapshot");
  const leaseRelease = main.lastIndexOf("Remove-ExactOwnedPublicationLease -Lease $lease");
  const ownerGuard = main.indexOf("if (-not $leaseOwned)");
  const receipt = main.lastIndexOf("Write-CreateOnlyReceipt -Receipt $receipt");
  assert.ok(authority >= 0 && authority < gate && gate < snapshot && snapshot < lease);
  assert.ok(lease < credential && credential < sentinel && sentinel < predecessor);
  assert.ok(predecessor < admission && admission < mutation && mutation < marker);
  assert.ok(marker < readback && readback < finalize);
  assert.ok(finalize < snapshotCleanup && snapshotCleanup < leaseRelease && leaseRelease < ownerGuard && ownerGuard < receipt);
  assert.match(main, /if \(\$Publish -and \$AllowUncommittedValidation\)/);
  assert.match(source, /Remote mutation was attempted before target custody admission/);
  assert.match(source, /Invoke-ReleaseRollback -Journal \$journal/);
  assert.match(source, /Assert-ManifestRemoteBeforeState -Manifest \$manifest -Nonce \$nonce/);
  assert.match(source, /Remote LIST, SIZE, and download evidence is conflicting or ambiguous/);
  assert.match(source, /Pinned source-authority verifier byte identity drifted/);
  assert.doesNotMatch(main.slice(marker, receipt), /(?:Send|Move|Remove)-Remote(?:Bytes|File|Directory)/);
  assert.equal((main.match(/Write-CreateOnlyReceipt -Receipt \$receipt/g) || []).length, 1);

  const publishFunction = source.slice(
    source.indexOf("function Publish-ManifestFile"),
    source.indexOf("function Restore-DeploymentJournalEntry"),
  );
  const stageMutation = publishFunction.indexOf("Send-RemoteBytesOnce");
  const removePredecessor = publishFunction.indexOf("Remove-RemoteFileExact");
  const markerPromotion = publishFunction.indexOf("Move-RemoteFileExact");
  assert.ok(stageMutation >= 0 && stageMutation < removePredecessor && removePredecessor < markerPromotion);
  assert.doesNotMatch(
    publishFunction.slice(markerPromotion + "Move-RemoteFileExact".length),
    /(?:Send|Move|Remove)-Remote(?:Bytes|File|Directory)/,
  );
});

test("manifest builder rejects a revision mismatch before executing the verifier", () => {
  const builderPath = path.join(root, "tools", "build-site-deployment-manifest.js");
  const calls = [];
  const fixtureFs = {
    readFileSync(file) {
      assert.equal(file, authorityPath, "only local authority bytes may be read");
      return fs.readFileSync(file);
    },
    lstatSync() {
      return { isSymbolicLink: () => false };
    },
  };
  const fixtureChild = {
    execFileSync(file, args) {
      calls.push({ file, args });
      assert.equal(file, "git", "verifier must not execute");
      if (args.includes("ls-remote")) return "0000000000000000000000000000000000000000\trefs/heads/codex/model-acquisition-v2\n";
      if (args.includes("symbolic-ref")) return "hostile-branch\n";
      throw new Error("unexpected Git query");
    },
  };
  assert.throws(() => vm.runInNewContext(fs.readFileSync(builderPath, "utf8"), {
    __dirname: path.dirname(builderPath),
    process: { argv: [process.execPath, builderPath, "poisoned-later-input"] },
    require(name) {
      if (name === "node:fs") return fixtureFs;
      if (name === "node:child_process") return fixtureChild;
      return require(name);
    },
  }, { filename: builderPath, timeout: 5000 }), /not pinned, clean, and remote-exact/);
  assert.equal(calls.length, 2);
  assert.ok(calls.some((call) => call.args.includes("ls-remote")));
  assert.ok(calls.some((call) => call.args.includes("symbolic-ref")));
});

test("manifest builder pins authority and verifier bytes before any output write", () => {
  const source = fs.readFileSync(path.join(root, "tools", "build-site-deployment-manifest.js"), "utf8");
  const authority = source.indexOf("readPublicationAuthority()");
  const gate = source.indexOf("invokeCanonicalSourceAuthorityGate(publicationAuthority)");
  const verifierHash = source.indexOf("sha256(bytes) !== pin.sha256");
  const firstWrite = source.indexOf("fs.mkdirSync(path.dirname(outputPath)");
  assert.ok(authority >= 0 && authority < gate && gate < firstWrite);
  assert.ok(verifierHash >= 0 && verifierHash < firstWrite);
  assert.match(source, /gitIn\(sourceRepository, \["rev-parse", `HEAD:\$\{pin\.path\}`\]\) !== pin\.blob/);
  assert.match(source, /status", "--porcelain", "--untracked-files=all/);
});
