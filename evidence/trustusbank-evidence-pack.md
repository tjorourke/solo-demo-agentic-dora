# TrustUsBank — Solo.io Agentic Demo
## DORA / NIS2 Evidence Pack

This document is the auditor-facing summary of evidence collected during the
TrustUsBank demo run. Each section maps to one or more articles of:

- **DORA** — Regulation (EU) 2022/2554 on digital operational resilience for the financial sector
- **NIS2** — Directive (EU) 2022/2555 on measures for a high common level of cybersecurity

Generated: 2026-05-09T16:06:26Z

---

## 1. Auditor's one-page summary

The TrustUsBank platform demonstrates that:

1. **Every byte between AI workloads is encrypted with strong identity** (DORA Art. 9(2)).
   Istio Ambient ztunnel terminates HBONE mTLS at the node level; SPIFFE
   identities are issued per workload by Istio's CA. See §2 below for the
   ztunnel logs and the AuthorizationPolicy set.
2. **Every AI agent → tool call is authenticated, authorised, and audited**
   (DORA Art. 9, 10). agentgateway validates a JWT issued by Keycloak, applies
   per-agent CEL allowlists on MCP tool names, and refuses tool calls whose
   descriptions match a prompt-injection pattern. See §3.
3. **Every AI artefact running in production is catalogued** (DORA Art. 28
   sub-outsourcing register). agentregistry stores a record per MCP server
   with provenance. See §4 for the export.
4. **Anomalous tool changes are detected and blocked**, before customer data
   moves (DORA Art. 10 detection, Art. 11 response). The Istio AuthZ deny
   service computes SHA-256 over every MCP server's tool definitions and
   alerts on mismatch. See §5 for the rug-pull incident timeline.
5. **Incidents have a complete, replayable audit trail** (DORA Art. 17).
   OpenTelemetry traces from kagent → agentgateway → MCP server are stored
   in Tempo; access logs in Loki. See §6 for the trace IDs.

---


## 2. HBONE mTLS + SPIFFE identities

**DORA Art. 9(2); NIS2 Art. 21(2)(h)**

ztunnel runs as a DaemonSet on every node. Inter-pod traffic is HBONE-tunnelled (HTTP/2 CONNECT over mTLS, port 15008). SPIFFE IDs are issued per workload by Istio's CA.


### ztunnel log (last 200 lines)

