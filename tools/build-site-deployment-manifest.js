#!/usr/bin/env node
"use strict";

const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");

const repositoryRoot = path.resolve(__dirname, "..");
const contentCommit = process.argv[2];
const version = "2.6.1";
const releaseId = "mirust.com@2.6.1";
const releaseDate = "2026-08-31";
const operationId = "mirust-root-discovery-2.6.1-20260831-v1";
const manifestRelativePath = "deploy/site-deployment-manifest-2.6.1.v1.json";
const outputPath = path.join(repositoryRoot, ...manifestRelativePath.split("/"));
const stagingRoot = path.join(repositoryRoot, "deploy", "staging", version);
const stagingParent = path.dirname(stagingRoot);
const publicationAuthorityPath = path.join(
  repositoryRoot,
  "deploy",
  "publication-authority-2.6.1.v1.json",
);
const publicationAuthoritySha256 =
  "0a20b3073d6bb0977589d3469892370369fb8b8579ed6bd76f4ed74b18e4fb97";

const priorManifest = Object.freeze({
  path: "deploy/site-deployment-manifest.v1.json",
  sha256: "e76ecddc240df8b29d80d7f00fb12d97c7d4cbf5b3c134e7114577db523c144a",
  operationId: "mirust-root-discovery-2.6.0-20260829-v1",
});
const priorReceipt = Object.freeze({
  path: "deploy/receipts/site-deployment-mirust-root-discovery-2.6.0-20260829-v1.json",
  sha256: "ed4c2ba6817a8ca78c544bd5b474c97b8fcb537fafa8e4c4a1aa052ebe5f79fa",
});

function gitIn(repository, args) {
  return execFileSync("git", ["-C", repository, ...args], {
    encoding: "utf8",
    maxBuffer: 1024 * 1024,
    windowsHide: true,
  }).trim();
}

function readPublicationAuthority() {
  const bytes = fs.readFileSync(publicationAuthorityPath);
  if (sha256(bytes) !== publicationAuthoritySha256) {
    throw new Error("Publication authority byte identity is invalid");
  }
  let authority;
  try {
    authority = JSON.parse(bytes.toString("utf8"));
  } catch {
    throw new Error("Publication authority is malformed");
  }
  const verifier = authority?.source_verifier;
  if (
    verifier?.repository !== "TinyRustLM.com" ||
    verifier.relative_repository_path !== "../TinyRustLM.com" ||
    verifier.branch !== "codex/model-acquisition-v2" ||
    verifier.remote_name !== "origin" ||
    verifier.remote_url !== "https://github.com/MichaelKappel/TinyRustLM.com.git" ||
    !/^[0-9a-f]{40}$/.test(verifier.commit || "") ||
    !/^[0-9a-f]{40}$/.test(verifier.tree || "") ||
    verifier.path !== "tinyrustlm/tools/verify-single-source-authority.js" ||
    !/^[0-9a-f]{40}$/.test(verifier.blob || "") ||
    !Number.isSafeInteger(verifier.bytes) ||
    verifier.bytes < 1 ||
    !/^[0-9a-f]{64}$/.test(verifier.sha256 || "")
  ) {
    throw new Error("Publication authority has an invalid source-verifier pin");
  }
  return authority;
}

function assertDirectNonSymlinkPath(target, label) {
  const resolved = path.resolve(target);
  const parsed = path.parse(resolved);
  let current = parsed.root;
  for (const segment of resolved.slice(parsed.root.length).split(path.sep).filter(Boolean)) {
    current = path.join(current, segment);
    const stat = fs.lstatSync(current);
    if (stat.isSymbolicLink()) {
      throw new Error(`${label} contains a symbolic link or junction`);
    }
  }
  return resolved;
}

