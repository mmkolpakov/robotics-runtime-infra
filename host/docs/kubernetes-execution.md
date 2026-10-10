# Kubernetes effect admission and retained output

`KubernetesExecution` uses the official Kubernetes JavaScript client. It binds a run
to the actual namespace, Job, Pod, PVC and Lease UIDs, with matching run, domain and
profile annotations. Kubernetes resource versions are opaque compare-and-swap
tokens; names alone are not an execution identity.

## Initiation

An operator creates an empty, separately retained `coordination.k8s.io/v1` Lease
before the Job. The consumer records its UID. A call to `initiate(callback, signal)`
changes that Lease once, using its observed resource version, and invokes the
callback only after the API acknowledges the exact claim and fresh identity checks
pass. Objects that have begun deletion are refused. A replacement Pod or a second call
from the same Pod cannot reclaim it.

The consumer puts **all native startup effects inside the callback**. Workers that
are started independently must remain passive until the admitted initiation.
A Kubernetes init container, Job `backoffLimit: 0` or `restartPolicy: Never` does not
provide this boundary. Helm deployment and ownership preflight alone are not
proof that a workload observes it.

The claim has no expiration, renewal, reset or takeover. It survives Job cleanup.
A lost acknowledgement, changed identity, interrupted callback or uncertain
outcome remains `unknown`; recovery does not initiate the native action again.
Other authorised actors must not reset this retained claim. The guarantee applies
to calls through initiate by the admitted consumer; administrators can change
these resources and are outside that guarantee.
This admits at most one initiation. It does not guarantee exactly one completed
physical effect or certify robot stop.

Use the existing lifecycle ServiceAccount with named Lease `get` and `update`
permissions. It must not delete or recreate the claim. Native workers do not need
the API token. Operators retain separate permissions for provisioning and cleanup.

## Export and cleanup

`exportAndDelete` runs an explicit finite export through the existing `Jobs`
interface and verifies the retained file bytes before deleting the exact Job with
UID and resource-version preconditions. It waits for the Job and its Pods to disappear,
then checks that
the original PVC, Lease and exported files still exist. A failed export leaves the
Job and retained objects available. A finalizer-held Job cannot be reported as released
when its Pods are gone.
The consumer supplies the native exporter;
this module does not invent a simulator-specific archive conversion.

Repeated cleanup of an absent Job verifies its retained identities and bytes
without running the exporter again. A reused Job name, foreign Pod, replaced
PVC or replaced Lease refuses cleanup. Resource deletion is reported separately
from native final state, which remains unknown without a native acknowledgement.

Pass an overall deadline signal. Use a bounded operating-system execution profile
for the caller and exporter: an AbortSignal does not bound every filesystem hash
or a synchronous SDK callback. Kubernetes credentials and kubeconfig contents
must not be written to reports.

## Storage profiles

The production storage profile uses encrypted EBS gp3, `ReadWriteOncePod`,
`WaitForFirstConsumer` and `Retain`. The separately declared Kind CPU profile uses
local-path storage with `ReadWriteOnce`; it provides no EBS, GPU, simulator or
hardware qualification.

The retained PVC and Lease have no Job owner reference. Teardown of these retained
objects is an explicit operator decision, separate from routine run cleanup.

The native CPU check is:

```sh
node tools/qualify-kubernetes-effect.mjs /private/kubeconfig /private/results
```

It creates an isolated namespace and storage class, exercises competing claims,
Pod replacement, client acknowledgement loss, UID replacement, finite export
failure, finalizer-held deletion and retention, then removes only its fixtures.
The replacement fault fixture permits one controller retry; the deployment chart
keeps zero backoff. This checks the claim independently of retry policy.

See the upstream [Job execution guarantees](https://kubernetes.io/docs/concepts/workloads/controllers/job/),
[resource versions](https://kubernetes.io/docs/reference/using-api/api-concepts/#resource-versions),
[Lease API](https://kubernetes.io/docs/reference/kubernetes-api/coordination/lease-v1/)
and [persistent volume lifecycle](https://kubernetes.io/docs/concepts/storage/persistent-volumes/).