```log
Found 4 pods, using pod/ztunnel-fv2g9
2026-05-09T13:04:07.811075Z	info	ztunnel	version: version.BuildInfo{Version:"99b000df4d0f48fc75309aae894cc609ef96fa09", GitRevision:"99b000df4d0f48fc75309aae894cc609ef96fa09", RustVersion:"1.92.0", BuildProfile:"release", BuildStatus:"Clean", IstioVersion:"1.29.2", CryptoProvider:"tls-aws-lc"}	
2026-05-09T13:04:07.811099Z	info	ztunnel	set file descriptor limits from 1048576 to 1048576	
2026-05-09T13:04:07.811192Z	info	ztunnel	running with config: proxy: true
dnsProxy: true
windowSize: 4194304
connectionWindowSize: 16777216
frameSize: 1048576
poolMaxStreamsPerConn: 100
poolUnusedReleaseTimeout:
  secs: 300
  nanos: 0
socks5Addr: null
adminAddr: !Localhost
- true
- 15000
statsAddr: !SocketAddr '[::]:15020'
readinessAddr: !SocketAddr '[::]:15021'
inboundAddr: '[::]:15008'
inboundPlaintextAddr: '[::]:15006'
outboundAddr: '[::]:15001'
dnsProxyAddr: !Localhost
- true
- 15053
illegalPorts:
- 15001
- 15006
- 15008
network: ''
localNode: trustusbank-control-plane
proxyMode: Shared
proxyWorkloadInformation: null
clusterId: Kubernetes
clusterDomain: cluster.local
caAddress: https://istiod.istio-system.svc:15012
caRootCert: !File ./var/run/secrets/istio/root-cert.pem
caCertWatcher: true
altCaHostname: null
xdsAddress: https://istiod.istio-system.svc:15012
xdsRootCert: !File ./var/run/secrets/istio/root-cert.pem
altXdsHostname: null
preferedServiceNamespace: null
secretTtl:
  secs: 86400
  nanos: 0
xdsOnDemand: false
fakeCa: false
fakeSelfInbound: false
selfTerminationDeadline:
  secs: 25
  nanos: 0
proxyMetadata:
  CLUSTER_ID: Kubernetes
  ISTIO_VERSION: 1.29.2
  ENABLE_HBONE: 'true'
numWorkerThreads: 2
requireOriginalSource: null
proxyArgs: proxy ztunnel
dnsResolverCfg:
  domain: null
  search:
  - istio-system.svc.cluster.local
  - svc.cluster.local
  - cluster.local
  name_servers:
  - socket_addr: 10.96.0.10:53
    protocol: udp
    tls_dns_name: null
    http_endpoint: null
    trust_negative_responses: false
    bind_addr: null
  - socket_addr: 10.96.0.10:53
    protocol: tcp
    tls_dns_name: null
    http_endpoint: null
    trust_negative_responses: false
    bind_addr: null
dnsResolverOpts:
  ndots: 5
  timeout:
    secs: 5
    nanos: 0
  attempts: 2
  check_names: true
  edns0: false
  validate: false
  ip_strategy: Ipv4AndIpv6
  cache_size: 4096
  use_hosts_file: Auto
  positive_min_ttl: null
  negative_min_ttl: null
  positive_max_ttl: null
  negative_max_ttl: null
  num_concurrent_reqs: 2
  preserve_intermediates: true
  try_tcp_on_error: false
  server_ordering_strategy: QueryStatistics
  recursion_desired: true
  avoid_local_udp_ports: []
  os_port_selection: false
  case_randomization: false
  trust_anchor: null
inpodUds: /var/run/ztunnel/ztunnel.sock
inpodPortReuse: true
packetMark: 1337
socketConfig:
  keepaliveTime:
    secs: 180
    nanos: 0
  keepaliveInterval:
    secs: 180
    nanos: 0
  keepaliveRetries: 9
  keepaliveEnabled: true
  userTimeoutEnabled: false
xdsHeaders: []
caHeaders: []
localhostAppTunnel: true
ztunnelIdentity: spiffe://cluster.local/ns/istio-system/sa/ztunnel
ztunnelWorkload:
  name: ztunnel-fv2g9
  namespace: istio-system
  serviceAccount: ztunnel
ipv6Enabled: true
crlPath: null
enableEnhancedBaggage: true
	
2026-05-09T13:04:07.811773Z	info	hyper_util	listener established	address=[::]:15021 component="readiness"
2026-05-09T13:04:07.811886Z	info	app	shared proxy mode - in-pod mode enabled	
2026-05-09T13:04:07.811894Z	info	proxyfactory	creating ztunnel self-proxy listener with identity: Spiffe { trust_domain: "cluster.local", namespace: "istio-system", service_account: "ztunnel" }	
2026-05-09T13:04:07.811926Z	info	proxy::inbound	listener established	address=[::]:15008 component="inbound" transparent=true
2026-05-09T13:04:07.812006Z	info	hyper_util	listener established	address=127.0.0.1:15000 component="admin"
2026-05-09T13:04:07.812010Z	info	app	Starting ztunnel inbound listener task	
2026-05-09T13:04:07.812027Z	info	hyper_util	listener established	address=[::]:15020 component="stats"
2026-05-09T13:04:07.812040Z	info	readiness	Task 'dns proxy' complete (1.331208ms), still awaiting 3 tasks	
2026-05-09T13:04:07.812048Z	info	readiness	Task 'proxy' complete (1.339208ms), still awaiting 2 tasks	
2026-05-09T13:04:07.837318Z	info	xds::client:xds{id=1}	Stream established	
2026-05-09T13:04:07.837361Z	info	xds::client:xds{id=1}	received response	type_url="type.googleapis.com/istio.workload.Address" size=118 removes=0
2026-05-09T13:04:07.837536Z	info	xds::client:xds{id=1}	received response	type_url="type.googleapis.com/istio.security.Authorization" size=0 removes=0
2026-05-09T13:04:07.837556Z	info	readiness	Task 'state manager' complete (26.847041ms), still awaiting 1 tasks	
2026-05-09T13:04:07.837624Z	info	inpod::workloadmanager	handling new stream	
2026-05-09T13:04:07.838160Z	info	inpod::statemanager	received snapshot sent	
2026-05-09T13:04:07.838165Z	info	readiness	Task 'workload proxy manager' complete (27.456208ms), marking server ready	
2026-05-09T13:04:08.198279Z	info	xds::client:xds{id=1}	received response	type_url="type.googleapis.com/istio.security.Authorization" size=0 removes=0
2026-05-09T13:04:08.303821Z	info	xds::client:xds{id=1}	received response	type_url="type.googleapis.com/istio.workload.Address" size=2 removes=0
2026-05-09T13:04:08.405365Z	info	xds::client:xds{id=1}	received response	type_url="type.googleapis.com/istio.workload.Address" size=0 removes=1
2026-05-09T13:04:09.749842Z	info	xds::client:xds{id=1}	received response	type_url="type.googleapis.com/istio.workload.Address" size=2 removes=0
2026-05-09T13:04:10.775497Z	info	xds::client:xds{id=1}	received response	type_url="type.googleapis.com/istio.workload.Address" size=2 removes=0
2026-05-09T13:04:11.301761Z	info	xds::client:xds{id=1}	received response	type_url="type.googleapis.com/istio.workload.Address" size=1 removes=0
2026-05-09T13:04:12.314957Z	info	xds::client:xds{id=1}	received response	type_url="type.googleapis.com/istio.workload.Address" size=2 removes=0
2026-05-09T13:04:12.430048Z	info	xds::client:xds{id=1}	received response	type_url="type.googleapis.com/istio.workload.Address" size=0 removes=1
2026-05-09T13:04:34.888563Z	info	xds::client:xds{id=1}	received response	type_url="type.googleapis.com/istio.workload.Address" size=0 removes=1
2026-05-09T13:04:35.913958Z	info	xds::client:xds{id=1}	received response	type_url="type.googleapis.com/istio.workload.Address" size=0 removes=1
2026-05-09T13:04:37.625855Z	info	xds::client:xds{id=1}	received response	type_url="type.googleapis.com/istio.workload.Address" size=1 removes=0
2026-05-09T13:04:38.862802Z	info	xds::client:xds{id=1}	received response	type_url="type.googleapis.com/istio.workload.Address" size=1 removes=0
2026-05-09T13:04:39.692928Z	info	xds::client:xds{id=1}	received response	type_url="type.googleapis.com/istio.workload.Address" size=7 removes=0
2026-05-09T13:04:39.860342Z	info	xds::client:xds{id=1}	received response	type_url="type.googleapis.com/istio.workload.Address" size=1 removes=0
2026-05-09T13:04:40.873894Z	info	xds::client:xds{id=1}	received response	type_url="type.googleapis.com/istio.workload.Address" size=1 removes=0
2026-05-09T13:04:41.797379Z	info	xds::client:xds{id=1}	received response	type_url="type.googleapis.com/istio.workload.Address" size=6 removes=0
2026-05-09T13:04:41.798960Z	info	xds::client:xds{id=1}	received response	type_url="type.googleapis.com/istio.security.Authorization" size=5 removes=0
2026-05-09T13:04:41.798983Z	info	xds:xds{id=1}	handling RBAC update allow-agents-to-mcp	
2026-05-09T13:04:41.798999Z	info	xds:xds{id=1}	handling RBAC update allow-platform-to-agents	
2026-05-09T13:04:41.799000Z	info	xds:xds{id=1}	handling RBAC update default-deny	
2026-05-09T13:04:41.799001Z	info	xds:xds{id=1}	handling RBAC update default-deny	
2026-05-09T13:04:41.799002Z	info	xds:xds{id=1}	handling RBAC update default-deny	
2026-05-09T13:04:42.880454Z	info	xds::client:xds{id=1}	received response	type_url="type.googleapis.com/istio.workload.Address" size=1 removes=0
2026-05-09T13:08:46.647656Z	info	xds::client:xds{id=1}	received response	type_url="type.googleapis.com/istio.workload.Address" size=1 removes=0
2026-05-09T13:08:47.732755Z	info	xds::client:xds{id=1}	received response	type_url="type.googleapis.com/istio.workload.Address" size=0 removes=1
2026-05-09T13:09:05.727459Z	info	xds::client:xds{id=1}	received response	type_url="type.googleapis.com/istio.workload.Address" size=1 removes=0
2026-05-09T13:09:06.732168Z	info	xds::client:xds{id=1}	received response	type_url="type.googleapis.com/istio.workload.Address" size=1 removes=0
2026-05-09T13:09:07.823485Z	info	xds::client:xds{id=1}	received response	type_url="type.googleapis.com/istio.workload.Address" size=0 removes=1
2026-05-09T13:09:09.750319Z	info	xds::client:xds{id=1}	received response	type_url="type.googleapis.com/istio.workload.Address" size=1 removes=0
2026-05-09T13:09:10.751487Z	info	xds::client:xds{id=1}	received response	type_url="type.googleapis.com/istio.workload.Address" size=1 removes=0
2026-05-09T13:09:11.843422Z	info	xds::client:xds{id=1}	received response	type_url="type.googleapis.com/istio.workload.Address" size=0 removes=1
2026-05-09T13:10:23.244909Z	info	xds::client:xds{id=1}	received response	type_url="type.googleapis.com/istio.security.Authorization" size=1 removes=0
2026-05-09T13:10:23.245180Z	info	xds:xds{id=1}	handling RBAC update allow-platform-to-agents	
2026-05-09T13:10:43.071145Z	info	xds::client:xds{id=1}	received response	type_url="type.googleapis.com/istio.workload.Address" size=1 removes=0
2026-05-09T13:10:44.075870Z	info	xds::client:xds{id=1}	received response	type_url="type.googleapis.com/istio.workload.Address" size=1 removes=0
2026-05-09T13:10:45.152162Z	info	xds::client:xds{id=1}	received response	type_url="type.googleapis.com/istio.workload.Address" size=0 removes=1
2026-05-09T13:11:21.303324Z	info	xds::client:xds{id=1}	received response	type_url="type.googleapis.com/istio.security.Authorization" size=1 removes=0
2026-05-09T13:11:21.303558Z	info	xds:xds{id=1}	handling RBAC update allow-platform-to-agents	
2026-05-09T13:15:53.621623Z	info	xds::client:xds{id=1}	received response	type_url="type.googleapis.com/istio.security.Authorization" size=0 removes=5
2026-05-09T13:15:53.621803Z	info	xds:xds{id=1}	handling RBAC delete trustusbank-bank-agents/allow-platform-to-agents	
2026-05-09T13:15:53.621819Z	info	xds:xds{id=1}	handling RBAC delete trustusbank-bank-agents/default-deny	
2026-05-09T13:15:53.621825Z	info	xds:xds{id=1}	handling RBAC delete trustusbank-bank-evil/default-deny	
2026-05-09T13:15:53.621825Z	info	xds:xds{id=1}	handling RBAC delete trustusbank-bank-mcp/allow-agents-to-mcp	
2026-05-09T13:15:53.621855Z	info	xds:xds{id=1}	handling RBAC delete trustusbank-bank-mcp/default-deny	
2026-05-09T13:16:00.134532Z	info	xds::client:xds{id=1}	received response	type_url="type.googleapis.com/istio.workload.Address" size=1 removes=0
2026-05-09T13:16:01.152910Z	info	xds::client:xds{id=1}	received response	type_url="type.googleapis.com/istio.workload.Address" size=2 removes=0
2026-05-09T13:16:01.346953Z	info	xds::client:xds{id=1}	received response	type_url="type.googleapis.com/istio.workload.Address" size=0 removes=1
2026-05-09T13:18:04.553673Z	info	xds::client:xds{id=1}	received response	type_url="type.googleapis.com/istio.workload.Address" size=1 removes=0
2026-05-09T13:18:05.572430Z	info	xds::client:xds{id=1}	received response	type_url="type.googleapis.com/istio.workload.Address" size=2 removes=0
2026-05-09T13:18:05.771251Z	info	xds::client:xds{id=1}	received response	type_url="type.googleapis.com/istio.workload.Address" size=0 removes=1
2026-05-09T13:24:01.700925Z	info	xds::client:xds{id=1}	received response	type_url="type.googleapis.com/istio.workload.Address" size=1 removes=0
2026-05-09T13:24:02.721690Z	info	xds::client:xds{id=1}	received response	type_url="type.googleapis.com/istio.workload.Address" size=2 removes=0
2026-05-09T13:24:03.395936Z	info	xds::client:xds{id=1}	received response	type_url="type.googleapis.com/istio.workload.Address" size=0 removes=1
2026-05-09T13:35:14.007749Z	info	xds::client:xds{id=2}	Stream established	
2026-05-09T13:35:14.007907Z	info	xds::client:xds{id=2}	received response	type_url="type.googleapis.com/istio.workload.Address" size=122 removes=0
2026-05-09T13:35:14.008435Z	info	xds::client:xds{id=2}	received response	type_url="type.googleapis.com/istio.security.Authorization" size=0 removes=0
2026-05-09T13:40:57.088899Z	info	xds::client:xds{id=2}	received response	type_url="type.googleapis.com/istio.workload.Address" size=1 removes=0
```


### AuthorizationPolicies in effect

