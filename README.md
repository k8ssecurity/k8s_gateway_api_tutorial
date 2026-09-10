# babanasoep

A complete hands-on lab for the Kubernetes Gateway API. You get a local KIND cluster with Cilium, a LoadBalancer (MetalLB or Cilium LB-IPAM — your choice), Envoy Gateway, and Agentgateway all wired together, plus two tutorial docs that walk through the setup at different depths.

Target audience: network engineers comfortable with Linux/Docker but new to Kubernetes, and AI engineers who want a realistic place to experiment with MCP traffic through a real gateway.

## Choosing your LoadBalancer (`LB_PROVIDER`)

KIND has no cloud LoadBalancer, so the lab provides external IPs one of two
ways. Pick with the `LB_PROVIDER` environment variable — **same lab, one knob**,
no separate branch:

```bash
LB_PROVIDER=metallb ./setup.sh   # default — MetalLB (separate controller)
LB_PROVIDER=cilium  ./setup.sh   # Cilium's built-in LB-IPAM + L2 (no extra pods)
```

| | `metallb` (default) | `cilium` |
|---|---|---|
| Mechanism | MetalLB controller in `metallb-system` | Cilium LB-IPAM + L2 announcements |
| Extra pods | MetalLB controller + speakers | none — Cilium is already the CNI |
| Config objects | `IPAddressPool` + `L2Advertisement` | `CiliumLoadBalancerIPPool` + `CiliumL2AnnouncementPolicy` |
| Best for | CNI-agnostic, "classic" on-prem pattern | leaner stack when you're already on Cilium |

Both produce the same Gateway IPs (`172.18.255.x`) and identical test commands.
When `LB_PROVIDER=cilium`, `setup.sh` also enables L2 announcements on the
Cilium install automatically.

## What you get

After `./setup.sh` you have a working cluster with:

- 3-node KIND cluster (1 control-plane + 2 workers)
- Cilium CNI with kube-proxy replacement
- LoadBalancer IPs from MetalLB **or** Cilium LB-IPAM + L2 (your choice via `LB_PROVIDER`)
- Gateway API CRDs (Experimental channel)
- Envoy Gateway routing a sample webapp on HTTP/HTTPS, with stable + canary deployments and example HTTPRoutes for traffic-split, header-match, cross-namespace routing (ReferenceGrant), and TLSRoute passthrough
- Agentgateway exposing the public Microsoft Learn MCP server at `/mcp-mslearn` **and** OpenAI chat completions at `/openai` — so both the tool and the LLM legs of an agent run through one gateway
- An OpenAI Agents SDK test client (`test-mslearn-agent.py`) that routes **both** its MCP tool calls and its LLM inference through agentgateway

## Where to read next

- [`testing.md`](testing.md) — **quick guide for driving the lab after `./setup.sh`**. Covers both the Envoy Gateway sample webapp and the agentgateway/Microsoft Learn MCP path, with separate macOS and Linux paths and a small troubleshooting section. Start here if you just want to verify everything works.
- [`kubernetes-gateway-api-tutorial.md`](kubernetes-gateway-api-tutorial.md) — full tutorial. Walks through the cluster, Cilium, the LoadBalancer (MetalLB or Cilium LB-IPAM), Envoy Gateway, the sample app, and the HTTPRoute/TLSRoute examples step by step. Read this if you want to understand what `setup.sh` did under the hood.
- [`agentgateway.md`](agentgateway.md) — the AI-gateway extension explained. Installs agentgateway alongside Envoy Gateway, wires Microsoft Learn MCP as an `AgentgatewayBackend`, routes the agent's OpenAI inference through the gateway, and discusses tool gating with `AgentgatewayPolicy`. Read this after the main tutorial.

All three docs assume the same lab folder, so the cluster you build with the first tutorial is the one you test in the second and extend in the third.

## Quick start

```bash
cd gateway-api-lab
./setup.sh
```

That runs the full sequence — cluster, CNI, your chosen LoadBalancer (`LB_PROVIDER`, default MetalLB), Gateway API, Envoy Gateway, sample app + routes, agentgateway, Microsoft Learn MCP route, `/etc/hosts` update, and a printout of platform-appropriate test commands at the end.

