"use strict";

const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const root = path.resolve(__dirname, "..");
const read = (relativePath) =>
  fs.readFileSync(path.join(root, ...relativePath.split("/")), "utf8");
const json = (relativePath) => JSON.parse(read(relativePath));
const sha256 = (relativePath) =>
  crypto
    .createHash("sha256")
    .update(fs.readFileSync(path.join(root, ...relativePath.split("/"))))
    .digest("hex");

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

const expectedLanes = [
  { name: "TinyRustLM.com", version: "0.4.1", release_status: "published" },
  {
    name: "TinyRustLM.MiRust.com",
    version: "1.8.2",
    release_status: "published",
  },
  { name: "MiniModel.org", version: "1.1.1", release_status: "published" },
  {
    name: "MiniModel.MiRust.com",
    version: "1.1.0",
    release_status: "published",
  },
];

const superseded = [
  ".well-known/ai-ready-manifest.json",
  ".well-known/ai-ready-manifest.schema.json",
  ".well-known/ai-ready-maturity.json",
  ".well-known/ai-ready-readiness-result.schema.json",
  ".well-known/ai-ready-readiness.json",
  ".well-known/ai-ready-requirements.json",
  ".well-known/ai-ready.json",
];

test("current release identities agree", () => {
  const packageJson = json("package.json");
  const site = json(".well-known/mirust-site.json");
  const inventory = json(".well-known/ai-ready-route-inventory.json");
  const release = json(".well-known/site-release.json");
  const history = json(".well-known/site-release-history.json");
  assert.equal(packageJson.version, "2.6.1");
  assert.equal(site.version, "2.6.1");
  assert.equal(site.release_date, "2026-08-31");
  assert.equal(inventory.version, "2.6.1");
  assert.equal(inventory.updated_utc, "2026-08-31T00:00:00Z");
  assert.equal(release.release_id, "mirust.com@2.6.1");
  assert.equal(release.release_date, "2026-08-31");
  assert.equal(release.status, "published");
  assert.equal(history.current_release_id, release.release_id);
  assert.equal(history.releases[0].release_id, release.release_id);
  assert.equal(history.releases[1].release_id, "mirust.com@2.6.0");
  assert.equal(history.releases.length, 2);

  const releaseMirrors = new Map([
    ["llms.txt", "Current root-discovery release: 2.6.1, dated 2026-08-31."],
    ["llms-full.txt", "Release: `mirust.com@2.6.1`"],
    ["robots.txt", "MiRust.com release 2.6.1"],
    ["README-MIRUST-ROOT-DISCOVERY.txt", "MiRust.com Root Discovery 2.6.1"],
    [".well-known/uaix-talisman.txt", "release: mirust.com@2.6.1"],
  ]);
  for (const [relativePath, marker] of releaseMirrors) {
    assert.ok(read(relativePath).includes(marker), relativePath);
  }
});

test("the public constellation is exact and honest", () => {
  const site = json(".well-known/mirust-site.json");
  assert.deepEqual(
    site.current_lanes.map(({ name, version, release_status }) => ({
      name,
      version,
      release_status,
    })),
    expectedLanes,
  );
  const inventory = json(".well-known/ai-ready-route-inventory.json");
  assert.deepEqual(
    inventory.current_lanes.map(({ name, version, release_status }) => ({
      name,
      version,
      release_status,
    })),
    expectedLanes,
  );
  assert.equal(site.source_policy.current_tinyrustlm_authority_count, 1);
  assert.equal(site.source_policy.stale_tree_union_merge, false);
  assert.equal(site.source_policy.runtime_compatibility_paths, 0);
  assert.equal(read("llms.txt").includes("GGUF.MiRust.com"), false);
  assert.match(
    read("llms-full.txt"),
    /Historical implementations and superseded metadata contracts exist only in\s+Git history/,
  );
  assert.match(
    site.current_lanes.find((lane) => lane.name === "MiniModel.org")
      .claim_boundary,
    /No composition or peer is available until exact current evidence enters the empty feeds/,
  );
});

test("every human lane mirror uses only published downstream identities", () => {
  for (const relativePath of [
    "llms.txt",
    "llms-full.txt",
    ".well-known/uaix-talisman.txt",
  ]) {
    const value = read(relativePath);
    assert.match(value, /tinyrustlm\.com[\s\S]*0\.4\.1/i, relativePath);
    assert.match(value, /tinyrustlm\.mirust\.com[\s\S]*1\.8\.2/i, relativePath);
    assert.doesNotMatch(value, /\b(?:0\.3\.0|1\.8\.1)\b/, relativePath);
  }

  const publicText = publicPaths.map(read).join("\n");
  assert.doesNotMatch(publicText, /\b(?:0\.5\.0|1\.8\.3)\b/);
  assert.match(
    read("llms-full.txt"),
    /composition catalog and peer feed remain empty until exact evidence exists/,
  );
});