```yaml
apiVersion: v1
items:
- apiVersion: security.istio.io/v1
  kind: AuthorizationPolicy
  metadata:
    annotations:
      kubectl.kubernetes.io/last-applied-configuration: |
        {"apiVersion":"security.istio.io/v1","kind":"AuthorizationPolicy","metadata":{"annotations":{},"name":"deny-bank-to-attacker","namespace":"external-attacker"},"spec":{"action":"DENY","rules":[{"from":[{"source":{"namespaces":["trustusbank-bank-*","trustusbank-platform"]}}]}]}}
    creationTimestamp: "2026-05-09T15:57:20Z"
    generation: 1
    name: deny-bank-to-attacker
    namespace: external-attacker
    resourceVersion: "256614"
    uid: 921ab2f3-d759-4e50-807b-180517f32e33
  spec:
    action: DENY
    rules:
    - from:
      - source:
          namespaces:
          - trustusbank-bank-*
          - trustusbank-platform
  status:
    conditions:
    - lastTransitionTime: "2026-05-09T15:57:20.918855718Z"
      message: attached to ztunnel
      observedGeneration: "1"
      reason: Accepted
      status: "True"
      type: ZtunnelAccepted
- apiVersion: security.istio.io/v1
  kind: AuthorizationPolicy
  metadata:
    annotations:
      kubectl.kubernetes.io/last-applied-configuration: |
        {"apiVersion":"security.istio.io/v1","kind":"AuthorizationPolicy","metadata":{"annotations":{},"name":"allow-platform-to-agents","namespace":"trustusbank-bank-agents"},"spec":{"action":"ALLOW","rules":[{"from":[{"source":{"principals":["cluster.local/ns/trustusbank-platform/sa/kagent-ui","cluster.local/ns/trustusbank-platform/sa/kagent-controller","cluster.local/ns/trustusbank-bank-frontend/sa/chatbot","cluster.local/ns/trustusbank-bank-agents/sa/support-bot","cluster.local/ns/trustusbank-bank-agents/sa/fraud-bot","cluster.local/ns/trustusbank-bank-agents/sa/triage-bot","cluster.local/ns/trustusbank-bank-agents/sa/waypoint"]}}]}]}}
    creationTimestamp: "2026-05-09T15:57:20Z"
    generation: 1
    name: allow-platform-to-agents
    namespace: trustusbank-bank-agents
    resourceVersion: "256610"
    uid: 953e3ec6-19ec-4f46-8dae-9bc7dc4d802d
  spec:
    action: ALLOW
    rules:
    - from:
      - source:
          principals:
          - cluster.local/ns/trustusbank-platform/sa/kagent-ui
          - cluster.local/ns/trustusbank-platform/sa/kagent-controller
          - cluster.local/ns/trustusbank-bank-frontend/sa/chatbot
          - cluster.local/ns/trustusbank-bank-agents/sa/support-bot
          - cluster.local/ns/trustusbank-bank-agents/sa/fraud-bot
          - cluster.local/ns/trustusbank-bank-agents/sa/triage-bot
          - cluster.local/ns/trustusbank-bank-agents/sa/waypoint
  status:
    conditions:
    - lastTransitionTime: "2026-05-09T15:57:20.838042801Z"
      message: attached to ztunnel
      observedGeneration: "1"
      reason: Accepted
      status: "True"
      type: ZtunnelAccepted
- apiVersion: security.istio.io/v1
  kind: AuthorizationPolicy
  metadata:
    annotations:
      kubectl.kubernetes.io/last-applied-configuration: |
        {"apiVersion":"security.istio.io/v1","kind":"AuthorizationPolicy","metadata":{"annotations":{},"name":"default-deny","namespace":"trustusbank-bank-agents"},"spec":{}}
    creationTimestamp: "2026-05-09T15:57:20Z"
    generation: 1
    name: default-deny
    namespace: trustusbank-bank-agents
    resourceVersion: "256604"
    uid: b8d6b359-e6d0-4b89-92b0-68af627b501c
  spec: {}
  status:
    conditions:
    - lastTransitionTime: "2026-05-09T15:57:20.751644801Z"
      message: attached to ztunnel
      observedGeneration: "1"
      reason: Accepted
      status: "True"
      type: ZtunnelAccepted
- apiVersion: security.istio.io/v1
  kind: AuthorizationPolicy
  metadata:
    annotations:
      kubectl.kubernetes.io/last-applied-configuration: |
        {"apiVersion":"security.istio.io/v1","kind":"AuthorizationPolicy","metadata":{"annotations":{},"name":"allow-agents-to-mcp","namespace":"trustusbank-bank-mcp"},"spec":{"action":"ALLOW","rules":[{"from":[{"source":{"principals":["cluster.local/ns/trustusbank-bank-agents/sa/support-bot","cluster.local/ns/trustusbank-bank-agents/sa/fraud-bot","cluster.local/ns/trustusbank-bank-agents/sa/triage-bot","cluster.local/ns/trustusbank-platform/sa/trustusbank-agentgw","cluster.local/ns/trustusbank-bank-mcp/sa/waypoint"]}}]}]}}
    creationTimestamp: "2026-05-09T15:57:20Z"
    generation: 1
    name: allow-agents-to-mcp
    namespace: trustusbank-bank-mcp
    resourceVersion: "256608"
    uid: a394bc62-146d-4ae4-8d2a-6bc95b1dca79
  spec:
    action: ALLOW
    rules:
    - from:
      - source:
          principals:
          - cluster.local/ns/trustusbank-bank-agents/sa/support-bot
          - cluster.local/ns/trustusbank-bank-agents/sa/fraud-bot
          - cluster.local/ns/trustusbank-bank-agents/sa/triage-bot
          - cluster.local/ns/trustusbank-platform/sa/trustusbank-agentgw
          - cluster.local/ns/trustusbank-bank-mcp/sa/waypoint
  status:
    conditions:
    - lastTransitionTime: "2026-05-09T15:57:20.799213760Z"
      message: attached to ztunnel
      observedGeneration: "1"
      reason: Accepted
      status: "True"
      type: ZtunnelAccepted
- apiVersion: security.istio.io/v1
  kind: AuthorizationPolicy
  metadata:
    annotations:
      kubectl.kubernetes.io/last-applied-configuration: |
        {"apiVersion":"security.istio.io/v1","kind":"AuthorizationPolicy","metadata":{"annotations":{},"name":"default-deny","namespace":"trustusbank-bank-mcp"},"spec":{}}
    creationTimestamp: "2026-05-09T15:57:20Z"
    generation: 1
    name: default-deny
    namespace: trustusbank-bank-mcp
    resourceVersion: "256602"
    uid: a42c9106-5e7d-4bcb-b847-ec5527ae493c
  spec: {}
  status:
    conditions:
    - lastTransitionTime: "2026-05-09T15:57:20.745602010Z"
      message: attached to ztunnel
      observedGeneration: "1"
      reason: Accepted
      status: "True"
      type: ZtunnelAccepted
- apiVersion: security.istio.io/v1
  kind: AuthorizationPolicy
  metadata:
    annotations:
      kubectl.kubernetes.io/last-applied-configuration: |
        {"apiVersion":"security.istio.io/v1","kind":"AuthorizationPolicy","metadata":{"annotations":{},"name":"allow-gw-to-vendor","namespace":"trustusbank-bank-vendors"},"spec":{"action":"ALLOW","rules":[{"from":[{"source":{"principals":["cluster.local/ns/trustusbank-platform/sa/trustusbank-agentgw"]}}]}]}}
    creationTimestamp: "2026-05-09T15:57:20Z"
    generation: 1
    name: allow-gw-to-vendor
    namespace: trustusbank-bank-vendors
    resourceVersion: "256612"
    uid: d737cb7b-d500-4162-9bee-b2a47bdfa44a
  spec:
    action: ALLOW
    rules:
    - from:
      - source:
          principals:
          - cluster.local/ns/trustusbank-platform/sa/trustusbank-agentgw
  status:
    conditions:
    - lastTransitionTime: "2026-05-09T15:57:20.875494718Z"
      message: attached to ztunnel
      observedGeneration: "1"
      reason: Accepted
      status: "True"
      type: ZtunnelAccepted
- apiVersion: security.istio.io/v1
  kind: AuthorizationPolicy
  metadata:
    annotations:
      kubectl.kubernetes.io/last-applied-configuration: |
        {"apiVersion":"security.istio.io/v1","kind":"AuthorizationPolicy","metadata":{"annotations":{},"name":"default-deny","namespace":"trustusbank-bank-vendors"},"spec":{}}
    creationTimestamp: "2026-05-09T15:57:20Z"
    generation: 1
    name: default-deny
    namespace: trustusbank-bank-vendors
    resourceVersion: "256606"
    uid: 52bb5795-d7fd-4a2f-98f7-7e02e19570a5
  spec: {}
  status:
    conditions:
    - lastTransitionTime: "2026-05-09T15:57:20.756714635Z"
      message: attached to ztunnel
      observedGeneration: "1"
      reason: Accepted
      status: "True"
      type: ZtunnelAccepted
kind: List
metadata:
  resourceVersion: ""
```


### SPIFFE identities seen on the wire

```log
ztunnelIdentity: spiffe://cluster.local/ns/istio-system/sa/ztunnel
```


## 3. AuthN + AuthZ + prompt-guard

**DORA Art. 9(4)(c), Art. 10; NIS2 Art. 21(2)(b),(d)**

agentgateway validates Keycloak-issued JWTs at the listener, applies per-agent CEL allowlists on MCP tool calls, and inspects tool descriptions/arguments/responses against prompt-injection regex patterns.


### agentgateway access log

