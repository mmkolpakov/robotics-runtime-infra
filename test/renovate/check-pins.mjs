import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

// Run with the same installed Renovate package version as RENOVATE_IMAGE in CI.
const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
assert.ok(process.argv[2], "pass the directory of the installed renovate package");
const renovate = resolve(process.argv[2]);
const load = (path) => import(pathToFileURL(resolve(renovate, "dist", path)));
console.log("Loading Renovate regex manager and template renderer...");
const { extractPackageFile } = await load("modules/manager/custom/regex/index.js");
const { compile } = await load("util/template/index.js");
const config = JSON.parse(await readFile(resolve(root, "renovate.json"), "utf8"));
const ci = await readFile(resolve(root, ".github/workflows/ci.yml"), "utf8");
const installed = JSON.parse(await readFile(resolve(renovate, "package.json"), "utf8"));
assert.equal(installed.version, ci.match(/renovate\/renovate:([\d.]+)@/)[1]);

const cases = [
  ["foundation.repos", 2],
  ["docker/python/acceptance-observer.in", 2],
  ["docker/python/permit-preflight.in", 1],
  [".github/workflows/ci.yml", 1],
  ["docker-bake.hcl", 2],
  ["Dockerfile", 1],
];
let updates = 0;
for (const [packageFile, expectedCount] of cases) {
  console.log(`Checking ${packageFile}`);
  const original = (await readFile(resolve(root, packageFile), "utf8")).replaceAll("\r\n", "\n");
  for (const eol of ["\n", "\r\n"]) {
    const content = original.replaceAll("\n", eol);
    let count = 0;
    for (const manager of config.customManagers) {
      if (!manager.managerFilePatterns.some((pattern) => new RegExp(pattern.slice(1, -1)).test(packageFile))) continue;
      const extracted = extractPackageFile(content, packageFile, manager);
      count += extracted?.deps.length ?? 0;
      for (const [depIndex, dep] of (extracted?.deps ?? []).entries()) {
        assert.ok(!dep.skipReason, `${packageFile}: ${dep.skipReason}`);
        assert.ok(dep.currentValue, `${packageFile}: missing version`);
        assert.ok(dep.datasource, `${packageFile}: missing datasource`);
        if (!dep.depName.startsWith("mmkolpakov/")) continue;
        const newValue = "v0.99.0";
        const newDigest = dep.currentDigest ? "a".repeat(dep.currentDigest.length) : undefined;
        const upgrade = {
          ...manager, ...extracted, ...dep,
          manager: "custom.regex", packageFile, depIndex,
          newValue, newDigest, autoReplaceGlobalMatch: true,
        };
        const replacement = manager.autoReplaceStringTemplate
          ? compile(manager.autoReplaceStringTemplate, upgrade, false)
          : dep.replaceString.replaceAll(dep.currentValue, newValue).replaceAll(dep.currentDigest, newDigest);
        const result = content.replace(dep.replaceString, replacement);
        assert.ok(result && result !== content, `${packageFile}: replacement failed`);
        const changed = extractPackageFile(result, packageFile, manager).deps[depIndex];
        assert.equal(changed.currentValue, newValue);
        if (newDigest) assert.equal(changed.currentDigest, newDigest);
        if (packageFile !== "foundation.repos") {
          const wheel = dep.depName.slice("mmkolpakov/".length).replaceAll("-", "_");
          assert.ok(result.includes(`/v0.99.0/${wheel}-0.99.0-py3-none-any.whl`));
          assert.ok(!result.includes(`/v0.99.0/${wheel}-${dep.currentValue.slice(1)}-`));
        }
        const otherDeps = extractPackageFile(result, packageFile, manager).deps;
        assert.equal(otherDeps.length, extracted.deps.length);
        for (const [index, other] of otherDeps.entries()) {
          if (index !== depIndex) assert.deepEqual(other, extracted.deps[index]);
        }
        updates += 1;
      }
      if (packageFile !== "Dockerfile" && packageFile !== "docker-bake.hcl") {
        assert.equal(extractPackageFile(content.replaceAll("mmkolpakov/", "other-owner/"), packageFile, manager), null);
      }
    }
    assert.equal(count, expectedCount, `${packageFile}: unexpected extraction count`);
  }
}
assert.equal(updates, 12);
console.log(`Renovate ${installed.version}: 9 pins extracted for LF and CRLF; ${updates} replacements passed; unrelated repositories rejected.`);
// Renovate's library imports retain background handles; all assertions above are synchronous or awaited.
process.exit(0);
