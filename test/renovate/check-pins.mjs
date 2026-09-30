import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { startGithubFixture } from "./github-fixture.mjs";

// Exercise the installed Renovate implementation, including its actual file writer.
const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
assert.ok(process.argv[2], "pass the directory of the installed renovate package");
const renovate = resolve(process.argv[2]);
const load = (path) => import(pathToFileURL(resolve(renovate, "dist", path)));
const config = JSON.parse(await readFile(resolve(root, "renovate.json"), "utf8"));
const ci = await readFile(resolve(root, ".github/workflows/ci.yml"), "utf8");
const installed = JSON.parse(await readFile(resolve(renovate, "package.json"), "utf8"));
assert.equal(installed.version, ci.match(/renovate\/renovate:([\d.]+)@/)[1]);
console.log(`Loading Renovate ${installed.version} extraction and update pipeline...`);

const { extractPackageFile } = await load("modules/manager/index.js");
const { getMatchingFiles } = await load("workers/repository/extract/file-match.js");
const { lookupUpdates } = await load("workers/repository/process/lookup/index.js");
const { doAutoReplace } = await load("workers/repository/update/branch/auto-replace.js");
const { applyPackageRules } = await load("util/package-rules/index.js");
const { resolveConfigPresets } = await load("config/presets/index.js");
const { getConfig } = await load("config/defaults.js");
const { GlobalConfig } = await load("config/global.js");
const memory = await load("util/cache/memory/index.js");
const resolvedConfig = { ...getConfig(), ...(await resolveConfigPresets(config)).config };
const packageFile = "foundation.repos";
const candidateFiles = [
  packageFile, "config/foundation-lock.json", "docker-bake.hcl",
  "docker/python/acceptance-observer.in", "docker/python/permit-preflight.in",
  ".github/workflows/ci.yml", "nested/foundation.repos",
];
const managers = config.customManagers.filter((manager) =>
  getMatchingFiles(manager, candidateFiles).includes(packageFile));
assert.equal(managers.length, 1, "exactly one foundation manager is required");
const manager = managers[0];
assert.equal(manager.customType, "jsonata");
assert.deepEqual(getMatchingFiles(manager, candidateFiles), [packageFile]);
const managerName = `custom.${manager.customType}`;
const extract = (content) => extractPackageFile(managerName, content, packageFile, manager);
const fixtureText = await readFile(resolve(root, "test/renovate/stable.repos"), "utf8");
const fixture = JSON.parse(fixtureText);
const source = fixture.repositories["robotics-runtime"];
const originalDigest = source.version;
const newDigest = "2".repeat(40);
const liveText = await readFile(resolve(root, packageFile), "utf8");
const livePin = JSON.parse(liveText).repositories["robotics-runtime"];
const liveExtract = await extract(liveText);
if (livePin.release === undefined) {
  assert.match(livePin.version, /^[a-f0-9]{40}$/);
  assert.equal(liveExtract, null, "a development SHA must not track main or an invented release");
  console.log(`PENDING stable adoption: foundation.repos has only development SHA ${livePin.version}`);
} else {
  assert.equal(liveExtract?.deps.length, 1, "the canonical release pin must be extracted");
  assert.equal(liveExtract.deps[0].currentValue, livePin.release);
  assert.equal(liveExtract.deps[0].currentDigest, livePin.version);
}

let rejected = 0;
for (const patch of [
  { release: undefined }, { release: "main" }, { release: "contracts-v0.19.0" },
  { release: "harness-v0.19.0rc1" }, { release: "harness-v0.19.0-rc.1" },
  { release: [] }, { version: "main" }, { version: "1".repeat(39) },
  { version: [] }, { type: "hg" },
  { url: "https://github.com/other-owner/robotics-runtime.git" },
]) {
  const document = { repositories: { "robotics-runtime": { ...source, ...patch } } };
  assert.equal(await extract(JSON.stringify(document)), null, JSON.stringify(patch));
  rejected += 1;
}
console.log(`${rejected} invalid/unreleased source cases rejected by Renovate extraction`);

