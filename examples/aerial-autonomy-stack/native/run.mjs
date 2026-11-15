import { lstat, mkdir, readFile, realpath, writeFile } from 'node:fs/promises';
import { dirname, isAbsolute, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Admission, createHost, Jobs, referenceFile, RunOwner, RunStartupError } from '@robotics-runtime/host';
import { createLocalAttempt, verifyAttemptInputs } from '@robotics-runtime/infra-host';

const directory = dirname(fileURLToPath(import.meta.url));
const imageRef = /^[a-z0-9][a-z0-9._:/-]*@sha256:[a-f0-9]{64}$/;
const imageId = /^sha256:[a-f0-9]{64}$/;
const runIdPattern = /^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/;

async function loadInput(path) {
  if (!path || !isAbsolute(path) || await realpath(path) !== path) throw new Error('an absolute, canonical input file is required');
  const ref = await referenceFile(path, { maxBytes: 65_536 });
  const input = JSON.parse(await readFile(path, 'utf8'));
  await verifyAttemptInputs([ref]);
  if (!runIdPattern.test(input.runId) || !/^10\.\d{1,3}$/.test(input.subnetPrefix) || Number(input.subnetPrefix.split('.')[1]) > 255)
    throw new Error('runId must be a UUIDv4 and subnetPrefix a private two-octet prefix');
  for (const role of ['simulation', 'aircraft']) {
    const image = input.images?.[role];
    if (!imageRef.test(image?.reference) || !imageId.test(image?.id)) throw new Error('each image requires an admitted reference and image ID');
  }
  for (const key of ['compose', 'socket', 'output']) {
    if (typeof input[key] !== 'string' || !isAbsolute(input[key])) throw new Error(key + ' must be absolute');
    const existing = key === 'output' ? dirname(input[key]) : input[key];
    if (await realpath(existing) !== existing) throw new Error(key + ' must use a canonical path');
  }
  if (!(await lstat(input.compose)).isFile() || !(await lstat(input.socket)).isSocket()) throw new Error('the Compose client and Engine socket must already exist');
  if (!Array.isArray(input.admissionRefs) || input.admissionRefs.length < 1 || input.admissionRefs.length > 24)
    throw new Error('the operator must supply the admitted source and image evidence references');
  return { input, ref };
}

async function main() {
  if (process.argv.length !== 3) throw new Error('usage: node native/run.mjs /absolute/admitted-input.json');
  const { input, ref } = await loadInput(process.argv[2]);
  const composeFile = join(directory, 'compose.yaml');
  const profilePath = join(directory, 'profile.yml');
  const local = await Promise.all([composeFile, profilePath, join(directory, 'provider.mjs'), fileURLToPath(import.meta.url)].map(path => referenceFile(path)));
  const admissionRefs = [ref, ...local, ...input.admissionRefs];
  await verifyAttemptInputs(admissionRefs);
  const unit = 'rr-attempt-' + input.runId + '.service';
  const invocationId = process.env.INVOCATION_ID;
  if (!/^[a-f0-9]{32}$/.test(invocationId)) throw new Error('run inside its bounded user systemd unit');
  const projectName = 'rr-aas-' + input.runId;
  const host = await createHost({ baseDirectory: directory });
  await host.plugin(Jobs, { timeoutMs: 260_000, maxBufferBytes: 4_194_304 });
  await host.plugin(Admission, { profiles: [{ id: 'aas', profilePath,
    files: admissionRefs.map(item => ({ path: fileURLToPath(item.uri), sha256: item.sha256 })),
    requiredBindings: [{ entryId: 'aas', service: 'aas' }], isolatedServices: ['aas'], deadlineMs: 75_000 }] });
  await host.plugin(RunOwner);
  await host.admission.admit('aas');
  await mkdir(input.output, { mode: 0o700 });
  const attempt = await createLocalAttempt(join(input.output, 'attempt.json'), {
    runId: input.runId, projectName, targetEnvironment: 'simulation',
    coordinator: { unit, invocationId }, admissionRefs,
  }, { jobs: host.jobs, busctl: '/usr/bin/busctl' });
  host.provide('aasInput', Object.freeze({ ...input, projectName, composeFile, attempt }));

  const controller = new AbortController();
  const interrupt = () => controller.abort(new Error('attempt interrupted'));
  for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, interrupt);
  let completion;
  let measurementError;
  try {
    const run = await host.runOwner.start('aas', input.runId, { cancelSignal: controller.signal });
    const backend = run.context.get('aas');
    run.beginMeasurement();
    try { await backend.measure(controller.signal); }
    catch (error) { measurementError = String(error); }
    completion = await run.finish(backend.completion());
  } catch (error) {
    if (!(error instanceof RunStartupError)) throw error;
    measurementError = String(error);
    completion = error.completion;
  } finally {
    for (const signal of ['SIGINT', 'SIGTERM']) process.removeListener(signal, interrupt);
  }
  await writeFile(join(input.output, 'completion.json'), JSON.stringify({ attempt, measurementError, completion }, null, 2) + '\n', { flag: 'wx' });
  console.log(join(input.output, 'completion.json'));
  if (completion.status !== 'incomplete') await host.fiber.dispose();
  if (measurementError || completion.status !== 'passed') process.exitCode = 1;
}

main().catch(error => { console.error(error.message); process.exitCode = 1; });