function invokeCanonicalSourceAuthorityGate(authority) {
  const pin = authority.source_verifier;
  const sourceRepository = assertDirectNonSymlinkPath(
    path.resolve(repositoryRoot, pin.relative_repository_path),
    "Canonical source-authority repository",
  );
  const expectedRepository = path.resolve(repositoryRoot, "..", "TinyRustLM.com");
  const sourceAuthorityVerifier = assertDirectNonSymlinkPath(
    path.resolve(sourceRepository, ...pin.path.split("/")),
    "Canonical source-authority verifier",
  );
  if (sourceRepository.toLowerCase() !== expectedRepository.toLowerCase()) {
    throw new Error("Canonical source-authority repository path is invalid");
  }

  const directRemoteLine = gitIn(sourceRepository, [
    "ls-remote",
    "--refs",
    pin.remote_name,
    `refs/heads/${pin.branch}`,
  ]);
  const directRemote = directRemoteLine.split(/\s+/)[0];
  if (
    gitIn(sourceRepository, ["symbolic-ref", "--quiet", "--short", "HEAD"]) !== pin.branch ||
    gitIn(sourceRepository, ["remote", "get-url", pin.remote_name]) !== pin.remote_url ||
    gitIn(sourceRepository, ["rev-parse", "HEAD"]) !== pin.commit ||
    gitIn(sourceRepository, ["rev-parse", "HEAD^{tree}"]) !== pin.tree ||
    gitIn(sourceRepository, ["rev-parse", `HEAD:${pin.path}`]) !== pin.blob ||
    gitIn(sourceRepository, ["rev-parse", "@{upstream}"]) !== pin.commit ||
    directRemote !== pin.commit ||
    gitIn(sourceRepository, ["status", "--porcelain", "--untracked-files=all"]) !== ""
  ) {
    throw new Error("Canonical source-authority verifier is not pinned, clean, and remote-exact");
  }

  const descriptor = fs.openSync(sourceAuthorityVerifier, "r");
  let stdout;
  try {
    const stat = fs.fstatSync(descriptor);
    const bytes = fs.readFileSync(descriptor);
    if (!stat.isFile() || stat.size !== pin.bytes || bytes.length !== pin.bytes || sha256(bytes) !== pin.sha256) {
      throw new Error("Pinned source-authority verifier byte identity drifted");
    }
    stdout = execFileSync(
      process.execPath,
      [sourceAuthorityVerifier, "--require-clean", "--require-remote-exact"],
      {
        cwd: path.dirname(path.dirname(path.dirname(sourceAuthorityVerifier))),
        encoding: "utf8",
        maxBuffer: 1024 * 1024,
        windowsHide: true,
      },
    );
  } catch {
    throw new Error("Canonical source-authority verification failed");
  } finally {
    fs.closeSync(descriptor);
  }

  let result;
  try {
    result = JSON.parse(stdout);
  } catch {
    throw new Error("Canonical source-authority verifier returned invalid evidence");
  }
  if (
    result?.verdict !== "pass" ||
    result.canonicalLayoutAvailable !== true ||
    result.localScanPerformed !== true
  ) {
    throw new Error("Canonical source-authority verification did not pass");
  }
}

const publicationAuthority = readPublicationAuthority();
invokeCanonicalSourceAuthorityGate(publicationAuthority);

if (!/^[0-9a-f]{40}$/.test(contentCommit || "") || process.argv.length !== 3) {
  throw new Error(
    "Usage: node tools/build-site-deployment-manifest.js <40-character-content-commit>",
  );
}
if (fs.existsSync(stagingRoot) || fs.existsSync(outputPath)) {
  throw new Error("Create-only 2.6.1 deployment staging or manifest identity is already occupied");
}

function sha256(bytes) {
  return crypto.createHash("sha256").update(bytes).digest("hex");
}

function git(args, encoding = "utf8") {
  return execFileSync("git", args, {
    cwd: repositoryRoot,
    encoding,
    maxBuffer: 8 * 1024 * 1024,
  });
}

function parseJson(bytes, relativePath) {
  try {
    return JSON.parse(bytes.toString("utf8"));
  } catch {
    throw new Error(`Committed JSON is invalid: ${relativePath}`);
  }
}

const publicPaths = [
  "llms.txt",
  "llms-full.txt",
  "robots.txt",
  "mirust-public-sitemap.xml",
  "README-MIRUST-ROOT-DISCOVERY.txt",
  ".well-known/security.txt",
  ".well-known/uaix-talisman.txt",
  ".well-known/ai-ready-route-inventory.json",
  ".well-known/mirust-site.json",
  ".well-known/site-release-history.json",
  ".well-known/site-release.json",
];

git(["cat-file", "-e", `${contentCommit}^{commit}`]);
const sourceTree = git(["rev-parse", `${contentCommit}^{tree}`]).trim();
const tracked = new Set(
  git(["ls-tree", "-r", "--name-only", contentCommit])
    .split(/\r?\n/)
    .filter(Boolean),
);

for (const relativePath of [
  ...publicPaths,
  "package.json",
  priorManifest.path,
  priorReceipt.path,
]) {
  if (!tracked.has(relativePath)) {
    throw new Error(`Required release member is not tracked: ${relativePath}`);
  }
}

const committedBytes = new Map(
  publicPaths.map((relativePath) => [
    relativePath,
    git(["show", `${contentCommit}:${relativePath}`], null),
  ]),
);
const text = (relativePath) => committedBytes.get(relativePath).toString("utf8");
const json = (relativePath) => parseJson(committedBytes.get(relativePath), relativePath);

