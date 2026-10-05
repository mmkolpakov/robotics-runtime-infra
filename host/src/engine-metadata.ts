import Docker from 'dockerode';
import type {Readable} from 'node:stream';
import {isAbsolute} from 'node:path';

type RecordValue = Record<string, unknown>;
const object = (v: unknown): RecordValue | undefined => typeof v === 'object' && v !== null && !Array.isArray(v) ? v as RecordValue : undefined;
const api = (v: unknown): number | undefined => typeof v === 'string' && /^1\.\d+$/.test(v) ? Number(v.slice(2)) : undefined;
export interface EngineEndpoint {socketPath: string; operationMinApi: string; operationMaxApi: string}
export interface MetadataReadOptions {deadlineMs?:number;cancelSignal?:AbortSignal}
function metadataSignal(options:MetadataReadOptions):AbortSignal {
  const deadlineMs=options.deadlineMs??30000,cancel=options.cancelSignal;
  if(!Number.isSafeInteger(deadlineMs)||deadlineMs<1||deadlineMs>120000) throw new Error('invalid finite native metadata deadline');
  const signal=cancel?AbortSignal.any([cancel,AbortSignal.timeout(deadlineMs)]):AbortSignal.timeout(deadlineMs);
  signal.throwIfAborted();return signal;
}
function readJson<T>(docker:Docker,path:string,signal:AbortSignal,options?:Record<string,unknown>):Promise<T> {
  signal.throwIfAborted();
  return new Promise<T>((resolve,reject)=>docker.modem.dial({path,method:'GET',abortSignal:signal,options,
    statusCodes:{200:true,400:'invalid native metadata request',404:'native metadata is unavailable',500:'Engine metadata read failed'},
  },(error:unknown,value:unknown)=>error?reject(error):resolve(value as T)));
}
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
/** Physical cleanup ownership only; does not replace backend metadata or readiness checks. */
export interface ProjectOwnershipObservation {
  status:'complete'|'incomplete';missing:string[];mismatches:string[];engine:EngineFacts;
  inventory:{containers:unknown[];volumes:unknown;networks:unknown[]};
  containerDetails:unknown[];namespaceParents:unknown[];
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
  static async connect(requestedEndpoint:EngineEndpoint,options:MetadataReadOptions={}):Promise<EngineMetadata> {
    const endpoint={...requestedEndpoint},signal=metadataSignal(options);
    if (!isAbsolute(endpoint.socketPath)) throw new Error('Engine requires an absolute Unix socket');
    // /version is unversioned discovery. Dockerode does not negotiate client APIs.
    const bootstrap = new Docker({socketPath: endpoint.socketPath});
    const facts = selectApi(await readJson(bootstrap,'/version',signal), endpoint);
    signal.throwIfAborted();
    const docker = new Docker({socketPath: endpoint.socketPath, version: `v${facts.clientApi}`});
    return new EngineMetadata(docker, endpoint.socketPath, facts);
  }
  /** Actual deployment metadata from the same selected SDK and Unix endpoint. */
  async deploymentInfo(options:MetadataReadOptions={}):Promise<{engine:EngineFacts;info:unknown}> {
    const signal=metadataSignal(options);
    const info=await readJson(this.docker,'/info',signal);
    signal.throwIfAborted();return {engine:this.facts,info};
  }
  async rootlessParentMaps(options:MetadataReadOptions={}): Promise<{nativeApi: string; uidMap: unknown[]; gidMap: unknown[]; raw: unknown}> {
    const signal=metadataSignal(options);
    const version = object(this.facts.versionResponse);
    const components = Array.isArray(version?.Components) ? version.Components : [];
    const component = components.map(object).find(c => c?.Name === 'Podman Engine');
    const nativeApi = object(component?.Details)?.APIVersion;
    if (nativeApi !== '4.9.3') throw new Error('unqualified native parent namespace API');
    const native = new Docker({socketPath: this.socketPath, version: `v${nativeApi}`});
    const raw=await readJson(native,'/libpod/info',signal);
    signal.throwIfAborted();
    const host = object(object(raw)?.host);
    if (object(host?.security)?.rootless !== true) throw new Error('native Engine is not observed rootless');
    const maps = object(host?.idMappings);
    const valid = (v: unknown): v is unknown[] => Array.isArray(v) && v.length > 0 && v.every(row => ['container_id','host_id','size'].every(k => Number.isInteger(object(row)?.[k]) && Number(object(row)?.[k]) >= (k === 'size' ? 1 : 0)));
    if (!valid(maps?.uidmap) || !valid(maps?.gidmap)) throw new Error('incomplete native parent UID/GID maps');
    return {nativeApi, uidMap: maps.uidmap, gidMap: maps.gidmap, raw};
  }
  async remainingOwned(runId:string,options:MetadataReadOptions={}):Promise<{containers:unknown[];volumes:unknown;networks:unknown[]}> {
    const signal=metadataSignal(options);
    if(!runId) throw new Error('native metadata inventory requires an owner');
    const filters={label:[`org.robotics.runtime.run-id=${runId}`]};
    const [containers,volumes,networks]=await Promise.all([
      readJson<unknown[]>(this.docker,'/containers/json?',signal,{all:true,filters}),
      readJson(this.docker,'/volumes?',signal,{filters}),
      readJson<unknown[]>(this.docker,'/networks?',signal,{filters}),
    ]);
    signal.throwIfAborted();return {containers,volumes,networks};
  }
  /** Discover every resource carrying the project label, including completed one-off containers. */
  async projectOwnership(requestedOwner:{runId:string;projectName:string;networkNamespaceContainerId?:string},options:MetadataReadOptions={}):Promise<ProjectOwnershipObservation> {
    const owner={...requestedOwner},signal=metadataSignal(options);
    if(!owner.runId||!owner.projectName) throw new Error('native project ownership is required');
    const filters={label:[`com.docker.compose.project=${owner.projectName}`]};
    const [rawContainers,volumes,rawNetworks]=await Promise.all([
      readJson(this.docker,'/containers/json?',signal,{all:true,filters}),
      readJson(this.docker,'/volumes?',signal,{filters}),readJson(this.docker,'/networks?',signal,{filters}),
    ]);
    const missing:string[]=[],mismatches:string[]=[],containerDetails:unknown[]=[],namespaceParents:unknown[]=[];
    const containers=Array.isArray(rawContainers)?rawContainers:[],networks=Array.isArray(rawNetworks)?rawNetworks:[];
    if(!Array.isArray(rawContainers))missing.push('project.containers');
    if(!Array.isArray(rawNetworks))missing.push('project.networks');
    const rawVolumes=object(volumes)?.Volumes;
    if(rawVolumes!==null&&!Array.isArray(rawVolumes))missing.push('project.volumes');
    const matches=(labels:unknown,path:string):boolean=>{
      const actual=object(labels);let valid=true;
      for(const [key,expected] of [['org.robotics.runtime.run-id',owner.runId],['com.docker.compose.project',owner.projectName]]) {
        if(typeof actual?.[key]!=='string'||!actual[key]){missing.push(path+'.'+key);valid=false}
        else if(actual[key]!==expected){mismatches.push(path+'.'+key);valid=false}
      }
      return valid;
    };
    for(const [index,raw] of [...networks,...(Array.isArray(rawVolumes)?rawVolumes:[])].entries())matches(object(raw)?.Labels,'project.resource.'+index);
    for(const [index,raw] of containers.entries()) {
      const row=object(raw),id=row?.Id;
      if(typeof id!=='string'||!/^([a-f0-9]{64})$/.test(id)){missing.push('project.container.'+index+'.Id');continue}
      if(!matches(row?.Labels,'project.container.'+id+'.list-owner'))continue;
      const actual=await readJson(this.docker,'/containers/'+id+'/json',signal);containerDetails.push(actual);
      const container=object(actual);if(container?.Id!==id)mismatches.push('project.container.'+id+'.Id');
      if(!matches(object(container?.Config)?.Labels,'project.container.'+id+'.owner'))continue;
      const mode=object(container?.HostConfig)?.NetworkMode;
      if(typeof mode!=='string'||!mode)missing.push('project.container.'+id+'.NetworkMode');
      else if(mode.startsWith('container:')) {
        const parentId=mode.slice(10);
        if(!owner.networkNamespaceContainerId)missing.push('project.container.'+id+'.namespace.expected-id');
        else if(parentId!==owner.networkNamespaceContainerId)mismatches.push('project.container.'+id+'.namespace.expected-id');
        else if(!/^[a-f0-9]{64}$/.test(parentId))missing.push('project.container.'+id+'.namespace.exact-id');
        else {
          const parent=await readJson(this.docker,'/containers/'+parentId+'/json',signal);namespaceParents.push(parent);
          const native=object(parent);if(native?.Id!==parentId)mismatches.push('project.container.'+id+'.namespace.parent-id');
          matches(object(native?.Config)?.Labels,'project.container.'+id+'.namespace.parent-owner');
          const parentMode=object(native?.HostConfig)?.NetworkMode;
          if(typeof parentMode!=='string'||!parentMode||parentMode.startsWith('container:'))missing.push('project.container.'+id+'.namespace.direct-parent');
        }
      }
    }
    signal.throwIfAborted();
    return {status:missing.length||mismatches.length?'incomplete':'complete',missing,mismatches,engine:this.facts,
      inventory:{containers,volumes,networks},containerDetails,namespaceParents};
  }
  /** Read evidence only: no Engine exec or lifecycle writes are exposed here. */
  async readLogs(containerId:string,requestedOwner:{runId:string;projectName:string},
    requestedLimits:{tailLines:number;maxBytes:number;deadlineMs:number},cancel?:AbortSignal):Promise<{containerId:string;clientApi:string;tty:boolean;bytes:Buffer}> {
    const owner={...requestedOwner},limits={...requestedLimits};
    if(!/^[a-f0-9]{64}$/.test(containerId)) throw new Error('exact previously observed container ID required');
    if(!owner.runId||!owner.projectName) throw new Error('native log ownership is required');
    if(!Number.isSafeInteger(limits.tailLines)||limits.tailLines<1||limits.tailLines>10000 ||
       !Number.isSafeInteger(limits.maxBytes)||limits.maxBytes<1||limits.maxBytes>16777216 ||
       !Number.isSafeInteger(limits.deadlineMs)||limits.deadlineMs<1||limits.deadlineMs>120000) throw new Error('invalid finite native log bounds');
    const signal=cancel?AbortSignal.any([cancel,AbortSignal.timeout(limits.deadlineMs)]):AbortSignal.timeout(limits.deadlineMs);
    signal.throwIfAborted();
    const request=(path:string,isStream=false)=>new Promise<unknown>((resolve,reject)=>this.docker.modem.dial({
      path,method:'GET',abortSignal:signal,isStream,
      statusCodes:{200:true,404:'owned container is unavailable',500:'Engine evidence read failed'},
    },(error:unknown,value:unknown)=>error?reject(error):resolve(value)));
    const actual=object(await request('/containers/'+containerId+'/json'));
    const config=object(actual?.Config),labels=object(config?.Labels);
    if(actual?.Id!==containerId||labels?.['org.robotics.runtime.run-id']!==owner.runId||labels?.['com.docker.compose.project']!==owner.projectName) throw new Error('native log read refused foreign container ownership');
    if(typeof config?.Tty!=='boolean') throw new Error('native log transport framing is unavailable');
    const stream=await request('/containers/'+containerId+'/logs?stdout=1&stderr=1&follow=0&tail='+limits.tailLines,true) as Readable;
    const abort=()=>stream.destroy(signal.reason instanceof Error?signal.reason:new Error('native log read canceled'));
    signal.addEventListener('abort',abort,{once:true});
    try {
      signal.throwIfAborted();
      const chunks:Buffer[]=[];let length=0;
      for await(const raw of stream){
        signal.throwIfAborted();
        const chunk=Buffer.isBuffer(raw)?raw:Buffer.from(raw);
        length+=chunk.length;
        if(length>limits.maxBytes) throw new Error('native log evidence exceeds byte bound');
        chunks.push(chunk);
      }
      if(!length) throw new Error('owned container returned no retained log bytes');
      return {containerId,clientApi:this.facts.clientApi,tty:config.Tty,bytes:Buffer.concat(chunks,length)};
    } finally {
      signal.removeEventListener('abort',abort);
      stream.destroy();
    }
  }
  async inspect(containerId:string,requestedRequirement:ContainerRequirement,options:MetadataReadOptions={}): Promise<MetadataObservation> {
    const required=structuredClone(requestedRequirement),signal=metadataSignal(options);
    if (!/^[a-f0-9]{64}$/.test(containerId)) throw new Error('exact acquired container ID required');
    const container=await readJson(this.docker,'/containers/'+containerId+'/json',signal);
    const imageId = object(container)?.Image;
    const image = typeof imageId === 'string' ? await readJson(this.docker,'/images/'+encodeURIComponent(imageId)+'/json',signal) : undefined;
    const networks = object(object(object(container)?.NetworkSettings)?.Networks);
    const networkMode = object(object(container)?.HostConfig)?.NetworkMode;
    const parentId = typeof networkMode === 'string' && /^container:[a-f0-9]{64}$/.test(networkMode) ? networkMode.slice(10) : undefined;
    const networkNamespaceContainer = parentId ? await readJson(this.docker,'/containers/'+parentId+'/json',signal) : undefined;
    const namespaceMode = networkNamespaceContainer ? object(object(networkNamespaceContainer)?.HostConfig)?.NetworkMode : networkMode;
    const namespaceNetworks = networkNamespaceContainer ? object(object(networkNamespaceContainer)?.NetworkSettings)?.Networks : networks;
    const ids = namespaceMode === 'none' ? [] : Object.values(object(namespaceNetworks) ?? {}).map(n => object(n)?.NetworkID).filter((v): v is string => typeof v === 'string' && v.length > 0);
    const networkObjects=await Promise.all(ids.map(id=>readJson(this.docker,'/networks/'+encodeURIComponent(id),signal).catch((error:unknown)=>{signal.throwIfAborted();return {requestedNetworkId:id,inspectionError:String(error)}})));
    signal.throwIfAborted();
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
    const components=object(engine.versionResponse)?.Components;
    const qualifiedPodmanName=Array.isArray(components)&&components.map(object).some(component=>component?.Name==='Podman Engine'&&component.Version==='4.9.3'&&object(component.Details)?.APIVersion==='4.9.3');
    const matched=networks.some(raw=>{
      const actual=object(raw);
      if(actual?.Id===networkId) return true;
      // Podman 4.9.3's Docker projection may put the actual native name in NetworkID.
      // Accept only the inspected name/key/reference chain with a native immutable ID.
      return qualifiedPodmanName&&actual?.Name===name&&actual.Name===networkId&&typeof actual.Id==='string'&&/^[a-f0-9]{64}$/.test(actual.Id);
    });
    if(!matched) missing.push(`network.${name}.inspect`);
  }
  return {status: missing.length || mismatches.length ? 'incomplete' : 'complete', missing, mismatches, engine, container: rawContainer, image: rawImage, networks, networkNamespaceContainer:rawNamespaceContainer};
}