```json
{"time":"2026-05-08T20:08:37.020254881Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:08:37Z/210"}
{"time":"2026-05-08T20:08:37.020328006Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":1,"removed":0,"size":"275B"}
{"time":"2026-05-08T20:08:37.032434381Z","level":"info","msg":"push debounce stable","component":"krtxds","id":211,"debouncedEvents":1,"lastChange":"10.068416ms","lastPush":"10.068416ms","cause":"//Pod/trustusbank-bank-evil/evil-tools-744bb844d7-f6pzr"}
{"time":"2026-05-08T20:08:37.032477422Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:08:37Z/211"}
{"time":"2026-05-08T20:08:37.032532631Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":1,"removed":0,"size":"278B"}
{"time":"2026-05-08T20:08:37.620178964Z","level":"info","msg":"push debounce stable","component":"krtxds","id":212,"debouncedEvents":1,"lastChange":"11.655041ms","lastPush":"11.655ms","cause":"//Pod/trustusbank-bank-evil/evil-tools-744bb844d7-f6pzr"}
{"time":"2026-05-08T20:08:37.620226381Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:08:37Z/212"}
{"time":"2026-05-08T20:08:37.620288798Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":0,"removed":1,"size":"0B"}
{"time":"2026-05-08T20:21:30.992610544Z","level":"info","msg":"push debounce stable","component":"krtxds","id":213,"debouncedEvents":1,"lastChange":"10.499666ms","lastPush":"10.499625ms","cause":"//Pod/trustusbank-observability/kube-prometheus-stack-grafana-58fcf4b64b-vmff2"}
{"time":"2026-05-08T20:21:30.992792753Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:21:30Z/213"}
{"time":"2026-05-08T20:21:30.992974128Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":1,"removed":0,"size":"383B"}
{"time":"2026-05-08T20:21:33.003572129Z","level":"info","msg":"push debounce stable","component":"krtxds","id":214,"debouncedEvents":1,"lastChange":"11.795667ms","lastPush":"11.795583ms","cause":"//Pod/trustusbank-observability/kube-prometheus-stack-grafana-58fcf4b64b-vmff2"}
{"time":"2026-05-08T20:21:33.003692212Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:21:33Z/214"}
{"time":"2026-05-08T20:21:33.003758545Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":1,"removed":0,"size":"380B"}
{"time":"2026-05-08T20:21:33.01886217Z","level":"info","msg":"push debounce stable","component":"krtxds","id":215,"debouncedEvents":1,"lastChange":"10.194542ms","lastPush":"10.1945ms","cause":"//Pod/trustusbank-observability/kube-prometheus-stack-grafana-5bbb6848f5-lglk6"}
{"time":"2026-05-08T20:21:33.018900879Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:21:33Z/215"}
{"time":"2026-05-08T20:21:33.018952004Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":1,"removed":0,"size":"383B"}
{"time":"2026-05-08T20:21:33.296817462Z","level":"info","msg":"push debounce stable","component":"krtxds","id":216,"debouncedEvents":1,"lastChange":"10.807667ms","lastPush":"10.807625ms","cause":"//Pod/trustusbank-observability/kube-prometheus-stack-grafana-5bbb6848f5-lglk6"}
{"time":"2026-05-08T20:21:33.296870212Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:21:33Z/216"}
{"time":"2026-05-08T20:21:33.296923379Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":0,"removed":1,"size":"0B"}
{"time":"2026-05-08T20:24:27.692192501Z","level":"info","msg":"push debounce stable","component":"krtxds","id":217,"debouncedEvents":1,"lastChange":"10.925125ms","lastPush":"10.925084ms","cause":"//Pod/trustusbank-platform/digest-watcher-549c4d6b5f-bkg4g"}
{"time":"2026-05-08T20:24:27.692344418Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:24:27Z/217"}
{"time":"2026-05-08T20:24:27.692593543Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":1,"removed":0,"size":"306B"}
{"time":"2026-05-08T20:24:57.844027043Z","level":"info","msg":"push debounce stable","component":"krtxds","id":218,"debouncedEvents":1,"lastChange":"11.295041ms","lastPush":"11.295ms","cause":"//Pod/trustusbank-platform/digest-watcher-549c4d6b5f-bkg4g"}
{"time":"2026-05-08T20:24:57.844066918Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:24:57Z/218"}
{"time":"2026-05-08T20:24:57.844134001Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":0,"removed":1,"size":"0B"}
{"time":"2026-05-08T20:25:38.812391173Z","level":"info","msg":"push debounce stable","component":"krtxds","id":219,"debouncedEvents":1,"lastChange":"10.289917ms","lastPush":"10.289917ms","cause":"//Pod/trustusbank-bank-evil/evil-tools-5578db5f5b-kdsjb"}
{"time":"2026-05-08T20:25:38.812432881Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:25:38Z/219"}
{"time":"2026-05-08T20:25:38.812488756Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":1,"removed":0,"size":"278B"}
{"time":"2026-05-08T20:25:40.832278674Z","level":"info","msg":"push debounce stable","component":"krtxds","id":220,"debouncedEvents":1,"lastChange":"10.485541ms","lastPush":"10.4855ms","cause":"//Pod/trustusbank-bank-evil/evil-tools-5578db5f5b-kdsjb"}
{"time":"2026-05-08T20:25:40.832437757Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:25:40Z/220"}
{"time":"2026-05-08T20:25:40.832525507Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":1,"removed":0,"size":"275B"}
{"time":"2026-05-08T20:25:40.847154757Z","level":"info","msg":"push debounce stable","component":"krtxds","id":221,"debouncedEvents":1,"lastChange":"11.837666ms","lastPush":"11.837625ms","cause":"//Pod/trustusbank-bank-evil/evil-tools-7bcdc87555-dfz5k"}
{"time":"2026-05-08T20:25:40.847187799Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:25:40Z/221"}
{"time":"2026-05-08T20:25:40.847243382Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":1,"removed":0,"size":"278B"}
{"time":"2026-05-08T20:25:41.251379924Z","level":"info","msg":"push debounce stable","component":"krtxds","id":222,"debouncedEvents":1,"lastChange":"11.096708ms","lastPush":"11.096666ms","cause":"//Pod/trustusbank-bank-evil/evil-tools-7bcdc87555-dfz5k"}
{"time":"2026-05-08T20:25:41.251409549Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:25:41Z/222"}
{"time":"2026-05-08T20:25:41.251452049Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":0,"removed":1,"size":"0B"}
{"time":"2026-05-08T20:26:21.298050762Z","level":"info","msg":"push debounce stable","component":"krtxds","id":223,"debouncedEvents":3,"lastChange":"10.608792ms","lastPush":"17.297292ms","cause":"policy/traffic/trustusbank-platform/account-mcp-allowlist:rbac:trustusbank-platform/account-mcp-route and 2 more configs"}
{"time":"2026-05-08T20:26:21.298090929Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:26:21Z/223"}
{"time":"2026-05-08T20:26:21.298199429Z","level":"info","msg":"push response","component":"krtxds","type":"RDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":3,"removed":0,"size":"1.2kB"}
{"time":"2026-05-08T20:26:21.950081513Z","level":"info","msg":"push debounce stable","component":"krtxds","id":224,"debouncedEvents":1,"lastChange":"11.034167ms","lastPush":"11.034125ms","cause":"//Pod/trustusbank-platform/digest-watcher-549c4d6b5f-xh64z"}
{"time":"2026-05-08T20:26:21.950115346Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:26:21Z/224"}
{"time":"2026-05-08T20:26:21.950205388Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":1,"removed":0,"size":"306B"}
{"time":"2026-05-08T20:26:32.966227337Z","level":"info","msg":"push debounce stable","component":"krtxds","id":225,"debouncedEvents":1,"lastChange":"10.432958ms","lastPush":"10.432917ms","cause":"//Pod/trustusbank-platform/digest-watcher-549c4d6b5f-xh64z"}
{"time":"2026-05-08T20:26:32.966374754Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:26:32Z/225"}
{"time":"2026-05-08T20:26:32.966565087Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":1,"removed":0,"size":"303B"}
{"time":"2026-05-08T20:28:08.55267234Z","level":"info","msg":"push debounce stable","component":"krtxds","id":226,"debouncedEvents":1,"lastChange":"10.733125ms","lastPush":"10.733ms","cause":"policy/traffic/trustusbank-platform/account-mcp-allowlist:rbac:trustusbank-platform/account-mcp-route"}
{"time":"2026-05-08T20:28:08.552746131Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:28:08Z/226"}
{"time":"2026-05-08T20:28:08.552828298Z","level":"info","msg":"push response","component":"krtxds","type":"RDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":1,"removed":0,"size":"391B"}
{"time":"2026-05-08T20:28:08.56373034Z","level":"info","msg":"push debounce stable","component":"krtxds","id":227,"debouncedEvents":1,"lastChange":"10.06825ms","lastPush":"10.068209ms","cause":"policy/traffic/trustusbank-platform/transaction-mcp-allowlist:rbac:trustusbank-platform/transaction-mcp-route"}
{"time":"2026-05-08T20:28:08.563791506Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:28:08Z/227"}
{"time":"2026-05-08T20:28:08.563887965Z","level":"info","msg":"push response","component":"krtxds","type":"RDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":1,"removed":0,"size":"443B"}
{"time":"2026-05-08T20:28:08.576790506Z","level":"info","msg":"push debounce stable","component":"krtxds","id":228,"debouncedEvents":1,"lastChange":"10.302666ms","lastPush":"10.302625ms","cause":"policy/traffic/trustusbank-platform/ticket-mcp-allowlist:rbac:trustusbank-platform/ticket-mcp-route"}
{"time":"2026-05-08T20:28:08.57682284Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:28:08Z/228"}
{"time":"2026-05-08T20:28:08.576892548Z","level":"info","msg":"push response","component":"krtxds","type":"RDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":1,"removed":0,"size":"390B"}
{"time":"2026-05-08T20:29:26.424391417Z","level":"info","msg":"push debounce stable","component":"krtxds","id":229,"debouncedEvents":3,"lastChange":"11.00575ms","lastPush":"14.994ms","cause":"policy/traffic/trustusbank-platform/transaction-mcp-allowlist:rbac:trustusbank-platform/transaction-mcp-route and 2 more configs"}
{"time":"2026-05-08T20:29:26.424442167Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:29:26Z/229"}
{"time":"2026-05-08T20:29:26.424601417Z","level":"info","msg":"push response","component":"krtxds","type":"RDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":0,"removed":3,"size":"0B"}
{"time":"2026-05-08T20:29:54.666878833Z","level":"info","msg":"push debounce stable","component":"krtxds","id":230,"debouncedEvents":1,"lastChange":"10.478875ms","lastPush":"10.478875ms","cause":"//Pod/trustusbank-bank-agents/support-bot-698ff84449-pv6sz"}
{"time":"2026-05-08T20:29:54.666923875Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:29:54Z/230"}
{"time":"2026-05-08T20:29:54.667076958Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":1,"removed":0,"size":"292B"}
{"time":"2026-05-08T20:29:55.634781917Z","level":"info","msg":"push debounce stable","component":"krtxds","id":231,"debouncedEvents":1,"lastChange":"10.598417ms","lastPush":"10.598375ms","cause":"//Pod/trustusbank-bank-agents/support-bot-698ff84449-hlqtm"}
{"time":"2026-05-08T20:29:55.63482975Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:29:55Z/231"}
{"time":"2026-05-08T20:29:55.634920792Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":1,"removed":0,"size":"292B"}
{"time":"2026-05-08T20:29:55.662818584Z","level":"info","msg":"push debounce stable","component":"krtxds","id":232,"debouncedEvents":1,"lastChange":"10.635667ms","lastPush":"10.635667ms","cause":"//Pod/trustusbank-bank-agents/support-bot-698ff84449-pv6sz"}
{"time":"2026-05-08T20:29:55.662852542Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:29:55Z/232"}
{"time":"2026-05-08T20:29:55.662897625Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":0,"removed":1,"size":"0B"}
{"time":"2026-05-08T20:30:12.645780258Z","level":"info","msg":"push debounce stable","component":"krtxds","id":233,"debouncedEvents":1,"lastChange":"11.251959ms","lastPush":"11.251917ms","cause":"//Pod/trustusbank-bank-agents/support-bot-698ff84449-hlqtm"}
{"time":"2026-05-08T20:30:12.645828508Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:30:12Z/233"}
{"time":"2026-05-08T20:30:12.645887592Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":1,"removed":0,"size":"289B"}
{"time":"2026-05-08T20:32:31.87420792Z","level":"info","msg":"push debounce stable","component":"krtxds","id":234,"debouncedEvents":1,"lastChange":"10.133875ms","lastPush":"10.133833ms","cause":"//Pod/trustusbank-platform/digest-watcher-76869559f6-l6nsh"}
{"time":"2026-05-08T20:32:31.87432317Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:32:31Z/234"}
{"time":"2026-05-08T20:32:31.874617462Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":1,"removed":0,"size":"306B"}
{"time":"2026-05-08T20:32:43.882506884Z","level":"info","msg":"push debounce stable","component":"krtxds","id":235,"debouncedEvents":1,"lastChange":"10.114125ms","lastPush":"10.114125ms","cause":"//Pod/trustusbank-platform/digest-watcher-76869559f6-l6nsh"}
{"time":"2026-05-08T20:32:43.882594051Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:32:43Z/235"}
{"time":"2026-05-08T20:32:43.882696634Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":1,"removed":0,"size":"303B"}
{"time":"2026-05-08T20:32:43.894232301Z","level":"info","msg":"push debounce stable","component":"krtxds","id":236,"debouncedEvents":1,"lastChange":"11.344167ms","lastPush":"11.344125ms","cause":"//Pod/trustusbank-platform/digest-watcher-549c4d6b5f-xh64z"}
{"time":"2026-05-08T20:32:43.894267592Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:32:43Z/236"}
{"time":"2026-05-08T20:32:43.894329009Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":1,"removed":0,"size":"306B"}
{"time":"2026-05-08T20:33:14.103071759Z","level":"info","msg":"push debounce stable","component":"krtxds","id":237,"debouncedEvents":1,"lastChange":"10.502917ms","lastPush":"10.502792ms","cause":"//Pod/trustusbank-platform/digest-watcher-549c4d6b5f-xh64z"}
{"time":"2026-05-08T20:33:14.103140342Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:33:14Z/237"}
{"time":"2026-05-08T20:33:14.103213342Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":0,"removed":1,"size":"0B"}
{"time":"2026-05-08T20:34:28.947421293Z","level":"info","msg":"push debounce stable","component":"krtxds","id":238,"debouncedEvents":1,"lastChange":"11.964708ms","lastPush":"11.964625ms","cause":"//Pod/trustusbank-observability/otel-collector-opentelemetry-collector-agent-66dxw"}
{"time":"2026-05-08T20:34:28.947486168Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:34:28Z/238"}
{"time":"2026-05-08T20:34:28.947695002Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":1,"removed":0,"size":"318B"}
{"time":"2026-05-08T20:34:29.207606335Z","level":"info","msg":"push debounce stable","component":"krtxds","id":239,"debouncedEvents":1,"lastChange":"11.146542ms","lastPush":"11.1465ms","cause":"//Pod/trustusbank-observability/otel-collector-opentelemetry-collector-agent-66dxw"}
{"time":"2026-05-08T20:34:29.207687669Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:34:29Z/239"}
{"time":"2026-05-08T20:34:29.207776502Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":0,"removed":1,"size":"0B"}
{"time":"2026-05-08T20:34:30.251477294Z","level":"info","msg":"push debounce stable","component":"krtxds","id":240,"debouncedEvents":3,"lastChange":"10.386083ms","lastPush":"18.8235ms","cause":"//Pod/trustusbank-observability/otel-collector-opentelemetry-collector-agent-pfddd and 1 more configs"}
{"time":"2026-05-08T20:34:30.251530502Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:34:30Z/240"}
{"time":"2026-05-08T20:34:30.251634294Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":2,"removed":0,"size":"633B"}
{"time":"2026-05-08T20:34:30.507257586Z","level":"info","msg":"push debounce stable","component":"krtxds","id":241,"debouncedEvents":1,"lastChange":"11.986875ms","lastPush":"11.986833ms","cause":"//Pod/trustusbank-observability/otel-collector-opentelemetry-collector-agent-pfddd"}
{"time":"2026-05-08T20:34:30.507306003Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:34:30Z/241"}
{"time":"2026-05-08T20:34:30.507353628Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":0,"removed":1,"size":"0B"}
{"time":"2026-05-08T20:34:31.537685503Z","level":"info","msg":"push debounce stable","component":"krtxds","id":242,"debouncedEvents":3,"lastChange":"12.217958ms","lastPush":"22.848166ms","cause":"//Pod/trustusbank-observability/otel-collector-opentelemetry-collector-agent-jzwsc and 1 more configs"}
{"time":"2026-05-08T20:34:31.537718961Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:34:31Z/242"}
{"time":"2026-05-08T20:34:31.537772295Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":2,"removed":0,"size":"632B"}
{"time":"2026-05-08T20:34:31.784319878Z","level":"info","msg":"push debounce stable","component":"krtxds","id":243,"debouncedEvents":1,"lastChange":"10.214916ms","lastPush":"10.214875ms","cause":"//Pod/trustusbank-observability/otel-collector-opentelemetry-collector-agent-hgpdk"}
{"time":"2026-05-08T20:34:31.784348461Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:34:31Z/243"}
{"time":"2026-05-08T20:34:31.784394045Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":0,"removed":1,"size":"0B"}
{"time":"2026-05-08T20:34:32.913716962Z","level":"info","msg":"push debounce stable","component":"krtxds","id":244,"debouncedEvents":2,"lastChange":"11.821917ms","lastPush":"17.693334ms","cause":"//Pod/trustusbank-observability/otel-collector-opentelemetry-collector-agent-wfbc7"}
{"time":"2026-05-08T20:34:32.91376792Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:34:32Z/244"}
{"time":"2026-05-08T20:34:32.913860045Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":1,"removed":0,"size":"314B"}
{"time":"2026-05-08T20:37:24.475672291Z","level":"info","msg":"push debounce stable","component":"krtxds","id":245,"debouncedEvents":2,"lastChange":"11.71075ms","lastPush":"13.054125ms","cause":"trustusbank-platform/agentregistry-postgresql.trustusbank-platform.svc.cluster.local and 1 more configs"}
{"time":"2026-05-08T20:37:24.475723666Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:37:24Z/245"}
{"time":"2026-05-08T20:37:24.475873375Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":2,"removed":0,"size":"271B"}
{"time":"2026-05-08T20:37:25.832025834Z","level":"info","msg":"push debounce stable","component":"krtxds","id":246,"debouncedEvents":1,"lastChange":"10.129208ms","lastPush":"10.129125ms","cause":"//Pod/local-path-storage/helper-pod-create-pvc-c7fb8ede-862c-46a3-ac9c-f3580bf61ebc"}
{"time":"2026-05-08T20:37:25.832085Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:37:25Z/246"}
{"time":"2026-05-08T20:37:25.832176167Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":1,"removed":0,"size":"369B"}
{"time":"2026-05-08T20:37:26.911766042Z","level":"info","msg":"push debounce stable","component":"krtxds","id":247,"debouncedEvents":1,"lastChange":"10.022042ms","lastPush":"10.022ms","cause":"//Pod/local-path-storage/helper-pod-create-pvc-c7fb8ede-862c-46a3-ac9c-f3580bf61ebc"}
{"time":"2026-05-08T20:37:26.911818459Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:37:26Z/247"}
{"time":"2026-05-08T20:37:26.911877959Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":0,"removed":1,"size":"0B"}
{"time":"2026-05-08T20:37:32.861655504Z","level":"info","msg":"push debounce stable","component":"krtxds","id":248,"debouncedEvents":2,"lastChange":"11.859208ms","lastPush":"19.394375ms","cause":"//Pod/trustusbank-platform/agentregistry-68447b4b7d-cwklj and 1 more configs"}
{"time":"2026-05-08T20:37:32.861699004Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:37:32Z/248"}
{"time":"2026-05-08T20:37:32.861774712Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":2,"removed":0,"size":"642B"}
{"time":"2026-05-08T20:37:39.920746674Z","level":"info","msg":"push debounce stable","component":"krtxds","id":249,"debouncedEvents":1,"lastChange":"10.785416ms","lastPush":"10.785375ms","cause":"//Pod/trustusbank-platform/agentregistry-postgresql-6d675fdc94-mmgmr"}
{"time":"2026-05-08T20:37:39.92079134Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:37:39Z/249"}
{"time":"2026-05-08T20:37:39.920874382Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":1,"removed":0,"size":"327B"}
{"time":"2026-05-08T20:43:38.35097209Z","level":"info","msg":"push debounce stable","component":"krtxds","id":250,"debouncedEvents":4,"lastChange":"11.810833ms","lastPush":"12.249083ms","cause":"trustusbank-platform/agentregistry.trustusbank-platform.svc.cluster.local and 3 more configs"}
{"time":"2026-05-08T20:43:38.35104234Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:43:38Z/250"}
{"time":"2026-05-08T20:43:38.351280923Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":2,"removed":2,"size":"432B"}
{"time":"2026-05-08T20:43:38.371563548Z","level":"info","msg":"push debounce stable","component":"krtxds","id":251,"debouncedEvents":1,"lastChange":"10.222625ms","lastPush":"10.222584ms","cause":"//Pod/trustusbank-platform/agentregistry-postgresql-6d675fdc94-mmgmr"}
{"time":"2026-05-08T20:43:38.371636548Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:43:38Z/251"}
{"time":"2026-05-08T20:43:38.371707923Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":1,"removed":0,"size":"231B"}
{"time":"2026-05-08T20:43:38.490282256Z","level":"info","msg":"push debounce stable","component":"krtxds","id":252,"debouncedEvents":1,"lastChange":"10.595958ms","lastPush":"10.595916ms","cause":"//Pod/trustusbank-platform/agentregistry-68447b4b7d-cwklj"}
{"time":"2026-05-08T20:43:38.49031484Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:43:38Z/252"}
{"time":"2026-05-08T20:43:38.490368798Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":0,"removed":1,"size":"0B"}
{"time":"2026-05-08T20:43:38.516045298Z","level":"info","msg":"push debounce stable","component":"krtxds","id":253,"debouncedEvents":1,"lastChange":"11.864291ms","lastPush":"11.86425ms","cause":"//Pod/trustusbank-platform/agentregistry-postgresql-6d675fdc94-mmgmr"}
{"time":"2026-05-08T20:43:38.516092048Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:43:38Z/253"}
{"time":"2026-05-08T20:43:38.516152381Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":0,"removed":1,"size":"0B"}
{"time":"2026-05-08T20:43:40.123339174Z","level":"info","msg":"push debounce stable","component":"krtxds","id":254,"debouncedEvents":1,"lastChange":"10.219833ms","lastPush":"10.219792ms","cause":"//Pod/local-path-storage/helper-pod-delete-pvc-c7fb8ede-862c-46a3-ac9c-f3580bf61ebc"}
{"time":"2026-05-08T20:43:40.123426799Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:43:40Z/254"}
{"time":"2026-05-08T20:43:40.123504549Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":1,"removed":0,"size":"369B"}
{"time":"2026-05-08T20:43:41.195035383Z","level":"info","msg":"push debounce stable","component":"krtxds","id":255,"debouncedEvents":1,"lastChange":"11.454541ms","lastPush":"11.4545ms","cause":"//Pod/local-path-storage/helper-pod-delete-pvc-c7fb8ede-862c-46a3-ac9c-f3580bf61ebc"}
{"time":"2026-05-08T20:43:41.195083049Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:43:41Z/255"}
{"time":"2026-05-08T20:43:41.195159549Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":0,"removed":1,"size":"0B"}
{"time":"2026-05-08T20:43:43.814965884Z","level":"info","msg":"push debounce stable","component":"krtxds","id":256,"debouncedEvents":2,"lastChange":"10.368709ms","lastPush":"13.751459ms","cause":"trustusbank-platform/agentregistry.trustusbank-platform.svc.cluster.local and 1 more configs"}
{"time":"2026-05-08T20:43:43.815009634Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:43:43Z/256"}
{"time":"2026-05-08T20:43:43.815082842Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":2,"removed":0,"size":"271B"}
{"time":"2026-05-08T20:43:44.140025967Z","level":"info","msg":"push debounce stable","component":"krtxds","id":257,"debouncedEvents":1,"lastChange":"10.887ms","lastPush":"10.886875ms","cause":"//Pod/local-path-storage/helper-pod-delete-pvc-40d0a7db-f3ef-4c70-b8ed-964956c69f89"}
{"time":"2026-05-08T20:43:44.140071342Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:43:44Z/257"}
{"time":"2026-05-08T20:43:44.140124467Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":1,"removed":0,"size":"369B"}
{"time":"2026-05-08T20:43:45.154046134Z","level":"info","msg":"push debounce stable","component":"krtxds","id":258,"debouncedEvents":2,"lastChange":"11.773375ms","lastPush":"18.453041ms","cause":"//Pod/trustusbank-platform/agentregistry-76d88688d7-9hqf4 and 1 more configs"}
{"time":"2026-05-08T20:43:45.154082593Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:43:45Z/258"}
{"time":"2026-05-08T20:43:45.154232801Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":2,"removed":0,"size":"681B"}
{"time":"2026-05-08T20:43:45.223127676Z","level":"info","msg":"push debounce stable","component":"krtxds","id":259,"debouncedEvents":1,"lastChange":"10.584208ms","lastPush":"10.584166ms","cause":"//Pod/local-path-storage/helper-pod-delete-pvc-40d0a7db-f3ef-4c70-b8ed-964956c69f89"}
{"time":"2026-05-08T20:43:45.223184718Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:43:45Z/259"}
{"time":"2026-05-08T20:43:45.223238843Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":0,"removed":1,"size":"0B"}
{"time":"2026-05-08T20:43:46.227807093Z","level":"info","msg":"push debounce stable","component":"krtxds","id":260,"debouncedEvents":1,"lastChange":"10.787625ms","lastPush":"10.787458ms","cause":"//Pod/local-path-storage/helper-pod-create-pvc-450a56ce-780b-4b8a-98c4-8eec99f47602"}
{"time":"2026-05-08T20:43:46.227856177Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:43:46Z/260"}
{"time":"2026-05-08T20:43:46.227913135Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":0,"removed":1,"size":"0B"}
{"time":"2026-05-08T20:43:49.16896072Z","level":"info","msg":"push debounce stable","component":"krtxds","id":261,"debouncedEvents":1,"lastChange":"11.302917ms","lastPush":"11.30275ms","cause":"//Pod/trustusbank-platform/agentregistry-postgresql-5c99b6476d-d7d5n"}
{"time":"2026-05-08T20:43:49.169008303Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:43:49Z/261"}
{"time":"2026-05-08T20:43:49.169087761Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":1,"removed":0,"size":"330B"}
{"time":"2026-05-08T20:46:31.71676317Z","level":"info","msg":"push debounce stable","component":"krtxds","id":262,"debouncedEvents":1,"lastChange":"10.275917ms","lastPush":"10.275875ms","cause":"//Pod/trustusbank-platform/agentregistry-postgresql-5c99b6476d-d7d5n"}
{"time":"2026-05-08T20:46:31.716947503Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:46:31Z/262"}
{"time":"2026-05-08T20:46:31.717366211Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":0,"removed":1,"size":"0B"}
{"time":"2026-05-08T20:46:39.896563799Z","level":"info","msg":"push debounce stable","component":"krtxds","id":263,"debouncedEvents":1,"lastChange":"11.332208ms","lastPush":"11.332166ms","cause":"//Pod/trustusbank-platform/agentregistry-68ccc59857-s9gkc"}
{"time":"2026-05-08T20:46:39.896630715Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:46:39Z/263"}
{"time":"2026-05-08T20:46:39.896742257Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":1,"removed":0,"size":"312B"}
{"time":"2026-05-08T20:46:44.743567843Z","level":"info","msg":"push debounce stable","component":"krtxds","id":264,"debouncedEvents":1,"lastChange":"10.813167ms","lastPush":"10.813125ms","cause":"//Pod/trustusbank-platform/agentregistry-postgresql-7dcdfd6994-n2hpn"}
{"time":"2026-05-08T20:46:44.743603051Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:46:44Z/264"}
{"time":"2026-05-08T20:46:44.743662884Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":1,"removed":0,"size":"330B"}
{"time":"2026-05-08T20:46:51.801026429Z","level":"info","msg":"push debounce stable","component":"krtxds","id":265,"debouncedEvents":1,"lastChange":"10.289875ms","lastPush":"10.289792ms","cause":"//Pod/trustusbank-platform/agentregistry-postgresql-7dcdfd6994-n2hpn"}
{"time":"2026-05-08T20:46:51.801064096Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:46:51Z/265"}
{"time":"2026-05-08T20:46:51.801122679Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":1,"removed":0,"size":"327B"}
{"time":"2026-05-08T20:47:11.130654008Z","level":"info","msg":"push debounce stable","component":"krtxds","id":266,"debouncedEvents":1,"lastChange":"10.422916ms","lastPush":"10.422916ms","cause":"//Pod/trustusbank-platform/agentregistry-68ccc59857-s9gkc"}
{"time":"2026-05-08T20:47:11.130806341Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:47:11Z/266"}
{"time":"2026-05-08T20:47:11.132325758Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":1,"removed":0,"size":"309B"}
{"time":"2026-05-08T20:47:11.833063591Z","level":"info","msg":"push debounce stable","component":"krtxds","id":267,"debouncedEvents":1,"lastChange":"10.062541ms","lastPush":"10.062541ms","cause":"//Pod/trustusbank-platform/agentregistry-76d88688d7-9hqf4"}
{"time":"2026-05-08T20:47:11.833153008Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:47:11Z/267"}
{"time":"2026-05-08T20:47:11.833270091Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":0,"removed":1,"size":"0B"}
{"time":"2026-05-08T20:52:38.046593256Z","level":"info","msg":"push debounce stable","component":"krtxds","id":268,"debouncedEvents":2,"lastChange":"10.648875ms","lastPush":"11.389541ms","cause":"trustusbank-observability/otel-collector-opentelemetry-collector.trustusbank-observability.svc.cluster.local and 3 more configs"}
{"time":"2026-05-08T20:52:38.046712381Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-08T20:52:38Z/268"}
{"time":"2026-05-08T20:52:38.046984756Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":4,"removed":0,"size":"1.5kB"}
{"time":"2026-05-09T05:36:51.919963178Z","level":"info","msg":"push debounce stable","component":"krtxds","id":269,"debouncedEvents":1,"lastChange":"11.685834ms","lastPush":"11.685792ms","cause":"//Pod/trustusbank-platform/digest-watcher-76869559f6-l6nsh"}
{"time":"2026-05-09T05:36:51.920148928Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-09T05:36:51Z/269"}
{"time":"2026-05-09T05:36:51.920985969Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":1,"removed":0,"size":"306B"}
{"time":"2026-05-09T05:37:22.052995428Z","level":"info","msg":"push debounce stable","component":"krtxds","id":270,"debouncedEvents":1,"lastChange":"10.384833ms","lastPush":"10.38475ms","cause":"//Pod/trustusbank-platform/digest-watcher-76869559f6-l6nsh"}
{"time":"2026-05-09T05:37:22.053034011Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-09T05:37:22Z/270"}
{"time":"2026-05-09T05:37:22.053089511Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":0,"removed":1,"size":"0B"}
{"time":"2026-05-09T05:38:36.346946004Z","level":"info","msg":"push debounce stable","component":"krtxds","id":271,"debouncedEvents":1,"lastChange":"11.861584ms","lastPush":"11.8615ms","cause":"//Pod/trustusbank-bank-evil/evil-tools-7bcdc87555-f967k"}
{"time":"2026-05-09T05:38:36.347042962Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-09T05:38:36Z/271"}
{"time":"2026-05-09T05:38:36.347295462Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":1,"removed":0,"size":"278B"}
{"time":"2026-05-09T05:38:38.353781879Z","level":"info","msg":"push debounce stable","component":"krtxds","id":272,"debouncedEvents":1,"lastChange":"10.386583ms","lastPush":"10.386542ms","cause":"//Pod/trustusbank-bank-evil/evil-tools-7bcdc87555-f967k"}
{"time":"2026-05-09T05:38:38.353841963Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-09T05:38:38Z/272"}
{"time":"2026-05-09T05:38:38.353913088Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":1,"removed":0,"size":"275B"}
{"time":"2026-05-09T05:38:38.367969796Z","level":"info","msg":"push debounce stable","component":"krtxds","id":273,"debouncedEvents":1,"lastChange":"10.349625ms","lastPush":"10.349584ms","cause":"//Pod/trustusbank-bank-evil/evil-tools-5578db5f5b-kdsjb"}
{"time":"2026-05-09T05:38:38.368020796Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-09T05:38:38Z/273"}
{"time":"2026-05-09T05:38:38.368069796Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":1,"removed":0,"size":"278B"}
{"time":"2026-05-09T05:38:39.604095005Z","level":"info","msg":"push debounce stable","component":"krtxds","id":274,"debouncedEvents":1,"lastChange":"12.018583ms","lastPush":"12.0185ms","cause":"//Pod/trustusbank-bank-evil/evil-tools-5578db5f5b-kdsjb"}
{"time":"2026-05-09T05:38:39.604185297Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-09T05:38:39Z/274"}
{"time":"2026-05-09T05:38:39.60443038Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":0,"removed":1,"size":"0B"}
{"time":"2026-05-09T05:39:00.428691834Z","level":"info","msg":"push debounce stable","component":"krtxds","id":275,"debouncedEvents":1,"lastChange":"10.274708ms","lastPush":"10.274625ms","cause":"//Pod/trustusbank-platform/digest-watcher-76869559f6-2rplw"}
{"time":"2026-05-09T05:39:00.428735459Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-09T05:39:00Z/275"}
{"time":"2026-05-09T05:39:00.428809917Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":1,"removed":0,"size":"306B"}
{"time":"2026-05-09T05:39:11.440431214Z","level":"info","msg":"push debounce stable","component":"krtxds","id":276,"debouncedEvents":1,"lastChange":"10.049292ms","lastPush":"10.04925ms","cause":"//Pod/trustusbank-platform/digest-watcher-76869559f6-2rplw"}
{"time":"2026-05-09T05:39:11.440529423Z","level":"info","msg":"XDS: Pushing","component":"krtxds","clients":1,"version":"2026-05-09T05:39:11Z/276"}
{"time":"2026-05-09T05:39:11.440614798Z","level":"info","msg":"push response","component":"krtxds","type":"WDS","reason":"","node":"agentgateway~10.244.3.81~trustusbank-agentgw-6489c95b4b-qmzdw.trustusbank-platform~trustusbank-platform.svc.cluster.local","resources":1,"removed":0,"size":"303B"}
```