const historicalManifestBytes = git(
  ["show", `${contentCommit}:${priorManifest.path}`],
  null,
);
const historicalReceiptBytes = git(
  ["show", `${contentCommit}:${priorReceipt.path}`],
  null,
);
if (sha256(historicalManifestBytes) !== priorManifest.sha256) {
  throw new Error("Immutable 2.6.0 deployment manifest bytes changed");
}
if (sha256(historicalReceiptBytes) !== priorReceipt.sha256) {
  throw new Error("Immutable 2.6.0 deployment receipt bytes changed");
}

const historicalManifest = parseJson(historicalManifestBytes, priorManifest.path);
const historicalReceipt = parseJson(historicalReceiptBytes, priorReceipt.path);
if (
  historicalManifest.operation_id !== priorManifest.operationId ||
  historicalManifest.version !== "2.6.0" ||
  historicalReceipt.operation_id !== priorManifest.operationId ||
  historicalReceipt.version !== "2.6.0" ||
  historicalReceipt.status !== "published-and-readback-verified" ||
  historicalReceipt.manifest_sha256 !== priorManifest.sha256
) {
  throw new Error("Immutable 2.6.0 deployment evidence is semantically inconsistent");
}

const historicalFiles = new Map(
  historicalManifest.files.map((file) => [file.path, file]),
);
const historicalPublishedFiles = new Map(
  historicalReceipt.files.map((file) => [file.path, file]),
);
if (
  historicalFiles.size !== publicPaths.length ||
  historicalPublishedFiles.size !== publicPaths.length
) {
  throw new Error("Immutable 2.6.0 public closure has an unexpected cardinality");
}

const expectedBefore = new Map();
for (const relativePath of publicPaths) {
  const manifestFile = historicalFiles.get(relativePath);
  const receiptFile = historicalPublishedFiles.get(relativePath);
  if (
    !manifestFile ||
    !receiptFile ||
    manifestFile.bytes !== receiptFile.bytes ||
    manifestFile.sha256 !== receiptFile.sha256 ||
    !["published", "already-current"].includes(receiptFile.status)
  ) {
    throw new Error(`Immutable 2.6.0 public identity is inconsistent: ${relativePath}`);
  }
  expectedBefore.set(relativePath, {
    status: "present",
    bytes: manifestFile.bytes,
    sha256: manifestFile.sha256,
  });
}

const historicalRetirements = new Map(
  historicalManifest.retired_paths.map((entry) => [entry.path, entry]),
);
const historicalRetirementResults = new Map(
  historicalReceipt.retired_paths.map((entry) => [entry.path, entry]),
);
if (
  historicalRetirements.size !== 12 ||
  historicalRetirementResults.size !== 12 ||
  historicalManifest.retired_paths[0]?.path !== "workspace.uai"
) {
  throw new Error("Immutable 2.6.0 retirement closure has an unexpected cardinality");
}

const retiredBefore = new Map();
for (const [relativePath, retired] of historicalRetirements) {
  const result = historicalRetirementResults.get(relativePath);
  if (
    !result ||
    result.status !== "retired" ||
    result.bytes !== retired.expected_before.bytes ||
    result.sha256 !== retired.expected_before.sha256
  ) {
    throw new Error(`Immutable 2.6.0 retirement identity is inconsistent: ${relativePath}`);
  }
  if (relativePath.startsWith(".well-known/") && tracked.has(relativePath)) {
    throw new Error(`Superseded metadata remains in current source: ${relativePath}`);
  }
  retiredBefore.set(relativePath, { status: "absent" });
}

const packageJson = parseJson(
  git(["show", `${contentCommit}:package.json`], null),
  "package.json",
);
const site = json(".well-known/mirust-site.json");
const inventory = json(".well-known/ai-ready-route-inventory.json");
const release = json(".well-known/site-release.json");
const history = json(".well-known/site-release-history.json");
const expectedLanes = new Map([
  ["TinyRustLM.com", "0.4.1"],
  ["TinyRustLM.MiRust.com", "1.8.2"],
  ["MiniModel.org", "1.1.1"],
  ["MiniModel.MiRust.com", "1.1.0"],
]);

