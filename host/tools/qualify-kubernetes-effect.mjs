import assert from 'node:assert/strict';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { randomUUID } from 'node:crypto';
import { Writable } from 'node:stream';
import {
  KubeConfig,
  CoreV1Api,
  BatchV1Api,
  StorageV1Api,
  CoordinationV1Api,
  RbacAuthorizationV1Api,
  Exec,
} from '@kubernetes/client-node';
import { Context, Jobs, referenceFile } from '@robotics-runtime/host';
import { KubernetesExecution } from '../dist/src/kubernetes-execution.js';
const [configPath, destination] = process.argv.slice(2);
assert.ok(configPath && destination, 'private kubeconfig and report directory required');
const config = new KubeConfig();
config.loadFromFile(resolve(configPath));
const core = config.makeApiClient(CoreV1Api),
  batch = config.makeApiClient(BatchV1Api),
  storage = config.makeApiClient(StorageV1Api),
  leases = config.makeApiClient(CoordinationV1Api),
  rbac = config.makeApiClient(RbacAuthorizationV1Api);
const id = randomUUID().slice(0, 12),
  namespace = 'rr-effect-' + id,
  sc = 'rr-effect-' + id,
  labels = { 'robotics-runtime.dev/fixture-owner': id };
const bindings = {
  'run-id': 'run-' + id,
  'domain-id': 'software',
  'profile-id': 'kind-cpu',
  'profile-sha256': '17'.repeat(32),
};
const annotations = Object.fromEntries(
  Object.entries(bindings).map(([key, value]) => ['robotics-runtime.dev/' + key, value])
);
const report = {
  scope:
    'isolated Kubernetes CPU API, effect admission and retained bytes; not EKS, GPU, simulator or robot qualification',
  steps: [],
};
const image =
  'docker.io/library/node@sha256:b64fccfbcd1ae10d11b969a868b50e1c2530a7054813d5cdea04ac3bce551697';
const signal = () => AbortSignal.timeout(30000);
const pause = () => new Promise((resolve) => setTimeout(resolve, 100));
const wait = async (check) => {
  for (let n = 0; n < 300; n++) {
    const value = await check();
    if (value) return value;
    await pause();
  }
  throw new Error('finite native fixture wait expired');
};
const exec = async (pod, code) => {
  let out = '',
    err = '',
    settled = false,
    ws;
  return await new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      ws?.terminate();
      reject(new Error('bounded native exec expired'));
    }, 10000);
    const finish = (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      ws?.close();
      if (error) reject(error);
      else resolve(out);
    };
    const stdout = new Writable({
      write(chunk, encoding, next) {
        out += chunk.toString();
        if (out.length > 1048576) finish(new Error('native output limit'));
        next();
      },
    });
    const stderr = new Writable({
      write(chunk, encoding, next) {
        err += chunk.toString();
        if (err.length > 1048576) finish(new Error('native error limit'));
        next();
      },
    });
    new Exec(config)
      .exec(namespace, pod, 'worker', ['node', '-e', code], stdout, stderr, null, false, (status) =>
        finish(status.status === 'Success' ? undefined : new Error('native exec failed'))
      )
      .then((socket) => {
        ws = socket;
        socket.on('error', () => finish(new Error('native exec transport failed')));
        socket.on('close', () => {
          if (!settled) finish(new Error('native exec closed without status'));
        });
      })
      .catch(finish);
  });
};
const podFor = async (job, excluded) =>
  await wait(async () => {
    const pods = await core.listNamespacedPod({
      namespace,
      labelSelector: 'batch.kubernetes.io/controller-uid=' + job.metadata.uid,
    });
    return pods.items.find(
      (p) =>
        p.metadata.uid !== excluded &&
        !p.metadata.deletionTimestamp &&
        p.status?.phase === 'Running' &&
        p.status.containerStatuses?.every((c) => c.ready)
    );
  });
