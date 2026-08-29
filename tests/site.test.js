"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const root = path.resolve(__dirname, "..");
const read = (relativePath) =>
  fs.readFileSync(path.join(root, ...relativePath.split("/")), "utf8");
const json = (relativePath) => JSON.parse(read(relativePath));

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
  const site = json(".well-known/mirust-site.json");
  const inventory = json(".well-known/ai-ready-route-inventory.json");
  const release = json(".well-known/site-release.json");
  const history = json(".well-known/site-release-history.json");
  assert.equal(site.version, "2.6.0");
  assert.equal(inventory.version, "2.6.0");
  assert.equal(release.release_id, "mirust.com@2.6.0");
  assert.equal(history.current_release_id, release.release_id);
  assert.equal(history.releases[0].release_id, release.release_id);
  assert.equal(history.releases.length, 1);
});

test("the public constellation is exact and honest", () => {
  const site = json(".well-known/mirust-site.json");
  assert.deepEqual(
    site.current_lanes.map((lane) => lane.name),
    [
      "TinyRustLM.com",
      "TinyRustLM.MiRust.com",
      "MiniModel.org",
      "MiniModel.MiRust.com",
    ],
  );
  assert.equal(site.source_policy.current_tinyrustlm_authority_count, 1);
  assert.equal(site.source_policy.stale_tree_union_merge, false);
  assert.equal(site.source_policy.runtime_compatibility_paths, 0);
  assert.equal(read("llms.txt").includes("GGUF.MiRust.com"), false);
  assert.match(
    read("llms-full.txt"),
    /Historical implementations and superseded metadata contracts exist only in\s+Git history/,
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
  assert.match(builder, /"workspace\.uai": \{ status: "present"/);
  assert.match(builder, /prohibited_public_paths/);
  assert.doesNotMatch(
    publicPaths[0],
    /workspace\.uai|\.uai\/|deploy\/|tests\/|tools\//,
  );
  assert.match(
    read("README-MIRUST-ROOT-DISCOVERY.txt"),
    /not a complete WordPress source tree/,
  );
});

test("source authority policy fails closed", () => {
  const taboo = read(".uai/taboo.uai");
  for (const marker of [
    "Do not create, adopt, maintain, edit, build, test, release, deploy, or describe more than one authoritative TinyRustLM.com source checkout",
    "Fail closed before editing, building, testing, committing, releasing, or deploying",
    "Every workspace registry, read order, build recipe, CI workflow, release command, and deployment manifest must name only the canonical authority",
    "Do not pull both trees forward, merge stale branches wholesale",
    "Historical source belongs only in Git history",
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
    (sitemap.match(/<lastmod>2026-08-29<\/lastmod>/g) || []).length,
    9,
  );
  assert.doesNotMatch(
    sitemap,
    /project-constellation|implementation|model-breeding/,
  );
});