if (
  packageJson.version !== version ||
  site.version !== version ||
  site.release_id !== releaseId ||
  site.release_date !== releaseDate ||
  inventory.version !== version ||
  inventory.release_id !== releaseId ||
  release.version !== version ||
  release.release_id !== releaseId ||
  release.release_date !== releaseDate ||
  release.last_publish_date !== releaseDate ||
  release.status !== "published" ||
  history.current_release_id !== releaseId ||
  history.releases?.[0]?.release_id !== releaseId ||
  history.releases?.[0]?.release_date !== releaseDate ||
  history.releases?.[0]?.last_publish_date !== releaseDate ||
  history.releases?.[1]?.release_id !== "mirust.com@2.6.0" ||
  history.releases?.length !== 2
) {
  throw new Error("Content commit is not the exact prepared MiRust 2.6.1 release");
}

for (const lanes of [site.current_lanes, inventory.current_lanes]) {
  if (
    !Array.isArray(lanes) ||
    lanes.length !== expectedLanes.size ||
    lanes.map((lane) => lane.name).join("\n") !== [...expectedLanes.keys()].join("\n")
  ) {
    throw new Error("Prepared MiRust 2.6.1 lane closure is incomplete");
  }
  for (const lane of lanes) {
    if (
      expectedLanes.get(lane.name) !== lane.version ||
      lane.release_status !== "published"
    ) {
      throw new Error(`Prepared MiRust 2.6.1 lane identity is invalid: ${lane.name}`);
    }
  }
}

const humanMirrors = [
  text("llms.txt"),
  text("llms-full.txt"),
  text(".well-known/uaix-talisman.txt"),
];
for (const mirror of humanMirrors) {
  if (
    !mirror.includes("0.4.1") ||
    !mirror.includes("1.8.2") ||
    mirror.includes("0.3.0") ||
    mirror.includes("1.8.1")
  ) {
    throw new Error("A human-readable public lane mirror is stale or incomplete");
  }
}
for (const [relativePath, bytes] of committedBytes) {
  const value = bytes.toString("utf8");
  if (/\b(?:0\.5\.0|1\.8\.3)\b/.test(value)) {
    throw new Error(`Prepared downstream source was mislabeled in ${relativePath}`);
  }
}
if (
  !text("llms-full.txt").includes("composition catalog and peer feed remain empty") ||
  !site.current_lanes
    .find((lane) => lane.name === "MiniModel.org")
    ?.claim_boundary.includes("No composition or peer is available")
) {
  throw new Error("The empty-model and empty-peer evidence boundary is missing");
}

fs.mkdirSync(stagingParent, { recursive: true });
fs.mkdirSync(stagingRoot, { recursive: false });
const files = publicPaths.map((relativePath) => {
  const committed = committedBytes.get(relativePath);
  const stagedPath = path.join(stagingRoot, ...relativePath.split("/"));
  fs.mkdirSync(path.dirname(stagedPath), { recursive: true });
  fs.writeFileSync(stagedPath, committed);
  return {
    path: relativePath,
    bytes: committed.length,
    sha256: sha256(committed),
    https_readback_path: `/${relativePath}`,
    expected_before: expectedBefore.get(relativePath),
  };
});

if (
  files.length !== 11 ||
  files.at(-1)?.path !== ".well-known/site-release.json" ||
  files.some((file) => !file.expected_before)
) {
  throw new Error("MiRust public release closure is incomplete");
}
if (
  files.some((file) => file.bytes < 1 || file.bytes > 65536) ||
  files.reduce((sum, file) => sum + file.bytes, 0) > 262144
) {
  throw new Error("MiRust public release closure exceeds its resource bounds");
}

const retiredPaths = [...retiredBefore.entries()].map(([relativePath, before]) => ({
  path: relativePath,
  expected_before: before,
}));

const manifest = {
  schema: "uaix.static_site_create_only_deployment_manifest.v1",
  operation_id: operationId,
  site: "MiRust.com",
  origin: "https://mirust.com",
  version,
  release_date: releaseDate,
  source_commit: contentCommit,
  source_tree: sourceTree,
  transport_profile: "MiRust.com",
  receipt_path: `deploy/receipts/site-deployment-${operationId}.json`,
  files,
  retired_paths: retiredPaths,
  route_smokes: [
    { path: "/", contains: "MiRust" },
    { path: "/llms.txt", contains: "Current root-discovery release: 2.6.1" },
    { path: "/.well-known/mirust-site.json", contains: releaseId },
    { path: "/.well-known/site-release.json", contains: releaseId },
  ],
  prohibited_public_paths: [
    "/.uai/",
    "/workspace.uai",
    "/agent-file-handoff/",
    "/.git/",
  ],
};

fs.mkdirSync(path.dirname(outputPath), { recursive: true });
fs.writeFileSync(outputPath, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
process.stdout.write(
  `${manifestRelativePath}\n${files.length} files\n${retiredPaths.length} enforced historical retirements\ndeploy/staging/${version}\n`,
);
