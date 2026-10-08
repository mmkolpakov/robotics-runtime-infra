import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

export async function checkMaintenance(root, renovate) {
  const load = (path) => import(pathToFileURL(resolve(renovate, "dist", path)));
  const { extractPackageFile } = await load("modules/manager/index.js");
  const { applyPackageRules } = await load("util/package-rules/index.js");
  const { resolveConfigPresets } = await load("config/presets/index.js");
  const { getConfig } = await load("config/defaults.js");
  const { GlobalConfig } = await load("config/global.js");
  const { getMatchingFiles } = await load("workers/repository/extract/file-match.js");
  const preCommit = await load("modules/manager/pre-commit/index.js");
  const config = JSON.parse(await readFile(resolve(root, "renovate.json"), "utf8"));
  const resolved = { ...getConfig(), ...(await resolveConfigPresets(config)).config };
  assert.equal(resolved.automerge, false);
  const apply = (dep, manager, packageFile, extra = {}) => applyPackageRules({
    ...resolved, ...dep, manager, packageFile,
    packageName: dep.packageName ?? dep.depName, ...extra,
  });

  const workflow = ".github/workflows/ci.yml";
  const source = await readFile(resolve(root, workflow), "utf8");
  const actual = await extractPackageFile("github-actions", source, workflow, {});
  const runners = actual.deps.filter((dep) => dep.datasource === "github-runners");
  assert.ok(runners.length > 0, "current workflows must expose hosted runners");
  const fixture = await extractPackageFile("github-actions", [
    "name: Runner fixture", "on: push", "jobs:",
    "  amd64:", "    runs-on: ubuntu-24.04",
    "    steps:", "      - run: true",
    "  arm64:", "    runs-on: ubuntu-24.04-arm",
    "    steps:", "      - run: true",
    "  windows:", "    runs-on: windows-2025",
    "    steps:", "      - run: true",
  ].join("\n"), workflow, {});
  const fixtureRunners = fixture.deps.filter((dep) => dep.datasource === "github-runners");
  assert.deepEqual(fixtureRunners.map((dep) => dep.replaceString).sort(),
    ["ubuntu-24.04", "ubuntu-24.04-arm", "windows-2025"]);
  for (const dep of [...runners, ...fixtureRunners]) {
    for (const updateType of ["major", "minor"]) {
      const rule = await apply(dep, "github-actions", workflow, { updateType });
      assert.equal(rule.dependencyDashboardApproval, true);
      assert.equal(rule.groupName, "GitHub runner migrations");
      assert.equal(rule.automerge, false);
      assert.notEqual(rule.enabled, false);
    }
  }
  const image = (await extractPackageFile("dockerfile",
    "FROM ubuntu:24.04\n", "docker/control.Dockerfile", {})).deps[0];
  const imageRule = await apply(image, "dockerfile", "docker/control.Dockerfile");
  assert.notEqual(imageRule.dependencyDashboardApproval, true,
    "runner approval must not gate Docker OS dependencies");
  for (const dep of actual.deps.filter((item) => item.datasource !== "github-runners")) {
    assert.notEqual((await apply(dep, "github-actions", workflow)).dependencyDashboardApproval,
      true, "ordinary action updates must retain their own policy");
  }

  const preCommitConfig = { ...preCommit.defaultConfig, ...resolved["pre-commit"] };
  assert.equal(preCommitConfig.enabled, true);
  assert.ok(getMatchingFiles(preCommitConfig,
    [".pre-commit-config.yaml", "renovate.json"]).includes(".pre-commit-config.yaml"));
  const hooks = await extractPackageFile("pre-commit",
    await readFile(resolve(root, ".pre-commit-config.yaml"), "utf8"),
    ".pre-commit-config.yaml", preCommitConfig);
  assert.ok(hooks.deps.length >= 5, "native manager must extract actual repository hooks");
  assert.ok(hooks.deps.some((dep) => dep.depName === "DavidAnson/markdownlint-cli2"));
  console.log("PASS hosted runner approval and native pre-commit extraction: " + root);

  // Only infra has the local source cohort and release-asset-only host peer.
  let cohort;
  try {
    cohort = await readFile(resolve(root, "docker/ros-cohort-source.Dockerfile"), "utf8");
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
    return;
  }
  const cohortFile = "docker/ros-cohort-source.Dockerfile";
  const local = await extractPackageFile("dockerfile", cohort, cohortFile, {});
  const localId = local.deps.find((dep) => dep.depName === "sha256");
  assert.ok(localId && /^[a-f0-9]{64}$/.test(localId.currentValue));
  assert.equal((await apply(localId, "dockerfile", cohortFile)).enabled, false);
  assert.notEqual((await apply(localId, "dockerfile", "docker/other.Dockerfile")).enabled,
    false, "the exception must be confined to the actual source-cohort file");
  assert.notEqual(imageRule.enabled, false, "real image dependencies remain tracked");

  GlobalConfig.set({ localDir: root, platform: "local" });
  try {
    const npm = await load("modules/manager/npm/index.js");
    const files = await npm.extractAllPackageFiles(resolved.npm, ["host/package.json"]);
    const host = files.find((file) => file.packageFile === "host/package.json");
    const peer = host.deps.find((dep) =>
      dep.depName === "@robotics-runtime/host" && dep.depType === "peerDependencies");
    assert.ok(peer && peer.datasource === "npm");
    assert.equal((await apply(peer, "npm", host.packageFile)).enabled, false);
    assert.notEqual((await apply(peer, "npm", "other/package.json")).enabled, false);
    assert.notEqual((await apply({ ...peer, depName: "@robotics-runtime/other" },
      "npm", host.packageFile)).enabled, false);
    const archive = host.deps.find((dep) =>
      dep.depName === "@robotics-runtime/host" && dep.depType === "devDependencies");
    assert.equal(archive.skipReason, "file", "the verified asset remains a file dependency");
    for (const dep of host.deps.filter((item) => item.depName !== "@robotics-runtime/host")) {
      assert.notEqual((await apply(dep, "npm", host.packageFile)).enabled, false,
        "public host dependencies remain tracked");
    }
    console.log("PASS exact local-image and private-peer exclusions with public lookup controls");
  } finally {
    GlobalConfig.reset();
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const root = process.argv[3] ?? resolve(dirname(fileURLToPath(import.meta.url)), "../..");
  assert.ok(process.argv[2], "pass the installed Renovate package directory");
  await checkMaintenance(resolve(root), resolve(process.argv[2]));
  process.exit(0);
}