// One controller retry is deliberately allowed only in this replacement fault fixture.
const jobBody = (name = 'attempt') => ({
  apiVersion: 'batch/v1',
  kind: 'Job',
  metadata: { name, namespace, labels, annotations },
  spec: {
    parallelism: 1,
    completions: 1,
    backoffLimit: 1,
    podReplacementPolicy: 'Failed',
    activeDeadlineSeconds: 900,
    template: {
      metadata: { labels, annotations },
      spec: {
        restartPolicy: 'Never',
        automountServiceAccountToken: false,
        terminationGracePeriodSeconds: 1,
        containers: [
          {
            name: 'worker',
            image,
            imagePullPolicy: 'IfNotPresent',
            command: ['node', '-e', 'setInterval(()=>{},1000)'],
            resources: {
              requests: { cpu: '10m', memory: '32Mi' },
              limits: { cpu: '250m', memory: '128Mi' },
            },
            volumeMounts: [{ name: 'retained', mountPath: '/retained' }],
          },
        ],
        volumes: [{ name: 'retained', persistentVolumeClaim: { claimName: 'spool' } }],
      },
    },
  },
});
const context = new Context();
await context
  .plugin(Jobs, { timeoutMs: 30000, maxBufferBytes: 1048576, killTimeoutMs: 2000 })
  .await();
