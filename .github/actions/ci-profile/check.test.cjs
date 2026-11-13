'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const {validate} = require('./check.cjs');
const sha = 'a'.repeat(40);
const base = {
  executor: 'home', architecture: 'x64', trust: 'software',
  runnerEnvironment: 'self-hosted', runnerOs: 'Linux', runnerArch: 'X64',
  eventName: 'push', repository: 'owner/repo', ref: 'refs/heads/main', sha,
};
const event = {repository: {full_name: 'owner/repo'}, after: sha};
test('hosted default preserves the hosted runner contract', () => {
  validate({...base, executor: 'hosted', runnerEnvironment: 'github-hosted'}, {});
});
test('home admits the exact trusted push and architecture', () => {
  validate(base, event);
  validate({...base, architecture: 'arm64', runnerArch: 'ARM64'}, event);
});
for (const [title, delta, changedEvent] of [
  ['unknown executor', {executor:'hom'}, event],
  ['silent hosted fallback', {runnerEnvironment:'github-hosted'}, event],
  ['wrong OS', {runnerOs:'Windows'}, event],
  ['wrong architecture', {runnerArch:'ARM64'}, event],
  ['missing commit', {sha:undefined}, event],
  ['foreign event repository', {}, {...event, repository:{full_name:'other/repo'}}],
  ['changed push commit', {}, {...event, after:'b'.repeat(40)}],
  ['tag is not a software home push', {ref:'refs/tags/v1'}, event],
  ['unknown event', {eventName:'workflow_run'}, event],
  ['pull request target', {eventName:'pull_request_target'}, event],
  ['unadmitted home provenance', {trust:'github-provenance'}, event],
]) test('refuses ' + title, () => assert.throws(() => validate({...base, ...delta}, changedEvent)));
const pullRequest = {
  ...event, pull_request:{head:{repo:{full_name:'owner/repo'},sha},base:{repo:{full_name:'owner/repo'}}},
};
test('same-repository PR retains its merge ref', () => {
  validate({...base,eventName:'pull_request',ref:'refs/pull/4/merge'}, pullRequest);
});
test('fork PR is refused, including spoofed display identity', () => {
  assert.throws(() => validate({...base,eventName:'pull_request',ref:'refs/pull/4/merge'},
    {...pullRequest,pull_request:{...pullRequest.pull_request,head:{repo:{full_name:'other/repo'},sha}}}));
});
test('dispatch and schedule require main even in the same repository', () => {
  for (const eventName of ['workflow_dispatch','schedule']) {
    validate({...base,eventName},event);
    assert.throws(() => validate({...base,eventName,ref:'refs/heads/feature'},event));
  }
});
test('merge group requires both exact source coordinates', () => {
  const ref='refs/heads/gh-readonly-queue/main/pr-4';
  validate({...base,eventName:'merge_group',ref},{...event,merge_group:{head_ref:ref,head_sha:sha}});
  assert.throws(() => validate({...base,eventName:'merge_group',ref},
    {...event,merge_group:{head_ref:ref,head_sha:'b'.repeat(40)}}));
});
