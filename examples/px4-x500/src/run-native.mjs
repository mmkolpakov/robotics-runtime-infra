import {dirname, isAbsolute, join, relative} from 'node:path';
import {realpath} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';
import {readOperatorInput} from './operator-input.mjs';

export async function runNativeAttempt({owner, jobs, caseName, issued, archiveRoot, sdkIds, producerPython, producerPath, harnessExecutable, evaluatorTrust, signal}) {
  if (![archiveRoot, producerPython, producerPath, harnessExecutable].every(isAbsolute)) {
    throw new Error('absolute native archive and public tool paths required');
  }
  if (!evaluatorTrust || typeof evaluatorTrust !== 'object' || typeof evaluatorTrust.profile !== 'string' || !isAbsolute(evaluatorTrust.profile)) {
    throw new Error('an external evaluator trust profile is required');
  }
  for (const key of ['receipts', 'verifications', 'dependencies']) {
    const values = evaluatorTrust[key];
    if (!Array.isArray(values) || values.length > 16 || (key !== 'dependencies' && values.length === 0) ||
        values.some(value => typeof value !== 'string' || !isAbsolute(value))) {
      throw new Error('bounded absolute evaluator trust paths are required');
    }
  }
  const trustedProfile = await realpath(evaluatorTrust.profile);
  const archive = await realpath(archiveRoot), trustRelative = relative(archive, trustedProfile);
  if (!trustRelative || (!trustRelative.startsWith('../') && !isAbsolute(trustRelative))) {
    throw new Error('evaluator trust profile must be outside the evidence archive');
  }
  const run = await owner.start(issued.profile_id, issued.run_id, {cancelSignal: signal});
  const px4 = run.context.get('px4');
  if (!px4 || px4.config.mode !== 'native-sdk-v2' || px4.config.archiveRoot !== archiveRoot) {
    const completion = await run.finish();
    return {completion, workerError: 'admitted PX4 provider/archive binding differs'};
  }
  let workerError;
  try {
    await px4.startNativeLogger(signal);
    run.beginMeasurement();
    await px4.executeNative(caseName, sdkIds, signal);
  } catch (error) {
    workerError = error;
  }
  const completion = await run.finish({
    closeMeasurement: (s) => px4.closeNativeMeasurement(s),
    captureLastState: (s) => px4.captureLastState(s),
    drainRecorders: (s) => px4.drainRecorders(s),
    exportEvidence: (s) => px4.exportEvidence(s),
  });
  const exported = completion.phases?.some(phase => phase.phase === 'exporting-evidence' && phase.status === 'passed');
  if (!exported) return {completion, workerError: String(workerError ?? '')};
  const prepared = join(archiveRoot, 'inputs'), capture = join(archiveRoot, 'capture');
  const completed = await jobs.run({executable: producerPython,
    args: ['-B', producerPath, 'complete', '--prepared', prepared, '--capture', capture],
    cancelSignal: signal, extendEnv: false, env: {PATH: dirname(producerPython) + ':/usr/bin:/bin'}});
  if (!completed.ok) throw new Error('native producer did not complete: ' + (completed.diagnostic ?? completed.stderr));
  const manifest = await readOperatorInput(join(capture, 'controller-manifest.json'));
  if (!/^[0-9]{1,20}$/.test(manifest.started_unix_ns) || !/^[0-9]{1,20}$/.test(manifest.finished_unix_ns)) {
    throw new Error('controller window is unavailable');
  }
  const evaluated = await jobs.run({executable: harnessExecutable, args: [
    'evaluate', '--scenario', join(prepared, 'scenario.json'), '--runtime', join(prepared, 'runtime.json'),
    '--run-id', issued.run_id, '--domain-id', 'px4', '--run-context', join(prepared, 'run.json'),
    '--evidence-index', join(archiveRoot, 'evidence-index.json'),
    '--window-start-ns', manifest.started_unix_ns, '--window-end-ns', manifest.finished_unix_ns,
    '--max-raw-evidence-bytes', String(64 * 1024 * 1024),
    '--evaluator-trust-profile', trustedProfile,
    ...evaluatorTrust.receipts.flatMap(path => ['--evaluator-receipt', path]),
    ...evaluatorTrust.verifications.flatMap(path => ['--evaluator-verification', path]),
    ...evaluatorTrust.dependencies.flatMap(path => ['--evaluator-receipt-dependency', path]),
    '--output', join(archiveRoot, 'assessment'),
  ], cancelSignal: signal, extendEnv: false, env: {PATH: dirname(harnessExecutable) + ':/usr/bin:/bin'}});
  if (evaluated.timedOut || evaluated.canceled || evaluated.signal || ![0, 1].includes(evaluated.exitCode)) {
    throw new Error('native assessment did not complete: ' + (evaluated.diagnostic ?? evaluated.stderr));
  }
  return {completion, evaluation: evaluated, workerError: String(workerError ?? '')};
}

async function main() {
  throw new Error('PX4 native launch requires an admitted SDK/image composition');
  const {Context, Jobs, Admission, RunOwner} = await import('@robotics-runtime/host');
  const [caseName, operatorPath, inputPath] = process.argv.slice(2);
  if (![operatorPath, inputPath].every(isAbsolute)) throw new Error('absolute operator and input paths required');
  const operator = await readOperatorInput(operatorPath), prepared = await readOperatorInput(inputPath);
  const archiveRoot = dirname(dirname(inputPath));
  if (prepared.domain_id !== 'px4' || operator.archiveRoot !== archiveRoot) throw new Error('issued archive binding differs');
  const ctx = new Context();
  await ctx.plugin(Jobs, {timeoutMs: 300000, maxBufferBytes: 1048576});
  await ctx.plugin(Admission, {profiles: [operator.profile]});
  await ctx.plugin(RunOwner);
  const signal = AbortSignal.timeout(300000);
  const result = await runNativeAttempt({
    owner: ctx.runOwner, jobs: ctx.jobs, caseName, issued: {...prepared, profile_id: operator.profile.id},
    archiveRoot, sdkIds: operator.sdkIds, producerPython: operator.producerPython,
    producerPath: operator.producerPath, harnessExecutable: operator.harnessExecutable,
    evaluatorTrust: operator.evaluatorTrust, signal,
  });
  process.stdout.write(JSON.stringify(result) + '\n');
  if (result.completion.status !== 'passed' || result.evaluation?.exitCode !== 0) process.exitCode = 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) await main();
