import {createHash} from 'node:crypto';
import {constants} from 'node:fs';
import {chmod, open, lstat, writeFile} from 'node:fs/promises';
import {join, resolve} from 'node:path';

/** Reuse the public C19 validator, then bind the consumer's selected inputs. */
export async function admitContext(jobs, {contextPath, scenarioPath, schemaPath, contractsExecutable, output, domainId, mode}) {
  const copy = async (source, name) => {
    const path = resolve(source);
    const maximum = 4 * 1024 * 1024;
    const handle = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    let raw;
    try {
      const before = await handle.stat({bigint: true});
      if (!before.isFile() || before.size > BigInt(maximum)) throw new Error('bounded regular document input required');
      const buffer = Buffer.alloc(maximum + 1);
      let size = 0;
      while (size <= maximum) {
        const result = await handle.read(buffer, size, buffer.length - size, null);
        if (result.bytesRead === 0) break;
        size += result.bytesRead;
      }
      const after = await handle.stat({bigint: true});
      const current = await lstat(path, {bigint: true});
      const same = value => ['dev','ino','mode','size','mtimeNs','ctimeNs'].every(key => value[key] === before[key]);
      if (size > maximum || BigInt(size) !== before.size || !same(after) || !same(current)) {
        throw new Error('document input changed or exceeded its capture bound');
      }
      raw = buffer.subarray(0, size);
    } finally {
      await handle.close();
    }
    const destination = join(output, name);
    await writeFile(destination, raw, {flag: 'wx', mode: 0o444});
    await chmod(destination, 0o444);
    return {path: destination, raw, sha256: createHash('sha256').update(raw).digest('hex')};
  };
  const context = await copy(contextPath, 'run-context.json');
  const scenario = await copy(scenarioPath, 'scenario.json');
  const schema = await copy(schemaPath, 'nav2.schema.json');
  const validate = async (name, args) => {
    const result = await jobs.run({executable: contractsExecutable, args: ['validate', ...args],
      timeoutMs: 15000, maxBufferBytes: 1048576, extendEnv: false,
      env: {PATH: '/usr/bin:/bin', PYTHONDONTWRITEBYTECODE: '1'}});
    await writeFile(join(output, name + '.stdout'), result.stdout);
    await writeFile(join(output, name + '.stderr'), result.stderr);
    if (!result.ok) throw Object.assign(new Error('public document validation refused: ' + name), {cause: result});
  };
  await validate('validate-context', ['--schema', 'acceptance-run.v1', context.path]);
  await validate('validate-scenario', ['--extension-schema', 'urn:nav2-turtlebot3:scenario:v1=' + schema.path, scenario.path]);
  const issued = JSON.parse(context.raw);
  const declared = JSON.parse(scenario.raw);
  if (issued.scenario_sha256 !== scenario.sha256 || issued.scenario_id !== declared.scenario_id ||
      issued.domains.filter(domain => domain.domain_id === domainId).length !== 1 ||
      issued.domains.find(domain => domain.domain_id === domainId)?.role !== 'simulation' ||
      issued.time_authority.kind !== 'sim_clock' || issued.time_authority.source_id !== 'gazebo-harmonic-clock' ||
      declared.extensions?.['org.example.nav2-turtlebot3']?.case !== mode) {
    throw new Error('foreign run context, domain, scenario, or case');
  }
  const selectedExecution = {target_environment: 'simulation', data_source: 'simulator',
    plant_backend: 'simulated_physics', time_mode: 'simulation_realtime',
    data_plane_profile: 'standard_isolated', security_profile: 'none', physical_effect: 'none'};
  if (!Object.entries(selectedExecution).every(([key,value]) => declared.execution[key] === value) ||
      declared.authorization.mode !== 'none') {
    throw new Error('foreign execution route for the selected Nav2 consumer');
  }
  return {runId: issued.run_id, domainId, contextSha256: context.sha256,
    scenarioSha256: scenario.sha256, scenario: declared};
}
