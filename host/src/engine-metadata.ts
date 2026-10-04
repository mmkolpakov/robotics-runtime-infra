import Docker from 'dockerode';
import {isAbsolute} from 'node:path';

type RecordValue = Record<string, unknown>;
const object = (v: unknown): RecordValue | undefined => typeof v === 'object' && v !== null && !Array.isArray(v) ? v as RecordValue : undefined;
const api = (v: unknown): number | undefined => typeof v === 'string' && /^1\.\d+$/.test(v) ? Number(v.slice(2)) : undefined;
export interface EngineEndpoint {socketPath: string; operationMinApi: string; operationMaxApi: string}
export interface EngineFacts {endpoint: string; serverApi: string; serverMinApi: string; clientApi: string; versionResponse: unknown}
export interface ContainerRequirement {
  runId: string;
  projectName: string;
  imageDigest?: string;
  imageId?: string;
  mounts: readonly {destination: string; readOnly: boolean; volumeName: string}[];
  hostConfig: Readonly<Record<string, unknown>>;
  user: string;
  networkNamespaceContainerId?: string;
}
export interface MetadataObservation {
  status: 'complete' | 'incomplete';
  missing: string[];
  mismatches: string[];
  engine: EngineFacts;
  container: unknown;
  image: unknown;
  networks: unknown[];
  networkNamespaceContainer?: unknown;
}
export function selectApi(versionResponse: unknown, endpoint: EngineEndpoint): EngineFacts {
  const version = object(versionResponse);
  const high = api(version?.ApiVersion), low = api(version?.MinAPIVersion);
  const max = api(endpoint.operationMaxApi), min = api(endpoint.operationMinApi);
  if (![high, low, max, min].every(v => v !== undefined)) throw new Error('incomplete Engine API range or metadata operation policy');
  const selected = Math.min(high!, max!);
  if (selected < Math.max(low!, min!)) throw new Error('Engine API range and metadata operation policy do not overlap');
  return {endpoint: `unix://${endpoint.socketPath}`, serverApi: version!.ApiVersion as string, serverMinApi: version!.MinAPIVersion as string, clientApi: `1.${selected}`, versionResponse};
}
export class EngineMetadata {
  private constructor(private readonly docker: Docker, private readonly socketPath: string, readonly facts: EngineFacts) {}
  static async connect(endpoint: EngineEndpoint): Promise<EngineMetadata> {
    if (!isAbsolute(endpoint.socketPath)) throw new Error('Engine requires an absolute Unix socket');
    // /version is unversioned discovery. Dockerode does not negotiate client APIs.
    const bootstrap = new Docker({socketPath: endpoint.socketPath});
    const facts = selectApi(await bootstrap.version(), endpoint);
    const docker = new Docker({socketPath: endpoint.socketPath, version: `v${facts.clientApi}`});
    return new EngineMetadata(docker, endpoint.socketPath, facts);
  }
  async rootlessParentMaps(): Promise<{nativeApi: string; uidMap: unknown[]; gidMap: unknown[]; raw: unknown}> {
    const version = object(this.facts.versionResponse);
    const components = Array.isArray(version?.Components) ? version.Components : [];
    const component = components.map(object).find(c => c?.Name === 'Podman Engine');
    const nativeApi = object(component?.Details)?.APIVersion;
    if (nativeApi !== '4.9.3') throw new Error('unqualified native parent namespace API');
    const native = new Docker({socketPath: this.socketPath, version: `v${nativeApi}`});
    const raw = await new Promise<unknown>((resolve, reject) => native.modem.dial({path: '/libpod/info', method: 'GET', statusCodes: {200: true}}, (error: unknown, value: unknown) => error ? reject(error) : resolve(value)));
    const host = object(object(raw)?.host);
    if (object(host?.security)?.rootless !== true) throw new Error('native Engine is not observed rootless');
    const maps = object(host?.idMappings);
    const valid = (v: unknown): v is unknown[] => Array.isArray(v) && v.length > 0 && v.every(row => ['container_id','host_id','size'].every(k => Number.isInteger(object(row)?.[k]) && Number(object(row)?.[k]) >= (k === 'size' ? 1 : 0)));
    if (!valid(maps?.uidmap) || !valid(maps?.gidmap)) throw new Error('incomplete native parent UID/GID maps');
    return {nativeApi, uidMap: maps.uidmap, gidMap: maps.gidmap, raw};
  }
  async remainingOwned(runId: string): Promise<{containers: unknown[]; volumes: unknown; networks: unknown[]}> {
    const filters = {label: [`org.robotics.runtime.run-id=${runId}`]};
    const [containers, volumes, networks] = await Promise.all([this.docker.listContainers({all: true, filters}), this.docker.listVolumes({filters}), this.docker.listNetworks({filters})]);
    return {containers, volumes, networks};
  }
  async inspect(containerId: string, required: ContainerRequirement): Promise<MetadataObservation> {
    if (!/^[a-f0-9]{64}$/.test(containerId)) throw new Error('exact acquired container ID required');
    const container = await this.docker.getContainer(containerId).inspect();
    const imageId = object(container)?.Image;
    const image = typeof imageId === 'string' ? await this.docker.getImage(imageId).inspect() : undefined;
    const networks = object(object(object(container)?.NetworkSettings)?.Networks);
    const networkMode = object(object(container)?.HostConfig)?.NetworkMode;
    const parentId = typeof networkMode === 'string' && /^container:[a-f0-9]{64}$/.test(networkMode) ? networkMode.slice(10) : undefined;
    const networkNamespaceContainer = parentId ? await this.docker.getContainer(parentId).inspect() : undefined;
    const namespaceMode = networkNamespaceContainer ? object(object(networkNamespaceContainer)?.HostConfig)?.NetworkMode : networkMode;
    const namespaceNetworks = networkNamespaceContainer ? object(object(networkNamespaceContainer)?.NetworkSettings)?.Networks : networks;
    const ids = namespaceMode === 'none' ? [] : Object.values(object(namespaceNetworks) ?? {}).map(n => object(n)?.NetworkID).filter((v): v is string => typeof v === 'string' && v.length > 0);
    const networkObjects = await Promise.all(ids.map(id => this.docker.getNetwork(id).inspect().catch((error:unknown)=>({requestedNetworkId:id,inspectionError:String(error)}))));
    return validateObservation(this.facts, container, image, networkObjects, required, networkNamespaceContainer);
  }
}
export function validateObservation(engine: EngineFacts, rawContainer: unknown, rawImage: unknown, networks: unknown[], required: ContainerRequirement, rawNamespaceContainer?: unknown): MetadataObservation {
  const missing: string[] = [], mismatches: string[] = [];
  const c = object(rawContainer), i = object(rawImage);
  const requireField = (parent: RecordValue | undefined, field: string, path: string, check: (v: unknown) => boolean): unknown => {
    const value = parent?.[field];
    if (!check(value)) missing.push(path);
    return value;
  };
  const string = (v: unknown) => typeof v === 'string' && v.length > 0;
  const equal = (actual: unknown, expected: unknown, path: string) => {if (JSON.stringify(actual) !== JSON.stringify(expected)) mismatches.push(path)};
  requireField(c, 'Id', 'container.Id', string);
  const imageId = requireField(c, 'Image', 'container.Image', string);
  equal(requireField(i, 'Id', 'image.Id', string), imageId, 'image.Id');
  if(required.imageId!==undefined) equal(imageId,required.imageId,'container.Image');
  const config = object(c?.Config), state = object(c?.State), hc = object(c?.HostConfig), ns = object(c?.NetworkSettings);
  const labels = object(requireField(config, 'Labels', 'container.Config.Labels', v => object(v) !== undefined));
  equal(requireField(labels, 'org.robotics.runtime.run-id', 'owner.run-id', string), required.runId, 'owner.run-id');
  equal(requireField(labels, 'com.docker.compose.project', 'owner.compose-project', string), required.projectName, 'owner.compose-project');
  equal(requireField(config, 'User', 'container.Config.User', string), required.user, 'container.Config.User');
  requireField(state, 'Status', 'container.State.Status', string);
  requireField(state, 'Running', 'container.State.Running', v => typeof v === 'boolean');
  requireField(state, 'ExitCode', 'container.State.ExitCode', Number.isInteger);
  if (required.imageDigest !== undefined) {
    const digests = requireField(i, 'RepoDigests', 'image.RepoDigests', v => Array.isArray(v) && v.every(string));
    if (!Array.isArray(digests) || !digests.includes(required.imageDigest)) mismatches.push('image.released-digest');
  }
  const mounts = requireField(c, 'Mounts', 'container.Mounts', Array.isArray);
  for (const m of required.mounts) {
    const found = Array.isArray(mounts) ? object(mounts.find(v => object(v)?.Destination === m.destination)) : undefined;
    requireField(found, 'Destination', `mount.${m.destination}.Destination`, string);
    equal(requireField(found, 'RW', `mount.${m.destination}.RW`, v => typeof v === 'boolean'), !m.readOnly, `mount.${m.destination}.RW`);
    equal(requireField(found, 'Type', `mount.${m.destination}.Type`, string), 'volume', `mount.${m.destination}.Type`);
    equal(requireField(found, 'Name', `mount.${m.destination}.Name`, string), m.volumeName, `mount.${m.destination}.Name`);
  }
  for (const [field, expected] of Object.entries(required.hostConfig)) equal(requireField(hc, field, `container.HostConfig.${field}`, v => v !== undefined && v !== null), expected, `container.HostConfig.${field}`);
  const mode = requireField(hc, 'NetworkMode', 'container.HostConfig.NetworkMode', string);
  // service:<name> is an acquired container namespace. Prove its actual parent,
  // ownership and network mode before interpreting a native pseudo-network.
  let namespaceMode=mode;
  let namespaceSettings=ns;
  if(typeof mode==='string' && mode.startsWith('container:')) {
    const parent=object(rawNamespaceContainer), parentConfig=object(parent?.Config);
    const parentId=requireField(parent,'Id','network.namespace-container.Id',string);
    equal(mode,`container:${parentId}`,'network.namespace-container.binding');
    if(required.networkNamespaceContainerId===undefined) missing.push('network.namespace-container.expected-id');
    else equal(parentId,required.networkNamespaceContainerId,'network.namespace-container.expected-id');
    const parentLabels=object(requireField(parentConfig,'Labels','network.namespace-container.Labels',v=>object(v)!==undefined));
    equal(requireField(parentLabels,'org.robotics.runtime.run-id','network.namespace-container.owner',string),required.runId,'network.namespace-container.owner');
    equal(requireField(parentLabels,'com.docker.compose.project','network.namespace-container.project',string),required.projectName,'network.namespace-container.project');
    namespaceMode=requireField(object(parent?.HostConfig),'NetworkMode','network.namespace-container.NetworkMode',string);
    namespaceSettings=object(parent?.NetworkSettings);
    if(typeof namespaceMode==='string' && namespaceMode.startsWith('container:')) missing.push('network.namespace-container.direct-mode');
  } else if(required.networkNamespaceContainerId!==undefined) mismatches.push('network.namespace-container.expected-id');
  requireField(ns,'Networks','container.NetworkSettings.Networks',v=>object(v)!==undefined);
  const usedNetworks=object(requireField(namespaceSettings,'Networks','network.namespace.Networks',v=>object(v)!==undefined));
  if(namespaceMode!=='none' && !Object.keys(usedNetworks??{}).length) missing.push('network.identity');
  for(const [name,value] of Object.entries(namespaceMode==='none'?{}:usedNetworks??{})) {
    const networkId=requireField(object(value),'NetworkID',`network.${name}.NetworkID`,string);
    if(!networks.some(n=>object(n)?.Id===networkId)) missing.push(`network.${name}.inspect`);
  }
  return {status: missing.length || mismatches.length ? 'incomplete' : 'complete', missing, mismatches, engine, container: rawContainer, image: rawImage, networks, networkNamespaceContainer:rawNamespaceContainer};
}
