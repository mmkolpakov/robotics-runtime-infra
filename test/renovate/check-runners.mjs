import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

export async function checkRunnerSelections(root, renovate) {
  const load = (name) => import(pathToFileURL(resolve(renovate, "dist", name)));
  const { extractPackageFile, getEnabledManagersList } = await load("modules/manager/index.js");
  const { Workflow } = await load("modules/manager/github-actions/schema.js");
  const { getMatchingFiles } = await load("workers/repository/extract/file-match.js");
  const { resolveConfigPresets } = await load("config/presets/index.js");
  const { getConfig } = await load("config/defaults.js");
  const { applyPackageRules } = await load("util/package-rules/index.js");
  const { doAutoReplace } = await load("workers/repository/update/branch/auto-replace.js");
  const { lookupUpdates } = await load("workers/repository/process/lookup/index.js");
  const { GlobalConfig } = await load("config/global.js");
  const { GithubRunnersDatasource } = await load("modules/datasource/github-runners/index.js");
  const memory = await load("util/cache/memory/index.js");
  const config = JSON.parse(await readFile(resolve(root, "renovate.json"), "utf8"));
  const resolved = { ...getConfig(), ...(await resolveConfigPresets(config)).config };
  const managers = config.customManagers.filter((manager) => manager.datasourceTemplate === "github-runners");
  assert.equal(managers.length, 1);
  const manager = managers[0];
  assert.ok(getEnabledManagersList(resolved.enabledManagers).includes("regex"),
    "the configured runner manager must be enabled in actual repository extraction");
  const files = (await readdir(resolve(root, ".github/workflows"))).filter((name) => /\.ya?ml$/.test(name))
    .map((name) => ".github/workflows/" + name);
  assert.deepEqual(getMatchingFiles(manager, ["README.md", ...files]).sort(), files.sort());
  const datasource = new GithubRunnersDatasource();
  const releases = (await datasource.getReleases({ packageName: "ubuntu" })).releases;
  const temporary = await mkdtemp(resolve(tmpdir(), "runner-renovate-"));
  const observed = new Set();
  let count = 0;
  memory.init();
  GlobalConfig.set({ localDir: temporary, platform: "local" });
  try {
    for (const suffix of ["", "-arm"]) {
      const file = ".github/workflows/runner-lookup-control.yml";
      const value = "22.04" + suffix;
      const fixture = `name: Lookup control
on: push
jobs:
  control:
    runs-on: \${{ fromJSON('${JSON.stringify({ hosted: "ubuntu-" + value })}') }}
    steps:
      - run: true
`;
      const custom = (await extractPackageFile("regex", fixture, file, manager)).deps[0];
      const native = (await extractPackageFile("github-actions",
        "name: Native lookup control\non: push\njobs:\n  control:\n    runs-on: ubuntu-" +
        value + "\n    steps:\n      - run: true\n", file, {})).deps[0];
      const policy = (dep, type) => applyPackageRules({
        ...resolved, ...manager, ...dep, manager: type, packageFile: file,
        packageName: dep.packageName ?? dep.depName,
      });
      const selected = (await lookupUpdates(await policy(custom, "regex"))).unwrapOrThrow();
      const baseline = (await lookupUpdates(await policy(native, "github-actions"))).unwrapOrThrow();
      assert.deepEqual(selected.updates, baseline.updates);
      assert.ok(selected.updates.some((update) => update.newValue === "24.04" + suffix),
        "stable datasource lookup control must produce the architecture-preserving update");
    }
    for (const file of files) {
      const source = await readFile(resolve(root, file), "utf8");
      const extracted = await extractPackageFile("regex", source, file, manager);
      const parsed = Workflow.parse(source);
      for (const job of Object.values(parsed?.jobs ?? {})) {
        for (const expression of job["runs-on"]) {
          if (!expression.includes("vars.ROBOTICS_CI_EXECUTOR")) continue;
          const selected = await extractPackageFile("regex", expression, file, manager);
          assert.equal(selected?.deps.length, 1, "each selected job needs one runner dependency");
          const expected = selected.deps[0];
          assert.ok(extracted?.deps.some((dep) =>
            ["depName", "currentValue", "datasource", "replaceString"].every((key) =>
              dep[key] === expected[key])), "whole-file extraction must retain each selected job");
        }
      }
      let content = source;
      let expectedContent = source;
      await mkdir(resolve(temporary, dirname(file)), { recursive: true });
      await writeFile(resolve(temporary, file), source);
      for (const [depIndex, dep] of (extracted?.deps ?? []).entries()) {
        const arm = dep.currentValue.endsWith("-arm");
        observed.add(arm ? "arm64" : "x64");
        const literal = await extractPackageFile("github-actions",
          "name: Native runner baseline\non: push\njobs:\n  baseline:\n    runs-on: ubuntu-" +
          dep.currentValue + "\n    steps:\n      - run: true\n", file, {});
        const native = literal.deps.find((item) => item.datasource === "github-runners");
        assert.ok(native);
        for (const key of ["depName", "currentValue", "datasource", "depType", "extractVersion"]) {
          assert.equal(dep[key], native[key], key);
        }
        assert.equal(dep.packageName ?? dep.depName, native.packageName ?? native.depName);
        assert.equal(dep.versioning, native.versioning ?? datasource.defaultVersioning);
        assert.ok(releases.some((release) => release.version === dep.currentValue));
        const apply = (item, type) => applyPackageRules({
          ...resolved, ...manager, ...extracted, ...item,
          manager: type, packageFile: file, depIndex, packageName: item.packageName ?? item.depName,
        });
        const selected = await apply(dep, "regex");
        const baseline = await apply(native, "github-actions");
        for (const policy of [selected, baseline]) {
          assert.equal(policy.dependencyDashboardApproval, true);
          assert.equal(policy.groupName, "GitHub runner migrations");
          assert.equal(policy.automerge, false);
          assert.notEqual(policy.enabled, false);
        }
        const updates = (await lookupUpdates(selected)).unwrapOrThrow();
        const nativeUpdates = (await lookupUpdates(baseline)).unwrapOrThrow();
        assert.deepEqual(updates.updates, nativeUpdates.updates);
        const candidate = releases.find((release) => release.version !== dep.currentValue &&
          !release.isDeprecated && release.version.endsWith("-arm") === arm);
        assert.ok(candidate);
        content = await doAutoReplace({ ...selected, newValue: candidate.version }, content, false);
        const changed = await extractPackageFile("regex", content, file, manager);
        assert.equal(changed.deps[depIndex].currentValue, candidate.version);
        const oldLabel = '"hosted":"ubuntu-' + dep.currentValue + '"';
        const newLabel = '"hosted":"ubuntu-' + candidate.version + '"';
        assert.ok(source.includes(oldLabel));
        expectedContent = expectedContent.replaceAll(oldLabel, newLabel);
        assert.equal(await readFile(resolve(temporary, file), "utf8"), content);
        count += 1;
      }
      assert.equal(content, expectedContent, "only selected hosted labels may change");
    }
    assert.ok(count > 0, "actual workflows must expose hosted runner selections");
    assert.ok(observed.has("x64"));
    if (files.includes(".github/workflows/ci-supply-chain.yml")) assert.ok(observed.has("arm64"));
    console.log("PASS actual hosted runner extraction, native datasource/policy equivalence and file updates: " +
      count + " selections; " + [...observed].join(", ") +
      ". Writer controls do not qualify another hosted platform.");
  } finally {
    memory.reset();
    GlobalConfig.reset();
    await rm(temporary, { recursive: true, force: true });
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  assert.ok(process.argv[2], "pass the installed Renovate package directory");
  await checkRunnerSelections(resolve(dirname(fileURLToPath(import.meta.url)), "../.."), resolve(process.argv[2]));
  process.exit(0);
}
