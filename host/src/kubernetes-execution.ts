import { randomUUID } from 'node:crypto';
import {
  KubeConfig,
  BatchV1Api,
  CoreV1Api,
  CoordinationV1Api,
  StorageV1Api,
  Observable,
  type ConfigurationOptions,
  type ObservableMiddleware,
  type V1ObjectMeta,
  type V1Lease,
} from '@kubernetes/client-node';
import { referenceFile, type ArtifactRef } from '@robotics-runtime/host';
import { fileURLToPath } from 'node:url';
import type { FiniteJobs, FiniteJobRequest } from './compose-execution.js';
export interface NamedKubernetesObject {
  name: string;
  uid: string;
}
export interface KubernetesAttempt {
  namespace: string;
  job: NamedKubernetesObject;
  pod: NamedKubernetesObject;
  pvc: NamedKubernetesObject;
  lease: NamedKubernetesObject;
  bindings: Readonly<Record<string, string>>;
  storageProfile: 'eks-gp3-rwop' | 'kind-local-path-rwo';
  storageClass: string;
}
const prefix = 'robotics-runtime.dev/';
function requireValue(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}
function identity(
  metadata: V1ObjectMeta | undefined,
  expected: NamedKubernetesObject,
  namespace: string
) {
  requireValue(
    metadata?.name === expected.name &&
      metadata?.uid === expected.uid &&
      metadata?.namespace === namespace,
    'foreign Kubernetes object identity'
  );
  requireValue(metadata.resourceVersion, 'missing native Kubernetes resourceVersion');
  requireValue(!metadata.deletionTimestamp, 'Kubernetes identity is being deleted');
}
function options(signal: AbortSignal): ConfigurationOptions<ObservableMiddleware> {
  return {
    middlewareMergeStrategy: 'append',
    middleware: [
      {
        pre: (request) => {
          signal.throwIfAborted();
          request.setSignal(signal);
          return new Observable(Promise.resolve(request));
        },
        post: (response) => new Observable(Promise.resolve(response)),
      },
    ],
  };
}
export interface KubernetesInitiation<T> {
  status: 'admitted' | 'refused' | 'unknown';
  value?: T;
  diagnostic?: string;
}
export class KubernetesExecution {
  readonly binding: Readonly<KubernetesAttempt>;
  readonly batch: BatchV1Api;
  readonly core: CoreV1Api;
  readonly coordination: CoordinationV1Api;
  readonly storage: StorageV1Api;
  constructor(config: KubeConfig, binding: KubernetesAttempt) {
    const copy = structuredClone(binding);
    requireValue(
      /^[a-z0-9]([-a-z0-9]*[a-z0-9])?$/.test(copy.namespace) && copy.namespace.length <= 63,
      'invalid Kubernetes namespace'
    );
    for (const object of [copy.job, copy.pod, copy.pvc, copy.lease])
      requireValue(object.name && object.uid, 'actual Kubernetes name/UID required');
    requireValue(
      ['eks-gp3-rwop', 'kind-local-path-rwo'].includes(copy.storageProfile),
      'unsupported declared storage profile'
    );
    requireValue(
      ['run-id', 'domain-id', 'profile-id', 'profile-sha256'].every((key) => copy.bindings[key]),
      'complete native attempt bindings required'
    );
    for (const object of [copy.job, copy.pod, copy.pvc, copy.lease, copy.bindings])
      Object.freeze(object);
    this.binding = Object.freeze(copy);
    const admitted = new KubeConfig();
    admitted.loadFromString(config.exportConfig());
    this.batch = admitted.makeApiClient(BatchV1Api);
    this.core = admitted.makeApiClient(CoreV1Api);
    this.coordination = admitted.makeApiClient(CoordinationV1Api);
    this.storage = admitted.makeApiClient(StorageV1Api);
  }
  private annotated(metadata: V1ObjectMeta | undefined) {
    for (const [key, value] of Object.entries(this.binding.bindings))
      requireValue(
        metadata?.annotations?.[prefix + key] === value,
        'foreign run/domain/profile binding'
      );
  }
  async inspect(signal: AbortSignal) {
    const b = this.binding,
      o = options(signal);
    const [job, pod, pvc, lease, storage] = await Promise.all([
      this.batch.readNamespacedJob({ namespace: b.namespace, name: b.job.name }, o),
      this.core.readNamespacedPod({ namespace: b.namespace, name: b.pod.name }, o),
      this.core.readNamespacedPersistentVolumeClaim(
        { namespace: b.namespace, name: b.pvc.name },
        o
      ),
      this.coordination.readNamespacedLease({ namespace: b.namespace, name: b.lease.name }, o),
      this.storage.readStorageClass({ name: b.storageClass }, o),
    ]);
    for (const [actual, expected] of [
      [job.metadata, b.job],
      [pod.metadata, b.pod],
      [pvc.metadata, b.pvc],
      [lease.metadata, b.lease],
    ] as const) {
      identity(actual, expected, b.namespace);
      this.annotated(actual);
    }
    requireValue(
      pod.metadata?.ownerReferences?.some(
        (owner) =>
          owner.kind === 'Job' &&
          owner.name === b.job.name &&
          owner.uid === b.job.uid &&
          owner.controller === true
      ),
      'Pod is not owned by exact Job'
    );
    requireValue(
      !pvc.metadata?.ownerReferences?.length && !lease.metadata?.ownerReferences?.length,
      'retained control or PVC has garbage-collection owner'
    );
    requireValue(
      pvc.status?.phase === 'Bound' && pvc.spec?.storageClassName === b.storageClass,
      'retained PVC is not bound to admitted storage'
    );
    const access = b.storageProfile === 'eks-gp3-rwop' ? 'ReadWriteOncePod' : 'ReadWriteOnce';
    requireValue(
      pvc.spec.accessModes?.length === 1 && pvc.spec.accessModes[0] === access,
      'wrong explicit PVC access mode'
    );
    requireValue(
      storage.metadata?.name === b.storageClass &&
        storage.reclaimPolicy === 'Retain' &&
        storage.volumeBindingMode === 'WaitForFirstConsumer',
      'unsafe retained storage lifetime'
    );
    if (b.storageProfile === 'eks-gp3-rwop')
      requireValue(
        storage.provisioner === 'ebs.csi.aws.com' &&
          storage.parameters?.type === 'gp3' &&
          storage.parameters.encrypted === 'true',
        'unsupported encrypted EBS profile'
      );
    else
      requireValue(
        storage.provisioner === 'rancher.io/local-path',
        'unsupported separate kind CPU storage'
      );
    requireValue(
      pod.spec?.volumes?.some((volume) => volume.persistentVolumeClaim?.claimName === b.pvc.name),
      'Pod does not mount admitted PVC'
    );
    requireValue(
      lease.spec?.leaseDurationSeconds === undefined && lease.spec?.renewTime === undefined,
      'effect claim cannot expire or renew'
    );
    return { job, pod, pvc, lease, storage };
  }
  /** One admitted initiation. No reset, expiry, takeover or retry after uncertain commit. */
  async initiate<T>(
    effect: () => Promise<T>,
    signal: AbortSignal
  ): Promise<KubernetesInitiation<T>> {
    let claimed = false;
    try {
      const observed = await this.inspect(signal),
        b = this.binding;
      if (observed.lease.spec?.holderIdentity)
        return {
          status: 'refused',
          diagnostic: 'native initiation already claimed; original outcome may be unknown',
        };
      const holder = b.pod.uid + ':' + randomUUID();
      const body: V1Lease = {
        apiVersion: 'coordination.k8s.io/v1',
        kind: 'Lease',
        metadata: observed.lease.metadata,
        spec: { holderIdentity: holder },
      };
      const actual = await this.coordination.replaceNamespacedLease(
        { namespace: b.namespace, name: b.lease.name, body },
        options(signal)
      );
      identity(actual.metadata, b.lease, b.namespace);
      requireValue(actual.spec?.holderIdentity === holder, 'effect claim acknowledgement differs');
      claimed = true;
      const fresh = await this.inspect(signal);
      requireValue(fresh.lease.spec?.holderIdentity === holder, 'native initiation claim changed');
      signal.throwIfAborted();
      return { status: 'admitted', value: await effect() };
    } catch (error) {
      const code =
        typeof (error as { code?: unknown })?.code === 'number'
          ? (error as { code: number }).code
          : undefined;
      return {
        status: !claimed && code === 409 ? 'refused' : 'unknown',
        diagnostic: 'native initiation not acknowledged or its outcome is unknown',
      };
    }
  }
  /** Only resource cleanup: exported bytes and retained objects survive; SDK stop is separate. */
  async exportAndDelete(
    jobs: FiniteJobs,
    request: FiniteJobRequest,
    retained: readonly ArtifactRef[],
    signal: AbortSignal
  ) {
    requireValue(
      retained.length > 0 && retained.length <= 4096,
      'finite retained byte references required'
    );
    const b = this.binding;
    const verify = async () => {
      for (const expected of retained) {
        const actual = await referenceFile(fileURLToPath(expected.uri), {
          maxBytes: expected.size_bytes,
        });
        requireValue(
          actual.sha256 === expected.sha256 && actual.size_bytes === expected.size_bytes,
          'retained exported native bytes differ'
        );
      }
    };
    const preserved = async () => {
      const [pvc, lease] = await Promise.all([
        this.core.readNamespacedPersistentVolumeClaim(
          { namespace: b.namespace, name: b.pvc.name },
          options(signal)
        ),
        this.coordination.readNamespacedLease(
          { namespace: b.namespace, name: b.lease.name },
          options(signal)
        ),
      ]);
      identity(pvc.metadata, b.pvc, b.namespace);
      identity(lease.metadata, b.lease, b.namespace);
      this.annotated(pvc.metadata);
      this.annotated(lease.metadata);
      requireValue(
        !pvc.metadata?.ownerReferences?.length && !lease.metadata?.ownerReferences?.length,
        'retained objects gained a cleanup owner'
      );
      await verify();
      return { pvc, lease };
    };
    let observedJob;
    try {
      observedJob = await this.batch.readNamespacedJob(
        { namespace: b.namespace, name: b.job.name },
        options(signal)
      );
    } catch (error) {
      if ((error as { code?: unknown })?.code !== 404) throw error;
      const pods = await this.core.listNamespacedPod(
        {
          namespace: b.namespace,
          labelSelector: 'batch.kubernetes.io/controller-uid=' + b.job.uid,
        },
        options(signal)
      );
      requireValue(pods.items.length === 0, 'owned Kubernetes Pods remain after absent Job');
      const { pvc, lease } = await preserved();
      return {
        resources: 'released' as const,
        nativeFinalState: 'unknown' as const,
        pvcUID: pvc.metadata!.uid,
        leaseUID: lease.metadata!.uid,
        originalPodUID: b.pod.uid,
        retained,
      };
    }
    identity(observedJob.metadata, b.job, b.namespace);
    this.annotated(observedJob.metadata);
    const before = await this.inspect(signal);
    const exported = await jobs.run({ ...request, cancelSignal: signal });
    if (!exported.ok)
      return {
        resources: 'retained' as const,
        nativeFinalState: 'unknown' as const,
        diagnostic: 'finite export refused',
        pvcUID: this.binding.pvc.uid,
      };
    await verify();
    const current = await this.inspect(signal);
    await this.batch.deleteNamespacedJob(
      {
        namespace: b.namespace,
        name: b.job.name,
        body: {
          preconditions: {
            uid: b.job.uid,
            resourceVersion: current.job.metadata!.resourceVersion!,
          },
          propagationPolicy: 'Foreground',
        },
      },
      options(signal)
    );
    const absentJob = async () => {
      try {
        const actual = await this.batch.readNamespacedJob(
          { namespace: b.namespace, name: b.job.name },
          options(signal)
        );
        requireValue(actual.metadata?.uid === b.job.uid, 'Job name reused during cleanup');
        this.annotated(actual.metadata);
        return false;
      } catch (error) {
        if ((error as { code?: unknown })?.code === 404) return true;
        throw error;
      }
    };
    const deadline = performance.now() + 30000;
    let released = false;
    while (performance.now() < deadline) {
      signal.throwIfAborted();
      const [absent, pods] = await Promise.all([
        absentJob(),
        this.core.listNamespacedPod(
          {
            namespace: b.namespace,
            labelSelector: 'batch.kubernetes.io/controller-uid=' + b.job.uid,
          },
          options(signal)
        ),
      ]);
      requireValue(
        pods.items.every((pod) =>
          pod.metadata?.ownerReferences?.some(
            (owner) => owner.uid === b.job.uid && owner.controller === true
          )
        ),
        'foreign labeled Pod during cleanup'
      );
      if (absent && !pods.items.length) {
        released = true;
        break;
      }
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    requireValue(released, 'owned Kubernetes Job or Pods remain');
    requireValue(await absentJob(), 'owned Kubernetes Job remains');
    const remaining = await this.core.listNamespacedPod(
      { namespace: b.namespace, labelSelector: 'batch.kubernetes.io/controller-uid=' + b.job.uid },
      options(signal)
    );
    requireValue(remaining.items.length === 0, 'owned Kubernetes Pods remain');
    const { pvc, lease } = await preserved();
    return {
      resources: 'released' as const,
      nativeFinalState: 'unknown' as const,
      pvcUID: pvc.metadata!.uid,
      leaseUID: lease.metadata!.uid,
      originalPodUID: before.pod.metadata!.uid,
      retained,
    };
  }
}