To skip the AI-gateway step:

```bash
INSTALL_AGENTGATEWAY=false ./setup.sh
```

## Repository layout

```
.
├── README.md                              ← you are here
├── testing.md                             ← how to test after setup.sh (macOS + Linux)
├── kubernetes-gateway-api-tutorial.md     ← Envoy Gateway walkthrough
├── agentgateway.md                        ← Agentgateway / MCP walkthrough
└── gateway-api-lab/
    ├── setup.sh                           ← end-to-end installer
    ├── versions.env                       ← pinned versions (single source of truth)
    ├── cleanup.sh                         ← tear it all down
    ├── test-mslearn-agent.py              ← OpenAI Agents SDK test client
    │
    ├── 01-kind-config.yaml                ← cluster topology
    ├── 02-metallb-config.yaml             ← MetalLB IP pool (LB_PROVIDER=metallb)
    ├── 02-cilium-lb.yaml                  ← Cilium LB-IPAM + L2 pool (LB_PROVIDER=cilium)
    ├── 03-gateway.yaml                    ← Envoy Gateway: eg-gateway (80/443)
    ├── 04-webapp.yaml                     ← sample app: stable
    ├── 05-webapp-canary.yaml              ← sample app: canary
    ├── 06-httproute-basic.yaml            ← Envoy: route all → stable
    ├── 07-httproute-canary.yaml           ← Envoy: 90/10 traffic split
    ├── 08-httproute-header.yaml           ← Envoy: route by X-Canary header
    ├── 09-tlsroute-passthrough.yaml       ← Envoy: TLS passthrough (SNI-based)
    ├── 10-agentgateway.yaml               ← Agentgateway: proxy Gateway
    ├── 11-mcp-mslearn.yaml                ← Agentgateway: Microsoft Learn MCP route
    ├── 12-llm-openai.yaml                 ← Agentgateway: OpenAI LLM route (/openai)
    └── 13-referencegrant-crossns.yaml     ← Envoy: cross-namespace route + ReferenceGrant
```

## Pinned versions (June 2026)

All versions live in [`gateway-api-lab/versions.env`](gateway-api-lab/versions.env)
(the single source of truth — `setup.sh` sources it). Bump them there.

| Component | Version |
|---|---|
| Kubernetes (kind node) | v1.33.7 (kind v0.31.0) |
| Cilium | 1.19.3 |
| MetalLB (`LB_PROVIDER=metallb`) | v0.15.3 |
| Gateway API | v1.5.0 (Experimental channel) |
| Envoy Gateway | v1.7.3 |
| Agentgateway | v1.2.1 |

## macOS vs Linux — one thing to know

On Linux, the LoadBalancer IPs live on the host's Docker bridge — `curl http://<gateway-ip>/` from your shell just works.

On macOS, Docker Desktop runs containers inside a Linux VM. The LoadBalancer IPs are inside that VM and **not routable from your Mac terminal**. To test against either gateway, use one of:

1. `kubectl port-forward` — works everywhere, recommended.
2. `docker exec gateway-api-lab-control-plane curl ...` — runs the request from inside the kind network.

Both tutorials and `setup.sh`'s final output show concrete examples for each path.

> **Port convention** — the lab runs two gateways, so they get different local ports when port-forwarding: **Envoy Gateway (webapp) → `8080`/`8443`, agentgateway (MCP + LLM) → `8081`**. They're separate implementations on separate IPs, so a single port reaches only one of them — keeping them split lets both run at once.

## Prerequisites

| Tool | Purpose |
|---|---|
| Docker (Desktop or Engine) | Container runtime |
| `kubectl` | Kubernetes CLI |
| `kind` | Kubernetes-in-Docker |
| `helm` | Package manager for Envoy Gateway + agentgateway |
| `cilium` CLI | CNI install/management |
| `openssl` | TLS certificate generation |
| `python3` + `pip` | Only for the OpenAI Agents SDK test client |

Installation commands for both macOS and Linux are in [Part 1 of the main tutorial](kubernetes-gateway-api-tutorial.md#part-1-environment-setup).

## Cleanup

```bash
cd gateway-api-lab
./cleanup.sh        # or: kind delete cluster --name gateway-api-lab
```
