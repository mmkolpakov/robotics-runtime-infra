import assert from 'node:assert/strict';
import test from 'node:test';
import { KubeConfig } from '@kubernetes/client-node';
import { KubernetesExecution, type KubernetesAttempt } from '../src/kubernetes-execution.js';
const binding = (): KubernetesAttempt => ({
  namespace: 'test-run',
  job: { name: 'job', uid: 'job-uid' },
  pod: { name: 'pod', uid: 'pod-uid' },
  pvc: { name: 'spool', uid: 'pvc-uid' },
  lease: { name: 'effect', uid: 'lease-uid' },
  bindings: {
    'run-id': 'run',
    'domain-id': 'software',
    'profile-id': 'cpu',
    'profile-sha256': '11'.repeat(32),
  },
  storageProfile: 'kind-local-path-rwo',
  storageClass: 'local-retained',
});
const config = () => {
  const config = new KubeConfig();
  config.loadFromOptions({
    clusters: [{ name: 'test', server: 'https://127.0.0.1:1' }],
    users: [{ name: 'test', token: 'test-token' }],
    contexts: [{ name: 'test', cluster: 'test', user: 'test' }],
    currentContext: 'test',
  });
  return config;
};
test('admitted binding and Kubernetes configuration are independent immutable snapshots', () => {
  const input = binding(),
    cfg = config(),
    execution = new KubernetesExecution(cfg, input);
  input.lease.uid = 'replacement';
  input.bindings = { 'run-id': 'foreign' };
  cfg.setCurrentContext('other');
  assert.equal(execution.binding.lease.uid, 'lease-uid');
  assert.equal(execution.binding.bindings['run-id'], 'run');
  assert.ok(
    Object.isFrozen(execution.binding) &&
      Object.isFrozen(execution.binding.lease) &&
      Object.isFrozen(execution.binding.bindings)
  );
});
test('missing actual native identities and incomplete admission bindings refuse before API use', () => {
  for (const key of ['job', 'pod', 'pvc', 'lease'] as const) {
    const input = binding();
    input[key].uid = '';
    assert.throws(() => new KubernetesExecution(config(), input), /actual Kubernetes name\/UID/);
  }
  const input = binding();
  delete (input.bindings as Record<string, string>)['profile-sha256'];
  assert.throws(() => new KubernetesExecution(config(), input), /complete native attempt/);
});
test('unsupported namespace and storage contracts refuse instead of degrading EBS to kind', () => {
  const input = binding();
  input.namespace = 'invalid/name';
  assert.throws(() => new KubernetesExecution(config(), input), /invalid Kubernetes namespace/);
  const unsupported = { ...binding(), storageProfile: 'unqualified' };
  assert.throws(
    () => new KubernetesExecution(config(), unsupported as KubernetesAttempt),
    /unsupported declared storage/
  );
});
