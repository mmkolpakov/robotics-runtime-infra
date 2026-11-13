'use strict';
const {readFileSync} = require('node:fs');

function validate(context, event = {}) {
  const {executor, architecture, trust, runnerEnvironment, runnerOs, runnerArch,
    eventName, repository, ref, sha} = context;
  if (!['hosted', 'home'].includes(executor)) throw new Error('CI executor must be hosted or home');
  if (!['x64', 'arm64'].includes(architecture)) throw new Error('Unknown CI architecture');
  if (!['software', 'github-provenance'].includes(trust)) throw new Error('Unknown CI trust scope');
  const expectedEnvironment = executor === 'home' ? 'self-hosted' : 'github-hosted';
  if (runnerEnvironment !== expectedEnvironment) throw new Error('Runner environment differs from the selected executor');
  if (runnerOs !== 'Linux' || runnerArch?.toLowerCase() !== architecture) {
    throw new Error('Runner OS or architecture differs from the job requirement');
  }
  if (executor === 'hosted') return;
  if (trust === 'github-provenance') {
    throw new Error('Home build provenance requires its own admitted trust profile; this job remains blocked');
  }
  if (!/^[^/]+\/[^/]+$/.test(repository || '') || !/^[a-f0-9]{40}$/.test(sha || '')) {
    throw new Error('Home CI requires an exact repository and commit');
  }
  if (event.repository?.full_name !== repository) throw new Error('Event repository does not match this run');
  if (eventName === 'pull_request') {
    if (event.pull_request?.head?.repo?.full_name !== repository ||
        event.pull_request?.base?.repo?.full_name !== repository ||
        !/^[a-f0-9]{40}$/.test(event.pull_request?.head?.sha || '') ||
        !/^refs\/pull\/\d+\/merge$/.test(ref || '')) {
      throw new Error('Home CI does not admit fork pull requests or an unbound PR ref');
    }
    return;
  }
  if (['workflow_dispatch', 'schedule'].includes(eventName)) {
    if (ref !== 'refs/heads/main') throw new Error('Manual and scheduled home CI require main');
    return;
  }
  if (eventName === 'push') {
    if (!/^refs\/heads\//.test(ref || '') || event.after !== sha) {
      throw new Error('Home push must identify the exact branch commit');
    }
    return;
  }
  if (eventName === 'merge_group') {
    if (event.merge_group?.head_sha !== sha || event.merge_group?.head_ref !== ref) {
      throw new Error('Merge-group identity differs from the run');
    }
    return;
  }
  throw new Error('Event is not admitted by the home CI profile');
}

module.exports = {validate};
if (require.main === module) {
  try {
    const context = {
      executor: process.env.INPUT_EXECUTOR,
      architecture: process.env.INPUT_ARCHITECTURE || 'x64',
      trust: process.env.INPUT_TRUST || 'software',
      runnerEnvironment: process.env['INPUT_RUNNER-ENVIRONMENT'],
      runnerOs: process.env.RUNNER_OS, runnerArch: process.env.RUNNER_ARCH,
      eventName: process.env.GITHUB_EVENT_NAME, repository: process.env.GITHUB_REPOSITORY,
      ref: process.env.GITHUB_REF, sha: process.env.GITHUB_SHA,
    };
    const event = context.executor === 'home'
      ? JSON.parse(readFileSync(process.env.GITHUB_EVENT_PATH, 'utf8')) : {};
    validate(context, event);
    process.stdout.write('CI executor: ' + context.executor + '; architecture: ' + context.architecture + '\n');
  } catch (error) {
    process.stderr.write(String(error.message).replace(/[\r\n]/g, ' ') + '\n');
    process.exitCode = 1;
  }
}