const temporary = await mkdtemp(resolve(tmpdir(), "foundation-renovate-"));
const github = await startGithubFixture(originalDigest, newDigest);
GlobalConfig.set({ localDir: temporary, platform: "local" });
memory.init();
try {
  const formats = [
    ["LF", fixtureText.replaceAll("\r\n", "\n")],
    ["CRLF", fixtureText.replaceAll("\r\n", "\n").replaceAll("\n", "\r\n")],
    ["reordered JSON", JSON.stringify({ repositories: {
      "robotics-runtime": { version: originalDigest, release: source.release, url: source.url, type: "git" },
    } })],
    ["identical decoy values", JSON.stringify({
      unrelated: { release: source.release, version: originalDigest }, ...fixture,
    }, null, 2)],
  ];
  for (const [name, content] of formats) {
    const extracted = await extract(content);
    assert.equal(extracted?.deps.length, 1, name);
    const dep = extracted.deps[0];
    assert.equal(dep.depName, "mmkolpakov/robotics-runtime");
    assert.equal(dep.datasource, "github-releases");
    assert.equal(dep.currentValue, source.release);
    assert.equal(dep.currentDigest, originalDigest);
    assert.ok(!dep.skipReason);
    const lookupConfig = await applyPackageRules({
      ...resolvedConfig, ...manager, ...extracted, ...dep,
      manager: managerName, packageFile, depIndex: 0, packageName: dep.depName,
      // Only the remote API is a fixture. Renovate executes all dependency processing.
      registryUrls: [github.url],
    });
    assert.equal(lookupConfig.automerge, false);
    assert.equal(lookupConfig.ignoreUnstable, true);
    assert.equal(lookupConfig.minimumReleaseAge, "3 days");
    const result = (await lookupUpdates(lookupConfig)).unwrapOrThrow();
    assert.ok(!result.skipReason, result.skipReason);
    assert.deepEqual(result.warnings, []);
    assert.equal(result.updates.length, 1, JSON.stringify(result));
    const update = result.updates[0];
    assert.equal(update.newValue, "harness-v0.20.0");
    assert.equal(update.newDigest, newDigest, "use the annotated tag's commit, not the tag object");
    await writeFile(resolve(temporary, packageFile), content);
    const updated = await doAutoReplace({ ...lookupConfig, ...update }, content, false);
    assert.equal(await readFile(resolve(temporary, packageFile), "utf8"), updated);
    const expected = JSON.parse(content);
    expected.repositories["robotics-runtime"].release = update.newValue;
    expected.repositories["robotics-runtime"].version = newDigest;
    assert.deepEqual(JSON.parse(updated), expected, `${name}: unrelated fields must be preserved`);
    if (name === "LF" || name === "CRLF") {
      assert.equal(updated, content.replace(source.release, update.newValue).replace(originalDigest, newDigest));
    }
    const changed = (await extract(updated)).deps[0];
    assert.equal(changed.currentValue, update.newValue);
    assert.equal(changed.currentDigest, newDigest);
    assert.equal(await doAutoReplace({ ...lookupConfig, ...update }, updated, false, false), updated);
    console.log(`PASS ${name}: ${dep.currentValue}@${dep.currentDigest} -> ${changed.currentValue}@${changed.currentDigest}`);
  }
  assert.ok(github.queries.includes("releases"), "the real release datasource must query the API");
  assert.ok(github.queries.includes("tags"), "the real datasource must resolve the release tag commit");
  console.log(`Renovate ${installed.version}: 4 extraction/lookup/digest/file-update cases passed; draft, prerelease, recent, foreign-prefix and unpublished tags excluded`);
} finally {
  await github.close();
  memory.reset();
  GlobalConfig.reset();
  await rm(temporary, { recursive: true, force: true });
}
// Renovate imports retain background handles; all work and cleanup above are awaited.
process.exit(0);