test("superseded metadata is absent from current source", () => {
  for (const relativePath of superseded) {
    assert.equal(fs.existsSync(path.join(root, relativePath)), false, relativePath);
  }
  assert.equal(
    fs.existsSync(path.join(root, ".well-known/ai-ready-route-inventory.json")),
    true,
  );
  assert.equal(fs.existsSync(path.join(root, ".well-known/mirust-site.json")), true);
});

test("private and deployment files are outside the public closure", () => {
  const builder = read("tools/build-site-deployment-manifest.js");
  const publicPaths = builder.match(/const publicPaths = \[[\s\S]*?\];/);
  assert.ok(publicPaths);
  assert.match(builder, /historicalManifest\.retired_paths/);
  assert.match(builder, /historicalReceipt\.retired_paths/);
  assert.match(builder, /retiredBefore\.set\(relativePath, \{ status: "absent" \}\)/);
  assert.match(builder, /prohibited_public_paths/);
  assert.match(builder, /fs\.mkdirSync\(stagingParent, \{ recursive: true \}\)/);
  assert.match(builder, /fs\.mkdirSync\(stagingRoot, \{ recursive: false \}\)/);
  assert.doesNotMatch(
    publicPaths[0],
    /workspace\.uai|\.uai\/|deploy\/|tests\/|tools\//,
  );
  assert.match(
    read("README-MIRUST-ROOT-DISCOVERY.txt"),
    /not a complete WordPress source tree/,
  );
});

test("the next deployment identity is create-only and 2.6.0 evidence is immutable", () => {
  const builder = read("tools/build-site-deployment-manifest.js");
  const publisher = read("tools/deploy-site.ps1");
  const historicalManifest = json("deploy/site-deployment-manifest.v1.json");
  const historicalReceipt = json(
    "deploy/receipts/site-deployment-mirust-root-discovery-2.6.0-20260829-v1.json",
  );

  assert.equal(
    sha256("deploy/site-deployment-manifest.v1.json"),
    "e76ecddc240df8b29d80d7f00fb12d97c7d4cbf5b3c134e7114577db523c144a",
  );
  assert.equal(
    sha256(
      "deploy/receipts/site-deployment-mirust-root-discovery-2.6.0-20260829-v1.json",
    ),
    "ed4c2ba6817a8ca78c544bd5b474c97b8fcb537fafa8e4c4a1aa052ebe5f79fa",
  );
  assert.equal(historicalManifest.version, "2.6.0");
  assert.equal(historicalReceipt.status, "published-and-readback-verified");
  assert.equal(historicalReceipt.manifest_sha256, sha256("deploy/site-deployment-manifest.v1.json"));

  for (const value of [builder, publisher]) {
    assert.match(value, /mirust-root-discovery-2\.6\.1-20260831-v1/);
    assert.match(value, /site-deployment-manifest-2\.6\.1\.v1\.json/);
  }
  assert.match(builder, /Immutable 2\.6\.0 deployment manifest bytes changed/);
  assert.match(builder, /Immutable 2\.6\.0 deployment receipt bytes changed/);
  assert.match(publisher, /status = "already-retired"/);
});

test("source authority policy fails closed", () => {
  const taboo = read(".uai/taboo.uai");
  for (const marker of [
    "Do not create, adopt, maintain, edit, build, test, release, deploy, or describe more than one authoritative TinyRustLM.com source checkout",
    "Fail closed before editing, building, testing, committing, releasing, or deploying",
    "Every workspace registry, read order, build recipe, CI workflow, release command, and deployment manifest must name only the canonical authority",
    "Do not pull both trees forward, merge stale branches wholesale",
    "Historical source belongs only in Git history",
    "Any committed change to a declared public artifact invalidates deployed-current status",
  ]) {
    assert.ok(taboo.includes(marker), marker);
  }
});

test("discovery files expose no stale single-file model contract", () => {
  const publicText = [
    "llms.txt",
    "llms-full.txt",
    ".well-known/uaix-talisman.txt",
    ".well-known/ai-ready-route-inventory.json",
    ".well-known/mirust-site.json",
  ]
    .map(read)
    .join("\n");
  assert.doesNotMatch(publicText, /\.slm\b/i);
  assert.doesNotMatch(publicText, /absorbed legacy runtime/i);
  assert.doesNotMatch(publicText, /future native GGUF parser/i);
});

test("root sitemap is current and bounded", () => {
  const sitemap = read("mirust-public-sitemap.xml");
  assert.match(sitemap, /^<\?xml version="1\.0" encoding="UTF-8"\?>/);
  assert.equal((sitemap.match(/<url>/g) || []).length, 9);
  assert.equal(
    (sitemap.match(/<lastmod>2026-08-31<\/lastmod>/g) || []).length,
    9,
  );
  assert.doesNotMatch(
    sitemap,
    /project-constellation|implementation|model-breeding/,
  );
});
