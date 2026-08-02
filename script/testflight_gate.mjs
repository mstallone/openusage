#!/usr/bin/env node
// Decides whether a release tag needs the iOS TestFlight jobs at all. Every tag carries a new
// marketing version, so every upload puts the app through a fresh Beta App Review and pushes an
// update at every tester — pure overhead when the iOS app is byte-identical to the last release.
// Mac-only releases therefore skip the upload. Ships when ANY of:
//   - FORCE_IOS=1 (the workflow_dispatch override),
//   - there is no previous stable release tag (first release),
//   - iOS-relevant paths changed since the newest valid build distributed to every external
//     TestFlight group — that build's version names its tag; a failed upload or failed external
//     distribution never moves the baseline, so changes cannot be stranded by a later Mac-only
//     tag,
//   - that externally distributed build is older than TESTFLIGHT_MAX_BUILD_AGE_DAYS (default
//     60). TestFlight builds expire 90 days after upload, so an unchanged app must still re-ship
//     periodically or testers' installs go dark; 60 leaves a 30-day margin.
// Writes `ship=true|false` to $GITHUB_OUTPUT and always logs the reason. Any git or App Store
// Connect failure fails the job loudly — rerun it, or force with the workflow_dispatch input.
//
// Required env:
//   RELEASE_TAG          the tag being released, e.g. v0.8.6
//   APPLE_NOTARY_KEY_PATH / APPLE_NOTARY_KEY_ID / APPLE_NOTARY_ISSUER_ID
//                        App Store Connect API key, used only to read what the external groups
//                        last received (and only when the change check alone would skip)
// Optional env:
//   FORCE_IOS=1                     ship regardless of the delta
//   RUNWAY_IOS_BUNDLE_ID            defaults to com.mattstallone.runway.mobile
//   TESTFLIGHT_EXTERNAL_GROUPS      comma-separated external group names (default "External";
//                                   the workflow passes the same value the distribute job uses)
//   TESTFLIGHT_MAX_BUILD_AGE_DAYS   staleness backstop threshold (default 60)

import { appendFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { createClient } from "./lib/appstore_connect.mjs";

const env = (name) => {
  const v = process.env[name];
  if (!v) {
    console.error(`Missing required env: ${name}`);
    process.exit(1);
  }
  return v;
};

const fail = (message, response) => {
  console.error(message);
  if (response) console.error(JSON.stringify(response.json ?? response, null, 2));
  process.exit(1);
};

const decide = (ship, reason) => {
  console.log(`${ship ? "SHIP" : "SKIP"}: ${reason}`);
  if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, `ship=${ship}\n`);
  process.exit(0);
};

// Everything the shipped iOS build and its pipeline are made from. The wire-contract rule keeps
// this filter sound: a Mac-side change that matters to the phone must update
// ios/Shared/SyncWire.swift (docs/ios-app.md), so it always lands inside ios/.
const IOS_PATHS = [
  "ios",
  "script/release_ios.sh",
  "script/testflight_distribute.mjs",
  "script/testflight_gate.mjs",
  "script/lib/appstore_connect.mjs",
  ".github/workflows/release.yml",
];

const STABLE_TAG = /^v\d+\.\d+\.\d+$/;
const TAG = env("RELEASE_TAG");
if (!STABLE_TAG.test(TAG)) fail(`Release tags must use the stable form v1.2.3 (got: ${TAG}).`);
const BUNDLE_ID = process.env.RUNWAY_IOS_BUNDLE_ID || "com.mattstallone.runway.mobile";
const MAX_AGE_DAYS = Number(process.env.TESTFLIGHT_MAX_BUILD_AGE_DAYS || 60);

// stderr passes through so a git failure explains itself before the non-zero exit.
const git = (...args) =>
  execFileSync("git", args, { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] }).trim();

if (process.env.FORCE_IOS === "1") decide(true, "FORCE_IOS is set.");

// Previous stable release = highest stable tag whose version is below this one — the same range
// rule the release changelog uses. Deliberately NOT ancestry-based: a tag created before its
// changelog squash-merge sits off main forever (it has happened), yet its tree is still what
// testers last received, and `git diff` compares trees regardless of ancestry. Version order also
// keeps a rerun of an old tag from diffing against a newer release. Inherited beta tags
// (v0.7.7-beta.1, …) never match STABLE_TAG.
const version = (t) => t.slice(1).split(".").map(Number);
const lessThan = (a, b) => {
  for (let i = 0; i < 3; i += 1) if (a[i] !== b[i]) return a[i] < b[i];
  return false;
};
const tagVersion = version(TAG);
const previous = git("tag", "--list", "--sort=-v:refname")
  .split("\n")
  .filter((t) => STABLE_TAG.test(t) && lessThan(version(t), tagVersion))[0];
if (!previous) decide(true, "no previous stable release tag — first release.");

