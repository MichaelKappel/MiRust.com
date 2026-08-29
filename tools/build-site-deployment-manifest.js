#!/usr/bin/env node
"use strict";

const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");

const repositoryRoot = path.resolve(__dirname, "..");
const contentCommit = process.argv[2];
const outputPath = path.resolve(
  repositoryRoot,
  process.argv[3] || "deploy/site-deployment-manifest.v1.json",
);
const version = "2.6.0";
const operationId = "mirust-root-discovery-2.6.0-20260829-v1";
const stagingRoot = path.join(repositoryRoot, "deploy", "staging", version);

if (!/^[0-9a-f]{40}$/.test(contentCommit || "")) {
  throw new Error("Usage: node tools/build-site-deployment-manifest.js <40-character-content-commit> [output]");
}
if (fs.existsSync(stagingRoot) || fs.existsSync(outputPath)) {
  throw new Error("Create-only deployment staging or manifest identity is already occupied");
}

function git(args, encoding = "utf8") {
  return execFileSync("git", args, {
    cwd: repositoryRoot,
    encoding,
    maxBuffer: 8 * 1024 * 1024,
  });
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

const expectedBefore = new Map(Object.entries({
  "llms.txt": { status: "present", bytes: 1855, sha256: "a7494a3a7e2e60d99bba2c71199f6b8bcac0f4d6fc7385cfc9cf274d6b0de2fb" },
  "llms-full.txt": { status: "present", bytes: 3089, sha256: "2972643db2b7f639e52dbc0c6df8527d83c40c94a0e4ed52b9668d9ec2cd6046" },
  "robots.txt": { status: "present", bytes: 337, sha256: "980bb30057d7d072ea02c3b8d4edc0011489119247eced14163c0d8b6a0e0e7e" },
  "mirust-public-sitemap.xml": { status: "present", bytes: 1136, sha256: "c357f0a7e248100c2c6f7d2e426ca9ef3928e1b8ecbe81183e8dac310bc44588" },
  "README-MIRUST-ROOT-DISCOVERY.txt": { status: "present", bytes: 482, sha256: "4f4f9669acb33b516c29363892d76357be659bf89bb2842048ca508507fdd0bd" },
  ".well-known/security.txt": { status: "present", bytes: 113, sha256: "db3029d15deb26062dbf00e2aa966032e0cf31951222fe7c49e19847295fcb9f" },
  ".well-known/uaix-talisman.txt": { status: "present", bytes: 1644, sha256: "5ce344306ea04d98d87f3f43b9f916879537b068d41fdec18949ce656bf0286a" },
  ".well-known/ai-ready-route-inventory.json": { status: "present", bytes: 3177, sha256: "af204ddad94a6dd4ddc4fab16bab7bf170b4a39d1c45a2713dbe764582aa1854" },
  ".well-known/mirust-site.json": { status: "present", bytes: 2940, sha256: "ff25f7684d8e8e5c255dd40cefac74fa2bdb7f1116136b2890a23a00303409d9" },
  ".well-known/site-release-history.json": { status: "absent" },
  ".well-known/site-release.json": { status: "absent" },
}));

const retiredBefore = new Map(Object.entries({
  "workspace.uai": { status: "present", bytes: 2106, sha256: "5bb9bc2a4bbce0eda3169d005ca50eedb5ffa6097ff971bf921283ab1e523ecc" },
  "mirust-root-discovery-2.0.1.zip": { status: "present", bytes: 16928, sha256: "14799d02605c203c444abb57fe6bb269bc886ee59d37808dceb7abb96d1f67f1" },
  "mirust-root-discovery-2.2.0.zip": { status: "present", bytes: 11203, sha256: "529c5499f3cf7ff969cacc2441c31d3058d6957aa71e2bdfee5528ddeab62884" },
  "mirust-root-discovery-2.2.1.zip": { status: "present", bytes: 10879, sha256: "1ca2fc14505eaf1ecf78ec3c599acd535c64ab18a9bd52638519abeb096aa49e" },
  "mirust-root-discovery-2.3.0.zip": { status: "present", bytes: 13780, sha256: "da6aadd4d718282647dec8698a455837a7069ee94e7d132fcb692d14860eab9e" },
  ".well-known/ai-ready-manifest.json": { status: "present", bytes: 7883, sha256: "913c3842a75b33791bbd8b618b61163e65bdb07467a2a4c4e2e55d99f770d8e9" },
  ".well-known/ai-ready-manifest.schema.json": { status: "present", bytes: 303, sha256: "68e3737f78c723bd4fb7f9311aa9eab1ad6041ebf22730793f83fbca38144487" },
  ".well-known/ai-ready-maturity.json": { status: "present", bytes: 600, sha256: "c7ba42c16de8b4b9928685a081c63bbc7829c022c50d9ba4cb95f5f921c448a1" },
  ".well-known/ai-ready-readiness-result.schema.json": { status: "present", bytes: 351, sha256: "4ddd2337b16cd9b734adee5b3d38e56b39d4595f51e04aa34328ff94b42c4451" },
  ".well-known/ai-ready-readiness.json": { status: "present", bytes: 590, sha256: "f13290f63f4c6a70542f2f2645a3a312b55e296dfbcc6a34add9cbf807b15166" },
  ".well-known/ai-ready-requirements.json": { status: "present", bytes: 407, sha256: "9d0aab4c6e002b9fdc3437f73ec1f8d063bcefd2d6781b029b33c6aacf3238a8" },
  ".well-known/ai-ready.json": { status: "present", bytes: 7883, sha256: "913c3842a75b33791bbd8b618b61163e65bdb07467a2a4c4e2e55d99f770d8e9" },
}));

git(["cat-file", "-e", `${contentCommit}^{commit}`]);
const sourceTree = git(["rev-parse", `${contentCommit}^{tree}`]).trim();
const tracked = new Set(
  git(["ls-tree", "-r", "--name-only", contentCommit])
    .split(/\r?\n/)
    .filter(Boolean),
);

for (const relativePath of publicPaths) {
  if (!tracked.has(relativePath)) {
    throw new Error(`Public release member is not tracked: ${relativePath}`);
  }
}
for (const retiredPath of retiredBefore.keys()) {
  if (retiredPath.startsWith(".well-known/") && tracked.has(retiredPath)) {
    throw new Error(`Superseded metadata remains in current source: ${retiredPath}`);
  }
}

fs.mkdirSync(stagingRoot, { recursive: false });
const files = publicPaths.map((relativePath) => {
  const committed = git(["show", `${contentCommit}:${relativePath}`], null);
  const stagedPath = path.join(stagingRoot, ...relativePath.split("/"));
  fs.mkdirSync(path.dirname(stagedPath), { recursive: true });
  fs.writeFileSync(stagedPath, committed);
  return {
    path: relativePath,
    bytes: committed.length,
    sha256: crypto.createHash("sha256").update(committed).digest("hex"),
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
  release_date: "2026-08-29",
  source_commit: contentCommit,
  source_tree: sourceTree,
  transport_profile: "MiRust.com",
  receipt_path: `deploy/receipts/site-deployment-${operationId}.json`,
  files,
  retired_paths: retiredPaths,
  route_smokes: [
    { path: "/", contains: "MiRust" },
    { path: "/llms.txt", contains: "Current root-discovery release: 2.6.0" },
    { path: "/.well-known/mirust-site.json", contains: "mirust.com@2.6.0" },
    { path: "/.well-known/site-release.json", contains: "mirust.com@2.6.0" },
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
  `${outputPath}\n${files.length} files\n${retiredPaths.length} retired files\n${stagingRoot}\n`,
);