let namespaceUID, scUID;
await mkdir(destination, { recursive: true, mode: 0o700 });
try {
  const ns = await core.createNamespace({
    body: { apiVersion: 'v1', kind: 'Namespace', metadata: { name: namespace, labels } },
  });
  namespaceUID = ns.metadata.uid;
  const storageClass = await storage.createStorageClass({
    body: {
      apiVersion: 'storage.k8s.io/v1',
      kind: 'StorageClass',
      metadata: { name: sc, labels },
      provisioner: 'rancher.io/local-path',
      reclaimPolicy: 'Retain',
      volumeBindingMode: 'WaitForFirstConsumer',
    },
  });
  scUID = storageClass.metadata.uid;
  const pvc = await core.createNamespacedPersistentVolumeClaim({
    namespace,
    body: {
      apiVersion: 'v1',
      kind: 'PersistentVolumeClaim',
      metadata: { name: 'spool', namespace, labels, annotations },
      spec: {
        accessModes: ['ReadWriteOnce'],
        storageClassName: sc,
        resources: { requests: { storage: '64Mi' } },
      },
    },
  });
  const lease = await leases.createNamespacedLease({
    namespace,
    body: {
      apiVersion: 'coordination.k8s.io/v1',
      kind: 'Lease',
      metadata: { name: 'effect', namespace, labels, annotations },
      spec: {},
    },
  });
  const job = await batch.createNamespacedJob({ namespace, body: jobBody() });
  let pod = await podFor(job);
  const binding = {
    namespace,
    job: { name: 'attempt', uid: job.metadata.uid },
    pod: { name: pod.metadata.name, uid: pod.metadata.uid },
    pvc: { name: 'spool', uid: pvc.metadata.uid },
    lease: { name: 'effect', uid: lease.metadata.uid },
    bindings,
    storageProfile: 'kind-local-path-rwo',
    storageClass: sc,
  };
  const consumer = new KubernetesExecution(config, binding);
  await consumer.inspect(signal());
  await exec(
    pod.metadata.name,
    'require("fs").writeFileSync("/retained/count","0");require("fs").writeFileSync("/retained/original","native-original-bytes\\n")'
  );
  const effect = () =>
    exec(
      pod.metadata.name,
      'const f=require("fs");const n=Number(f.readFileSync("/retained/count","utf8"))+1;f.writeFileSync("/retained/count",String(n));console.log(n)'
    );
  const outcomes = await Promise.all([
    consumer.initiate(effect, signal()),
    consumer.initiate(effect, signal()),
  ]);
  assert.equal(outcomes.filter((r) => r.status === 'admitted').length, 1);
  assert.ok(outcomes.every((r) => ['admitted', 'refused'].includes(r.status)));
  assert.equal(
    await exec(
      pod.metadata.name,
      'process.stdout.write(require("fs").readFileSync("/retained/count"))'
    ),
    '1'
  );
  assert.equal((await consumer.initiate(effect, signal())).status, 'refused');
  report.steps.push({
    name: 'simultaneous-CAS-and-same-Pod-repeat-admit-one-initiation',
    passed: true,
    outcomes,
  });
  await core.deleteNamespacedPod({
    namespace,
    name: pod.metadata.name,
    body: { preconditions: { uid: pod.metadata.uid }, gracePeriodSeconds: 0 },
  });
  pod = await podFor(job, binding.pod.uid);
  assert.notEqual(pod.metadata.uid, binding.pod.uid);
  const replacement = new KubernetesExecution(config, {
    ...binding,
    pod: { name: pod.metadata.name, uid: pod.metadata.uid },
  });
  const refused = await replacement.initiate(
    () => exec(pod.metadata.name, 'require("fs").writeFileSync("/retained/count","2")'),
    signal()
  );
  assert.equal(refused.status, 'refused');
  assert.equal(
    await exec(
      pod.metadata.name,
      'process.stdout.write(require("fs").readFileSync("/retained/count"))'
    ),
    '1'
  );
  report.steps.push({
    name: 'actual-replacement-Pod-retained-Lease-refuses-effect-replay',
    passed: true,
    oldPodUID: binding.pod.uid,
    replacementPodUID: pod.metadata.uid,
    outcome: refused,
  });
  const currentBinding = { ...binding, pod: { name: pod.metadata.name, uid: pod.metadata.uid } };
  const freshLease = await leases.createNamespacedLease({
    namespace,
    body: {
      apiVersion: 'coordination.k8s.io/v1',
      kind: 'Lease',
      metadata: { name: 'ack-loss', namespace, labels, annotations },
      spec: {},
    },
  });
  const lost = new KubernetesExecution(config, {
    ...currentBinding,
    lease: { name: 'ack-loss', uid: freshLease.metadata.uid },
  });
  const originalReplace = lost.coordination.replaceNamespacedLease.bind(lost.coordination);
  lost.coordination.replaceNamespacedLease = async (...args) => {
    await originalReplace(...args);
    throw new Error('test transport acknowledgement lost after committed response');
  };
  const ack = await lost.initiate(
    () => exec(pod.metadata.name, 'require("fs").writeFileSync("/retained/count","3")'),
    signal()
  );
  assert.equal(ack.status, 'unknown');
  assert.ok(
    (await leases.readNamespacedLease({ namespace, name: 'ack-loss' })).spec.holderIdentity
  );
  assert.equal(
    await exec(
      pod.metadata.name,
      'process.stdout.write(require("fs").readFileSync("/retained/count"))'
    ),
    '1'
  );
  assert.equal((await lost.initiate(() => Promise.resolve('never'), signal())).status, 'refused');
  report.steps.push({
    name: 'real-committed-CAS-with-lost-client-ack-is-unknown-no-retry',
    passed: true,
    outcome: ack,
  });
  await leases.deleteNamespacedLease({
    namespace,
    name: 'ack-loss',
    body: { preconditions: { uid: freshLease.metadata.uid } },
  });
  const recreated = await leases.createNamespacedLease({
    namespace,
    body: {
      apiVersion: 'coordination.k8s.io/v1',
      kind: 'Lease',
      metadata: { name: 'ack-loss', namespace, labels, annotations },
      spec: {},
    },
  });
  assert.notEqual(recreated.metadata.uid, freshLease.metadata.uid);
  let called = false;
  assert.equal(
    (
      await lost.initiate(async () => {
        called = true;
      }, signal())
    ).status,
    'unknown'
  );
  assert.equal(called, false);
  report.steps.push({
    name: 'deleted-recreated-Lease-name-cannot-rearm-old-UID-binding',
    passed: true,
    oldUID: freshLease.metadata.uid,
    newUID: recreated.metadata.uid,
  });
  const pendingLease = await leases.createNamespacedLease({
    namespace,
    body: {
      apiVersion: 'coordination.k8s.io/v1',
      kind: 'Lease',
      metadata: {
        name: 'pending',
        namespace,
        labels,
        annotations,
        finalizers: ['robotics-runtime.dev/fixture-retain'],
      },
      spec: {},
    },
  });
  await leases.deleteNamespacedLease({
    namespace,
    name: 'pending',
    body: { preconditions: { uid: pendingLease.metadata.uid } },
  });
  const pendingConsumer = new KubernetesExecution(config, {
    ...currentBinding,
    lease: { name: 'pending', uid: pendingLease.metadata.uid },
  });
  let pendingEffect = false;
  await assert.rejects(() => pendingConsumer.inspect(signal()), /being deleted/);
  assert.equal(
    (
      await pendingConsumer.initiate(async () => {
        pendingEffect = true;
      }, signal())
    ).status,
    'unknown'
  );
  assert.equal(pendingEffect, false);
  const pendingActual = await leases.readNamespacedLease({ namespace, name: 'pending' });
  assert.ok(pendingActual.metadata.deletionTimestamp);
  pendingActual.metadata.finalizers = [];
  await leases.replaceNamespacedLease({ namespace, name: 'pending', body: pendingActual });
  report.steps.push({
    name: 'actual-deletion-pending-Lease-refuses-before-native-initiation',
    passed: true,
    uid: pendingLease.metadata.uid,
  });
  const account = await core.createNamespacedServiceAccount({
    namespace,
    body: {
      apiVersion: 'v1',
      kind: 'ServiceAccount',
      metadata: { name: 'consumer', namespace, labels },
      automountServiceAccountToken: false,
    },
  });
  await rbac.createNamespacedRole({
    namespace,
    body: {
      apiVersion: 'rbac.authorization.k8s.io/v1',
      kind: 'Role',
      metadata: { name: 'consumer', namespace, labels },
      rules: [
        {
          apiGroups: ['coordination.k8s.io'],
          resources: ['leases'],
          resourceNames: ['effect'],
          verbs: ['get', 'update'],
        },
      ],
    },
  });
  await rbac.createNamespacedRoleBinding({
    namespace,
    body: {
      apiVersion: 'rbac.authorization.k8s.io/v1',
      kind: 'RoleBinding',
      metadata: { name: 'consumer', namespace, labels },
      subjects: [{ kind: 'ServiceAccount', name: 'consumer', namespace }],
      roleRef: { apiGroup: 'rbac.authorization.k8s.io', kind: 'Role', name: 'consumer' },
    },
  });
  const token = await core.createNamespacedServiceAccountToken({
    namespace,
    name: 'consumer',
    body: {
      apiVersion: 'authentication.k8s.io/v1',
      kind: 'TokenRequest',
      spec: { audiences: [], expirationSeconds: 600 },
    },
  });
  const restricted = new KubeConfig();
  restricted.loadFromOptions({
    clusters: [config.getCurrentCluster()],
    users: [{ name: 'fixture-consumer', token: token.status.token }],
    contexts: [
      {
        name: 'fixture-consumer',
        cluster: config.getCurrentCluster().name,
        user: 'fixture-consumer',
        namespace,
      },
    ],
    currentContext: 'fixture-consumer',
  });
  const permitted = restricted.makeApiClient(CoordinationV1Api),
    restrictedCore = restricted.makeApiClient(CoreV1Api);
  const readLease = await permitted.readNamespacedLease({ namespace, name: 'effect' });
  assert.equal(readLease.metadata.uid, lease.metadata.uid);
  assert.equal(
    (await permitted.replaceNamespacedLease({ namespace, name: 'effect', body: readLease }))
      .metadata.uid,
    lease.metadata.uid
  );
  const forbidden = async (action) => {
    await assert.rejects(action, (error) => error.code === 403);
  };
  await forbidden(() => permitted.readNamespacedLease({ namespace, name: 'ack-loss' }));
  await forbidden(() =>
    permitted.deleteNamespacedLease({
      namespace,
      name: 'effect',
      body: { preconditions: { uid: lease.metadata.uid } },
    })
  );
  await forbidden(() => restrictedCore.listNamespacedSecret({ namespace }));
  assert.equal(pod.spec.automountServiceAccountToken, false);
  report.steps.push({
    name: 'actual-consumer-token-named-Lease-get-update-only-and-worker-token-disabled',
    passed: true,
    accountUID: account.metadata.uid,
  });
  const exportPath = resolve(destination, 'original.bin'),
    expected = Buffer.from('native-original-bytes\n');
  // Native SDK export is captured below; the finite Jobs export copies those exact bytes.
  const original = await exec(
    pod.metadata.name,
    'process.stdout.write(require("fs").readFileSync("/retained/original"))'
  );
  assert.equal(original, expected.toString());
  await writeFile(resolve(destination, 'native-export.bin'), original, { mode: 0o400 });
  const ref = await referenceFile(resolve(destination, 'native-export.bin'));
  const fail = await replacement.exportAndDelete(
    context.jobs,
    { executable: '/usr/bin/false', args: [], timeoutMs: 2000, maxBufferBytes: 1048576 },
    [ref],
    signal()
  );
  assert.equal(fail.resources, 'retained');
  assert.equal(
    (await batch.readNamespacedJob({ namespace, name: 'attempt' })).metadata.uid,
    job.metadata.uid
  );
  assert.equal(
    (await core.readNamespacedPersistentVolumeClaim({ namespace, name: 'spool' })).metadata.uid,
    pvc.metadata.uid
  );
  assert.equal(
    await exec(
      pod.metadata.name,
      'process.stdout.write(require("fs").readFileSync("/retained/original"))'
    ),
    original
  );
  report.steps.push({
    name: 'failed-finite-export-keeps-exact-Job-PVC-and-original-bytes',
    passed: true,
    outcome: fail,
  });
  const hung = await replacement.exportAndDelete(
    context.jobs,
    {
      executable: process.execPath,
      args: ['-e', 'process.on("SIGTERM",()=>{});setInterval(()=>{},1000)'],
      timeoutMs: 200,
      maxBufferBytes: 1048576,
    },
    [ref],
    signal()
  );
  assert.equal(hung.resources, 'retained');
  assert.equal(
    (await batch.readNamespacedJob({ namespace, name: 'attempt' })).metadata.uid,
    job.metadata.uid
  );
  report.steps.push({
    name: 'hanging-export-is-bounded-by-existing-Jobs-without-deleting-Job-or-PVC',
    passed: true,
    outcome: hung,
  });
  const foreignPVC = new KubernetesExecution(config, {
    ...currentBinding,
    pvc: { name: 'spool', uid: 'foreign-uid' },
  });
  await assert.rejects(
    () =>
      foreignPVC.exportAndDelete(
        context.jobs,
        { executable: '/bin/false', args: [], timeoutMs: 1000, maxBufferBytes: 1048576 },
        [ref],
        signal()
      ),
    /foreign Kubernetes object identity/
  );
  assert.equal(
    (await core.readNamespacedPersistentVolumeClaim({ namespace, name: 'spool' })).metadata.uid,
    pvc.metadata.uid
  );
  report.steps.push({
    name: 'foreign-PVC-UID-refuses-export-and-cleanup-before-native-effects',
    passed: true,
  });
  const concurrentChange = new KubernetesExecution(config, currentBinding);
  const originalDelete = concurrentChange.batch.deleteNamespacedJob.bind(concurrentChange.batch);
  concurrentChange.batch.deleteNamespacedJob = async (...args) => {
    const changed = await batch.readNamespacedJob({ namespace, name: 'attempt' });
    changed.metadata.annotations['robotics-runtime.dev/fixture-concurrent-change'] = 'true';
    await batch.replaceNamespacedJob({ namespace, name: 'attempt', body: changed });
    return originalDelete(...args);
  };
  await assert.rejects(
    () =>
      concurrentChange.exportAndDelete(
        context.jobs,
        {
          executable: '/bin/cp',
          args: ['--', resolve(destination, 'native-export.bin'), exportPath],
          timeoutMs: 2000,
          maxBufferBytes: 1048576,
        },
        [{ ...ref, uri: new URL('file://' + exportPath).href }],
        signal()
      ),
    (error) => error.code === 409
  );
  assert.equal(
    (await batch.readNamespacedJob({ namespace, name: 'attempt' })).metadata.uid,
    job.metadata.uid
  );
  assert.deepEqual(await readFile(exportPath), expected);
  report.steps.push({
    name: 'actual-concurrent-Job-resourceVersion-change-refuses-atomic-delete',
    passed: true,
  });
  const guarded = await batch.readNamespacedJob({ namespace, name: 'attempt' });
  guarded.metadata.finalizers = ['robotics-runtime.dev/fixture-retain'];
  await batch.replaceNamespacedJob({ namespace, name: 'attempt', body: guarded });
  await assert.rejects(() =>
    replacement.exportAndDelete(
      context.jobs,
      {
        executable: '/usr/bin/cmp',
        args: ['--', resolve(destination, 'native-export.bin'), exportPath],
        timeoutMs: 2000,
        maxBufferBytes: 1048576,
      },
      [{ ...ref, uri: new URL('file://' + exportPath).href }],
      AbortSignal.timeout(3500)
    )
  );
  const held = await batch.readNamespacedJob({ namespace, name: 'attempt' });
  assert.equal(held.metadata.uid, job.metadata.uid);
  assert.ok(held.metadata.deletionTimestamp);
  assert.ok(held.metadata.finalizers.includes('robotics-runtime.dev/fixture-retain'));
  assert.equal(
    (await core.readNamespacedPersistentVolumeClaim({ namespace, name: 'spool' })).metadata.uid,
    pvc.metadata.uid
  );
  assert.deepEqual(await readFile(exportPath), expected);
  await assert.rejects(() => replacement.inspect(signal())); // A deleting Job is never initiation-ready.
  report.steps.push({
    name: 'real-Job-finalizer-prevents-false-release-after-Pods-disappear',
    passed: true,
    jobUID: held.metadata.uid,
    retainedFile: await referenceFile(exportPath),
  });
  // Only the fixture operator removes its own test finalizer; the helper never does.
  held.metadata.finalizers = held.metadata.finalizers.filter(
    (x) => x !== 'robotics-runtime.dev/fixture-retain'
  );
  await batch.replaceNamespacedJob({ namespace, name: 'attempt', body: held });
  await wait(async () => {
    try {
      await batch.readNamespacedJob({ namespace, name: 'attempt' });
      return false;
    } catch (error) {
      if (error.code === 404) return true;
      throw error;
    }
  });
  const successful = await replacement.exportAndDelete(
    context.jobs,
    {
      executable: '/bin/cp',
      args: ['--', resolve(destination, 'native-export.bin'), exportPath],
      timeoutMs: 2000,
      maxBufferBytes: 1048576,
    },
    [{ ...ref, uri: new URL('file://' + exportPath).href }],
    signal()
  );
  assert.equal(successful.resources, 'released');
  assert.equal(successful.nativeFinalState, 'unknown');
  const repeated = await replacement.exportAndDelete(
    context.jobs,
    { executable: '/must/not/run', args: [], timeoutMs: 2000, maxBufferBytes: 1048576 },
    [{ ...ref, uri: new URL('file://' + exportPath).href }],
    signal()
  );
  assert.equal(repeated.resources, 'released');
  const reused = await batch.createNamespacedJob({ namespace, body: jobBody() });
  assert.notEqual(reused.metadata.uid, job.metadata.uid);
  await assert.rejects(
    () =>
      replacement.exportAndDelete(
        context.jobs,
        { executable: '/must/not/run', args: [], timeoutMs: 1000, maxBufferBytes: 1048576 },
        [{ ...ref, uri: new URL('file://' + exportPath).href }],
        signal()
      ),
    /foreign Kubernetes object identity/
  );
  await batch.deleteNamespacedJob({
    namespace,
    name: 'attempt',
    body: { preconditions: { uid: reused.metadata.uid }, propagationPolicy: 'Foreground' },
  });
  await wait(
    async () =>
      !(
        await core.listNamespacedPod({
          namespace,
          labelSelector: 'batch.kubernetes.io/controller-uid=' + reused.metadata.uid,
        })
      ).items.length
  );
  report.steps.push({
    name: 'same-Job-name-reused-with-new-UID-refuses-cleanup-and-export-replay',
    passed: true,
    oldUID: job.metadata.uid,
    newUID: reused.metadata.uid,
  });
  const reader = await core.createNamespacedPod({
    namespace,
    body: {
      apiVersion: 'v1',
      kind: 'Pod',
      metadata: { name: 'reader', namespace, labels },
      spec: {
        restartPolicy: 'Never',
        automountServiceAccountToken: false,
        containers: jobBody().spec.template.spec.containers,
        volumes: jobBody().spec.template.spec.volumes,
      },
    },
  });
  await wait(async () => {
    const p = await core.readNamespacedPod({ namespace, name: 'reader' });
    return p.status?.phase === 'Running' && p.status.containerStatuses?.every((c) => c.ready);
  });
  assert.equal(
    await exec('reader', 'process.stdout.write(require("fs").readFileSync("/retained/original"))'),
    original
  );
  assert.equal(
    await exec('reader', 'process.stdout.write(require("fs").readFileSync("/retained/count"))'),
    '1'
  );
  assert.deepEqual(await readFile(exportPath), expected);
  report.steps.push({
    name: 'UID-precondition-Job-cleanup-leaves-retained-PVC-Lease-bytes-and-unknown-native-outcome',
    passed: true,
    outcome: successful,
  });
  report.passed = true;
} catch (error) {
  report.passed = false;
  report.error = String(error);
  process.exitCode = 1;
  try {
    report.nativeFailure = {
      pods: (await core.listNamespacedPod({ namespace })).items.map((p) => ({
        name: p.metadata.name,
        phase: p.status.phase,
        conditions: p.status.conditions,
        containers: p.status.containerStatuses,
      })),
      claims: (await core.listNamespacedPersistentVolumeClaim({ namespace })).items.map((p) => ({
        name: p.metadata.name,
        status: p.status,
      })),
      events: (await core.listNamespacedEvent({ namespace })).items.map((e) => ({
        reason: e.reason,
        message: e.message,
      })),
    };
  } catch {}
} finally {
  try {
    if (namespaceUID) {
      const actual = await core.readNamespace({ name: namespace });
      assert.equal(actual.metadata.uid, namespaceUID);
      assert.equal(actual.metadata.labels['robotics-runtime.dev/fixture-owner'], id);
      await core.deleteNamespace({
        name: namespace,
        body: { preconditions: { uid: namespaceUID } },
      });
    }
    if (scUID) {
      const actual = await storage.readStorageClass({ name: sc });
      assert.equal(actual.metadata.uid, scUID);
      await storage.deleteStorageClass({ name: sc, body: { preconditions: { uid: scUID } } });
    }
  } catch (error) {
    report.cleanupError = String(error);
    report.passed = false;
    process.exitCode = 1;
  }
  await context.fiber.dispose();
  await writeFile(
    resolve(destination, 'kubernetes-effect.json'),
    JSON.stringify(report, null, 2) + '\n',
    { mode: 0o600 }
  );
  console.log(
    JSON.stringify({
      passed: report.passed,
      error: report.error,
      cleanupError: report.cleanupError,
      steps: report.steps.map((x) => x.name),
    })
  );
}