const diffAgainst = (base) =>
  git("diff", "--name-only", base, TAG, "--", ...IOS_PATHS).split("\n").filter(Boolean);

// Fast path, no App Store Connect needed: changes since the previous stable tag are new to
// testers no matter which older build they actually have.
const sincePrevious = diffAgainst(previous);
if (sincePrevious.length) {
  decide(true, `iOS-relevant changes since ${previous}:\n  ${sincePrevious.join("\n  ")}`);
}

// No changes since the previous tag — but that only proves freshness if the previous tag's iOS
// build actually reached testers. Ask App Store Connect what EXTERNAL testers really have.
// Processing VALID alone is not enough: the external-group attach happens later, in the
// distribute job, and can fail independently — a build only counts once it is in every
// configured external group. (Beta App Review APPROVAL is deliberately not required: it is
// asynchronous and pending for up to a day after every ship, and requiring it would re-ship
// byte-identical builds — the exact overhead this gate removes. A review rejection is
// owner-visible in App Store Connect.)
const api = createClient({
  keyPath: env("APPLE_NOTARY_KEY_PATH"),
  keyId: env("APPLE_NOTARY_KEY_ID"),
  issuerId: env("APPLE_NOTARY_ISSUER_ID"),
});

const apps = await api("GET", `/v1/apps?filter[bundleId]=${encodeURIComponent(BUNDLE_ID)}`);
if (apps.status !== 200) fail("Could not query App Store Connect apps.", apps);
const app = apps.json.data?.[0];
if (!app) {
  fail(`No App Store Connect app record for ${BUNDLE_ID} — create it first (docs/releasing.md "Release setup").`);
}

const groupNames = (process.env.TESTFLIGHT_EXTERNAL_GROUPS || "External")
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean);

// Newest valid build per external group; a partially distributed release leaves one group
// behind, so the OLDEST of those per-group newest builds is what every external tester is
// guaranteed to have — the baseline for both the diff and the expiry backstop.
let baseline;
for (const name of groupNames) {
  const res = await api(
    "GET",
    `/v1/betaGroups?filter[app]=${app.id}&filter[name]=${encodeURIComponent(name)}`,
  );
  if (res.status !== 200) fail("Could not query TestFlight groups.", res);
  const group = res.json.data?.find((g) => g.attributes.name === name);
  if (!group) decide(true, `external TestFlight group "${name}" does not exist yet.`);
  const builds = await api(
    "GET",
    `/v1/builds?filter[app]=${app.id}&filter[betaGroups]=${group.id}` +
      `&filter[processingState]=VALID&sort=-uploadedDate&limit=1&include=preReleaseVersion`,
  );
  if (builds.status !== 200) fail("Could not query builds.", builds);
  const newest = builds.json.data?.[0];
  if (!newest) decide(true, `no processed build has ever been distributed to external group "${name}".`);
  const preId = newest.relationships?.preReleaseVersion?.data?.id;
  const version = builds.json.included?.find(
    (i) => i.type === "preReleaseVersions" && i.id === preId,
  )?.attributes?.version;
  if (!version) fail(`Could not read the marketing version of group "${name}"'s newest build.`, builds);
  const uploadedAt = Date.parse(newest.attributes.uploadedDate);
  if (!Number.isFinite(uploadedAt)) {
    fail(`Could not read the uploadedDate of group "${name}"'s newest build.`, builds);
  }
  if (!baseline || uploadedAt < baseline.uploadedAt) {
    baseline = { version, uploadedAt, buildNumber: newest.attributes.version };
  }
}

// The build's marketing version names the tag it was built from (the version IS the tag). When
// that is not the previous tag, an earlier release's iOS upload or distribution failed — diff
// against what testers actually have so those changes cannot be stranded.
const shippedTag = `v${baseline.version}`;
if (shippedTag !== previous) {
  if (!STABLE_TAG.test(shippedTag) || !git("tag", "--list", shippedTag)) {
    decide(true, `newest externally distributed build is ${baseline.version}, which matches no local release tag — shipping to be safe.`);
  }
  const sinceShipped = diffAgainst(shippedTag);
  if (sinceShipped.length) {
    decide(true, `iOS-relevant changes since the last externally shipped build (${shippedTag}):\n  ${sinceShipped.join("\n  ")}`);
  }
}

const ageDays = (Date.now() - baseline.uploadedAt) / 86_400_000;
const age = `build ${baseline.buildNumber} of ${baseline.version} uploaded ${Math.floor(ageDays)} days ago`;
if (ageDays > MAX_AGE_DAYS) {
  decide(true, `newest externally distributed build is stale (${age}; limit ${MAX_AGE_DAYS}, expiry 90).`);
}
decide(false, `no iOS-relevant changes since the last externally shipped build (${shippedTag}) and it is fresh (${age}).`);
