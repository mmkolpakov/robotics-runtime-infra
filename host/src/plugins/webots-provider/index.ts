import {Service, referenceFile} from "@robotics-runtime/host";
import type {ArtifactRef, Context} from "@robotics-runtime/host";
import {createHash, randomUUID} from 'node:crypto';
import {readFile, writeFile} from 'node:fs/promises';
import {isAbsolute, join} from 'node:path';
import {setTimeout as pause} from 'node:timers/promises';
import {ComposeExecution} from '../../compose-execution.js';
import type {ComposeOptions} from '../../compose-execution.js';
import {EngineMetadata} from '../../engine-metadata.js';
import type {MetadataObservation} from '../../engine-metadata.js';

export interface WebotsConfig {
  composeExecutable: string; socketPath: string; composeFiles: readonly string[]; cwd: string;
  workerImage: string; runVolume: string; outputRoot: string;
  mode: 'physics-only' | 'offscreen-camera';
  deadlineMs?: number;
}
const record = (value: unknown): Record<string, unknown> => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('worker fact must be an object');
  return value as Record<string, unknown>;
};
export async function reference(path: string): Promise<ArtifactRef> {
  return referenceFile(path);
}
/** Native APIs stay in the worker; this provider owns only finite Compose jobs and evidence paths. */
declare module "cordis" {interface Context {webots: WebotsNative}}
export class WebotsNative extends Service {
  static inject = ["jobs", "runResources"];
  readonly ownerId: string; readonly project: string; readonly output: string;
  private readonly compose: ComposeExecution;
  private readonly deadline: number;
  private started: Promise<{ready: boolean; evidenceRefs: ArtifactRef[]}> | undefined;
  private engine: EngineMetadata | undefined;
  constructor(ctx: Context, readonly config: WebotsConfig) {
    super(ctx, "webots");
    if (![config.composeExecutable, config.socketPath, ...config.composeFiles, config.cwd, config.outputRoot].every(isAbsolute)) throw new Error('native provider paths must be absolute');
    if (!/@sha256:[a-f0-9]{64}$/.test(config.workerImage)) throw new Error('immutable worker image digest is required');
    if (!['physics-only', 'offscreen-camera'].includes(config.mode)) throw new Error('unsupported native Webots mode');
    this.ownerId = ctx.runResources.ownerId;
    const scope = createHash('sha256').update(this.ownerId + randomUUID()).digest('hex').slice(0,24);
    this.project = 'rr-webots-' + scope;
    this.output = join(config.outputRoot, scope);
    this.deadline = config.deadlineMs ?? 120000;
    if (!Number.isSafeInteger(this.deadline) || this.deadline <= 0 || this.deadline > 300000) throw new Error('invalid finite Webots deadline');
    const options: ComposeOptions = {
      executable: config.composeExecutable, socketPath: config.socketPath, projectName: this.project,
      files: config.composeFiles, cwd: config.cwd, timeoutMs: this.deadline, maxBufferBytes: 1048576,
      env: {ROBOTICS_WEBOTS_IMAGE: config.workerImage, ROBOTICS_RUN_VOLUME: config.runVolume,
        ROBOTICS_RUN_ID: this.ownerId, ROBOTICS_WEBOTS_SCOPE: scope, ROBOTICS_WEBOTS_MODE: config.mode},
    };
    this.compose = new ComposeExecution(ctx.jobs, options);
    ctx.runResources.track({id: this.project, ownerId: this.ownerId,
      cleanup: async () => {
        const stopped = await this.compose.run(['stop', '--timeout', '3', 'webots-native']);
        if (!stopped.ok) throw new Error(stopped.diagnostic ?? 'native worker stop failed');
        const down = await this.compose.run(['down', '--remove-orphans']);
        if (!down.ok) throw new Error(down.diagnostic ?? 'owned Webots project cleanup failed');
      },
      verifyCleanup: async signal => {
        signal.throwIfAborted();
        if (!this.engine) return {released: false, evidenceRefs: [], diagnostic: 'native Engine readiness was not observed'};
        const owned = await this.engine.remainingOwned(this.ownerId);
        const own = (items: unknown[]) => items.filter(item => {
          const labels = record(record(item).Labels ?? {});
          return labels['com.docker.compose.project'] === this.project;
        });
        const released = !own(owned.containers).length && !own(owned.networks).length;
        const {writeFile} = await import('node:fs/promises');
        const path = join(this.output, 'engine-cleanup.json');
        await writeFile(path, JSON.stringify({owner_id: this.ownerId, project: this.project, released,
          observed_owned: owned, retained_host_volume: this.config.runVolume}));
        return {released, evidenceRefs: [await reference(path)]};
      }});
  }
  ready(signal: AbortSignal): Promise<{ready: boolean; evidenceRefs: ArtifactRef[]}> {
    return this.started ??= this.start(signal);
  }
  private async waitFile(name: string, signal: AbortSignal): Promise<Record<string, unknown>> {
    const end = performance.now() + this.deadline;
    for (;;) {
      signal.throwIfAborted();
      try {
        const raw = await readFile(join(this.output, name));
        if (raw.length > 1048576) throw new Error('native worker fact exceeds its bound');
        const value = record(JSON.parse(raw.toString('utf8')));
        if (value.owner_id !== this.ownerId) throw new Error('native evidence belongs to another owner');
        return value;
      } catch (error) {
        if (record(error).code !== 'ENOENT') throw error;
      }
      if (performance.now() >= end) throw new Error('native worker readiness/evidence deadline exceeded');
      await pause(25, undefined, {signal});
    }
  }
  private async start(signal: AbortSignal): Promise<{ready: boolean; evidenceRefs: ArtifactRef[]}> {
    await this.compose.requireVersion();
    this.engine = await EngineMetadata.connect({socketPath: this.config.socketPath, operationMinApi: '1.24', operationMaxApi: '1.53'});
    const launched = await this.compose.run(['up', '--detach', 'webots-native'], signal);
    if (!launched.ok) throw new Error(launched.diagnostic ?? 'native worker launch failed');
    const ps = await this.compose.run(['ps', '--all', '--quiet', 'webots-native'], signal);
    const id = ps.stdout.trim();
    if (!ps.ok || !/^[a-f0-9]{64}$/.test(id)) throw new Error('exact native worker container ID is unavailable');
    const observed: MetadataObservation = await this.engine.inspect(id, {
      runId: this.ownerId, projectName: this.project, imageDigest: this.config.workerImage,
      mounts: [{destination: '/run/robotics', readOnly: false, volumeName: this.config.runVolume}],
      hostConfig: {Init: true, ReadonlyRootfs: true, NetworkMode: 'none', Memory: 2147483648}, user: '10001:1000',
    });
    const ready = await this.waitFile('ready.json', signal);
    await writeFile(join(this.output, 'engine-readiness.json'), JSON.stringify(observed));
    if (observed.status !== 'complete' || record(record(observed.container).State).Running !== true) throw new Error('native worker Engine facts are incomplete or mismatched');
    const init = record(record(await this.waitFile('worker-identity.json', signal)).oci_init);
    if (init.pid !== 1 || init.sha256 !== '43e9b836ca7631672f12d0610cd574875b62d236dfd62e3b86751f35862e5eba' || typeof init.comm !== 'string' || !init.comm || typeof init.executable !== 'string') throw new Error('actual stock OCI init identity is unqualified');
    if (ready.ready !== true || record(ready.robot).name !== 'rr-native-probe') throw new Error('native world/robot readiness is absent');
    return {ready: true, evidenceRefs: [await reference(join(this.output, 'ready.json')),
      await reference(join(this.output, 'worker-identity.json'))]};
  }
  async measure(signal: AbortSignal): Promise<Record<string, unknown>> {
    await this.ready(signal);
    const gate = await this.compose.run(['run', '--rm', '--no-deps', 'webots-signal'], signal);
    if (!gate.ok) throw new Error(gate.diagnostic ?? 'finite native measurement producer failed');
    const result = await this.waitFile('worker-result.json', signal);
    if (result.status !== 'completed' || result.processes_reaped !== true || result.evidence_exported_before_stop !== true) throw new Error(String(result.diagnostic ?? 'native measurement/capture did not complete'));
    return result;
  }
  async exportEvidence(signal: AbortSignal): Promise<ArtifactRef[]> {
    const result = await this.waitFile('worker-result.json', signal);
    if (result.evidence_exported_before_stop !== true) throw new Error('native payload export is not confirmed');

    const names = ['worker-result.json', 'controller-result.json', 'last-native-state.json', 'ready.json', 'worker-identity.json', 'oci-init.json', 'engine-readiness.json', 'renderer.txt', 'packages.tsv', 'binaries.sha256', 'controller.log', 'webots.log', 'xvfb.log'];
    if (this.config.mode === 'offscreen-camera') names.push('camera.bgra', 'camera.png');
    return Promise.all(names.map(name => reference(join(this.output, name))));
  }
}
export default WebotsNative;