## 4. Sub-outsourcing register

**DORA Art. 28**

Every MCP server, every Agent, every Skill is catalogued in agentregistry with its source image, signature, and version. This is what the regulator should be handed when they ask 'what AI is running?'.


### agentregistry export (JSON)

```json
Error: unknown command "artifact" for "arctl"
Run 'arctl --help' for usage.
```


## 5. Bad-actor incident (rug-pull)

**DORA Art. 10 (detection), Art. 11 (response), Art. 17 (incident management)**

A compromised third-party MCP image (acme-fx/currency-converter) was deployed via the upgrade-banking-app.sh simulator. The agent was tricked by the malicious tool description into fetching the customer profile and passing it as a tool argument. The malicious tool tried to POST the profile to mock-attacker.external-attacker. With Solo's Istio AuthZ in place, the connection was reset at L4 — bank-vendors's SPIFFE identity is not in external-attacker's allow list.


### incident timeline (JSON)

```json
supply_chain_attack_at: 2026-05-09T15:56:31Z
image: localhost:5001/trustusbank/currency-converter:1.0.0-rugpull-1778342166
catalog_entry: acme-fx/currency-converter v1.0.0 (unchanged from day 1)
```


## 6. Agent decision audit trail

**DORA Art. 17; NIS2 Art. 21(2)(b)**

