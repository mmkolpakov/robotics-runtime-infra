import {isAbsolute} from 'node:path';

import type {JobRequest,JobResult,Jobs} from '@robotics-runtime/host';

export type FiniteJobRequest = JobRequest;
export type FiniteJobResult = JobResult;
export type FiniteJobs = Pick<Jobs,'run'>;

export interface ComposeOptions {
  executable: string;
  socketPath: string;
  projectName: string;
  files: readonly string[];
  profiles?: readonly string[];
  cwd: string;
  env?: Readonly<Record<string, string>>;
  timeoutMs?: number;
  maxBufferBytes?: number;
}
const commands = new Set(['version', 'config', 'up', 'run', 'logs', 'ps', 'stop', 'down', 'pull', 'wait', 'exec']);
const forbidden = /^(?:(?:--project-name|--project-directory|--file|--context|--host|--profile)(?:=|$)|-[pf])/;

const argumentOptions = new Set(['--name','--entrypoint','--user','--workdir','--index','--env','--volume','--label','--publish','-u','-w','-e','-v','-l']);
function composeArguments(args:readonly string[]):readonly string[] {
  if(args[0]!=='run' && args[0]!=='exec') return args;
  for(let index=1;index<args.length;index++) {
    const token=args[index]!;
    if(token==='--') return args.slice(0,index);
    if(!token.startsWith('-')) return args.slice(0,index+1);
    if(argumentOptions.has(token)) index++;
  }
  return args;
}
export class ComposeExecution {
  constructor(private readonly jobs: FiniteJobs, private readonly options: ComposeOptions) {
    if (!/^[a-z0-9][a-z0-9_-]{1,62}$/.test(options.projectName)) throw new Error('invalid owned Compose project');
    if (![options.executable, options.socketPath, options.cwd, ...options.files].every(isAbsolute)) throw new Error('Compose paths must be absolute');
    this.options = {...options, files: [...options.files], profiles: [...options.profiles ?? []], env: {...options.env}};
    if ((options.profiles ?? []).some(p => !/^[a-zA-Z0-9][a-zA-Z0-9_.-]*$/.test(p))) throw new Error('invalid owned Compose profile');
    if (!options.files.length) throw new Error('an immutable Compose file is required');
    if (Object.keys(options.env ?? {}).some(k => ['DOCKER_HOST', 'DOCKER_CONTEXT', 'DOCKER_TLS_VERIFY', 'DOCKER_CERT_PATH'].includes(k))) throw new Error('endpoint environment is host-owned');
  }
  async run(args: readonly string[], cancelSignal?: AbortSignal): Promise<FiniteJobResult> {
    if (!commands.has(args[0] ?? '') || composeArguments(args).some(a => forbidden.test(a))) throw new Error('command cannot replace the owned Compose project or endpoint');
    return this.jobs.run({
      executable: this.options.executable,
      args: ['--project-name', this.options.projectName, ...this.options.files.flatMap(p => ['--file', p]), ...(this.options.profiles ?? []).flatMap(p => ['--profile', p]), ...args],
      cwd: this.options.cwd,
      timeoutMs: this.options.timeoutMs ?? 120_000,
      maxBufferBytes: this.options.maxBufferBytes ?? 1_048_576,
      cancelSignal,
      env: {PATH: '/usr/local/bin:/usr/bin:/bin', ...this.options.env, DOCKER_HOST: `unix://${this.options.socketPath}`, DOCKER_CONFIG: '/nonexistent'},
      extendEnv: false,
    });
  }
  async requireVersion(): Promise<FiniteJobResult> {
    const result = await this.run(['version', '--short']);
    if (!result.ok || result.stdout.trim() !== '5.3.1') throw new Error(`Compose 5.3.1 required: ${result.diagnostic ?? result.stdout}`);
    return result;
  }
}