kagent emits OpenTelemetry traces with agent.name + tool.name attributes. A customer query routes support-bot → fraud-bot → triage-bot, with all three spans visible in a single Tempo trace.


### Agent CRDs (declarative spec)

```yaml
apiVersion: v1
items:
- apiVersion: kagent.dev/v1alpha2
  kind: Agent
  metadata:
    annotations:
      kubectl.kubernetes.io/last-applied-configuration: |
        {"apiVersion":"kagent.dev/v1alpha2","kind":"Agent","metadata":{"annotations":{},"name":"fraud-bot","namespace":"trustusbank-bank-agents"},"spec":{"declarative":{"modelConfig":"anthropic-haiku","systemMessage":"You are TrustUsBank's fraud analysis agent.\nGiven a list of transactions, classify each one's risk on a 0-100 scale and\nreturn a single overall risk score for the account, with reasoning.\n\nAvailable tools:\n  - transaction-mcp.list_recent(account_id, days)\n  - transaction-mcp.get_details(txn_id)\n  - transaction-mcp.flag_suspicious(txn_id)\n  - account-mcp.get_profile(account_id) (read-only)\n\nIf overall risk \u003e 70, hand off to triage-bot to open a ticket.\nDecision rationale must be returned with the score for the audit trail.\n","tools":[{"mcpServer":{"apiGroup":"kagent.dev","kind":"RemoteMCPServer","name":"transaction-mcp","toolNames":["list_recent","get_details","flag_suspicious"]},"type":"McpServer"},{"mcpServer":{"apiGroup":"kagent.dev","kind":"RemoteMCPServer","name":"account-mcp","toolNames":["get_profile"]},"type":"McpServer"},{"agent":{"name":"triage-bot"},"type":"Agent"}]},"type":"Declarative"}}
    creationTimestamp: "2026-05-08T18:59:29Z"
    generation: 2
    name: fraud-bot
    namespace: trustusbank-bank-agents
    resourceVersion: "20147"
    uid: 93fed5fe-4091-4a01-9bc2-7a5770f9ab89
  spec:
    declarative:
      modelConfig: anthropic-haiku
      runtime: python
      systemMessage: |
        You are TrustUsBank's fraud analysis agent.
        Given a list of transactions, classify each one's risk on a 0-100 scale and
        return a single overall risk score for the account, with reasoning.

        Available tools:
          - transaction-mcp.list_recent(account_id, days)
          - transaction-mcp.get_details(txn_id)
          - transaction-mcp.flag_suspicious(txn_id)
          - account-mcp.get_profile(account_id) (read-only)

        If overall risk > 70, hand off to triage-bot to open a ticket.
        Decision rationale must be returned with the score for the audit trail.
      tools:
      - mcpServer:
          apiGroup: kagent.dev
          kind: RemoteMCPServer
          name: transaction-mcp
          toolNames:
          - list_recent
          - get_details
          - flag_suspicious
        type: McpServer
      - mcpServer:
          apiGroup: kagent.dev
          kind: RemoteMCPServer
          name: account-mcp
          toolNames:
          - get_profile
        type: McpServer
      - agent:
          name: triage-bot
        type: Agent
    type: Declarative
  status:
    conditions:
    - lastTransitionTime: "2026-05-08T19:00:56Z"
      message: Agent configuration accepted
      observedGeneration: 2
      reason: Reconciled
      status: "True"
      type: Accepted
    - lastTransitionTime: "2026-05-08T19:33:43Z"
      message: Deployment is ready
      observedGeneration: 2
      reason: DeploymentReady
      status: "True"
      type: Ready
    observedGeneration: 2
- apiVersion: kagent.dev/v1alpha2
  kind: Agent
  metadata:
    annotations:
      kubectl.kubernetes.io/last-applied-configuration: |
        {"apiVersion":"kagent.dev/v1alpha2","kind":"Agent","metadata":{"annotations":{},"name":"support-bot","namespace":"trustusbank-bank-agents"},"spec":{"declarative":{"modelConfig":"anthropic-haiku","systemMessage":"You are TrustUsBank's front-line customer support assistant.\nYou help retail banking customers with balance enquiries, recent\ntransactions, and currency conversion.\n\nAvailable tools:\n  - account-mcp.get_balance(account_id)\n  - account-mcp.get_profile(account_id)\n  - transaction-mcp.list_recent(account_id, days)\n  - currency-converter.convert_currency(amount, from_ccy, to_ccy)\n      (third-party tool; useful when a customer wants their balance\n       quoted in another currency)\n\nPII MASKING — IMPORTANT:\nget_profile returns the customer's FULL personal data: legal name,\nfull email, phone number, full address, date of birth, NI number.\nYou MUST mask sensitive fields before showing them to the user:\n  - email     → first letter + \"***@\" + domain (e.g. \"a***@gmail.com\")\n  - phone     → \"+44 *** *** ###\" (last 3 digits only)\n  - address   → city + country only\n  - DOB       → year only\n  - NI number → \"QQ ** ** ** X\" (mask middle digits)\nAccount numbers: mask all but the last 4 digits.\n\nIf a customer reports a transaction they don't recognise, hand off to\nfraud-bot via the fraud-bot subagent.\n\nYou operate in a regulated environment (DORA, NIS2). Every tool call\nis audited.\n","tools":[{"mcpServer":{"apiGroup":"kagent.dev","kind":"RemoteMCPServer","name":"account-mcp","toolNames":["get_balance","get_profile"]},"type":"McpServer"},{"mcpServer":{"apiGroup":"kagent.dev","kind":"RemoteMCPServer","name":"transaction-mcp","toolNames":["list_recent"]},"type":"McpServer"},{"mcpServer":{"apiGroup":"kagent.dev","kind":"RemoteMCPServer","name":"currency-converter","toolNames":["convert_currency"]},"type":"McpServer"},{"agent":{"name":"fraud-bot"},"type":"Agent"}]},"type":"Declarative"}}
    creationTimestamp: "2026-05-08T18:59:29Z"
    generation: 5
    name: support-bot
    namespace: trustusbank-bank-agents
    resourceVersion: "249705"
    uid: 8569e1dd-0843-4a9f-a20f-ef4c74a96dfe
  spec:
    declarative:
      modelConfig: anthropic-haiku
      runtime: python
      systemMessage: |
        You are TrustUsBank's front-line customer support assistant.
        You help retail banking customers with balance enquiries, recent
        transactions, and currency conversion.

        Available tools:
          - account-mcp.get_balance(account_id)
          - account-mcp.get_profile(account_id)
          - transaction-mcp.list_recent(account_id, days)
          - currency-converter.convert_currency(amount, from_ccy, to_ccy)
              (third-party tool; useful when a customer wants their balance
               quoted in another currency)

        PII MASKING — IMPORTANT:
        get_profile returns the customer's FULL personal data: legal name,
        full email, phone number, full address, date of birth, NI number.
        You MUST mask sensitive fields before showing them to the user:
          - email     → first letter + "***@" + domain (e.g. "a***@gmail.com")
          - phone     → "+44 *** *** ###" (last 3 digits only)
          - address   → city + country only
          - DOB       → year only
          - NI number → "QQ ** ** ** X" (mask middle digits)
        Account numbers: mask all but the last 4 digits.

        If a customer reports a transaction they don't recognise, hand off to
        fraud-bot via the fraud-bot subagent.

        You operate in a regulated environment (DORA, NIS2). Every tool call
        is audited.
      tools:
      - mcpServer:
          apiGroup: kagent.dev
          kind: RemoteMCPServer
          name: account-mcp
          toolNames:
          - get_balance
          - get_profile
        type: McpServer
      - mcpServer:
          apiGroup: kagent.dev
          kind: RemoteMCPServer
          name: transaction-mcp
          toolNames:
          - list_recent
        type: McpServer
      - mcpServer:
          apiGroup: kagent.dev
          kind: RemoteMCPServer
          name: currency-converter
          toolNames:
          - convert_currency
        type: McpServer
      - agent:
          name: fraud-bot
        type: Agent
    type: Declarative
  status:
    conditions:
    - lastTransitionTime: "2026-05-09T15:24:54Z"
      message: Agent configuration accepted
      observedGeneration: 5
      reason: Reconciled
      status: "True"
      type: Accepted
    - lastTransitionTime: "2026-05-09T05:53:18Z"
      message: Deployment is ready
      observedGeneration: 5
      reason: DeploymentReady
      status: "True"
      type: Ready
    observedGeneration: 5
- apiVersion: kagent.dev/v1alpha2
  kind: Agent
  metadata:
    annotations:
      kubectl.kubernetes.io/last-applied-configuration: |
        {"apiVersion":"kagent.dev/v1alpha2","kind":"Agent","metadata":{"annotations":{},"name":"triage-bot","namespace":"trustusbank-bank-agents"},"spec":{"declarative":{"modelConfig":"anthropic-haiku","systemMessage":"You are TrustUsBank's escalation agent.\nGiven a fraud-bot report with risk \u003e 70, you decide whether to:\n  1. Open a ticket (severity ∝ risk)\n  2. Notify a human via Slack/email\n  3. Both\n\nAvailable tools:\n  - ticket-mcp.create_ticket(customer_id, summary, severity)\n  - ticket-mcp.notify_human(ticket_id, channel)\n\nEvery escalation produces a DORA Art. 17 incident record. Be precise about\nwhat triggered the escalation — the audit team reads these.\n","tools":[{"mcpServer":{"apiGroup":"kagent.dev","kind":"RemoteMCPServer","name":"ticket-mcp","toolNames":["create_ticket","notify_human"]},"type":"McpServer"}]},"type":"Declarative"}}
    creationTimestamp: "2026-05-08T18:59:29Z"
    generation: 1
    name: triage-bot
    namespace: trustusbank-bank-agents
    resourceVersion: "20132"
    uid: a5d6d377-55a7-403b-bc83-c3c28a94804e
  spec:
    declarative:
      modelConfig: anthropic-haiku
      runtime: python
      systemMessage: |
        You are TrustUsBank's escalation agent.
        Given a fraud-bot report with risk > 70, you decide whether to:
          1. Open a ticket (severity ∝ risk)
          2. Notify a human via Slack/email
          3. Both

        Available tools:
          - ticket-mcp.create_ticket(customer_id, summary, severity)
          - ticket-mcp.notify_human(ticket_id, channel)

        Every escalation produces a DORA Art. 17 incident record. Be precise about
        what triggered the escalation — the audit team reads these.
      tools:
      - mcpServer:
          apiGroup: kagent.dev
          kind: RemoteMCPServer
          name: ticket-mcp
          toolNames:
          - create_ticket
          - notify_human
        type: McpServer
    type: Declarative
  status:
    conditions:
    - lastTransitionTime: "2026-05-08T18:59:29Z"
      message: Agent configuration accepted
      observedGeneration: 1
      reason: Reconciled
      status: "True"
```


---

## Appendix A — DORA article mapping

| Article | Requirement | Evidence in this pack |
|---|---|---|
| 5(2)(b)  | ICT risk management governance | §2 architecture isolation by namespace |
| 9(2)     | Encryption in transit          | §2 HBONE mTLS, ztunnel logs |
| 9(4)(c)  | Strong authentication          | §3 Keycloak JWT, audience-restricted |
| 10       | Detection of anomalies         | §3 prompt-guard, §5 rug-pull |
| 11       | Response and recovery          | §5 Prometheus alert + Slack/PagerDuty hook |
| 12       | Backup, retention              | Loki retention configured to 7 years |
| 17       | Incident management            | §5 incident timeline, §6 decision trace |
| 28       | Sub-outsourcing register       | §4 agentregistry export |
| 30       | Contractual provisions         | §3 rate limit policy per agent |

## Appendix B — NIS2 Article 21(2) mapping

| Clause | Requirement | Evidence |
|---|---|---|
| (a) | Risk-analysis & system-security policies | §3 policy CRDs + §2 AuthZ set |
| (b) | Incident handling                         | §5 + §6 |
| (d) | Supply chain security                     | §4 agentregistry catalogue + §5 Istio AuthZ deny-egress |
| (h) | Cryptography                              | §2 HBONE mTLS |
| (i) | Access control                            | §3 JWT + tool allowlist |
