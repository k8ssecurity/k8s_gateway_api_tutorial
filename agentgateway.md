# Agentgateway Setup on KIND

This doc installs the agentgateway control plane, creates an agentgateway proxy (Gateway API `Gateway`), wires up an MCP server through the gateway, and routes an agent's OpenAI inference through it — so both the tool and LLM legs of an agent flow through one gateway.

---

## What is Agentgateway?

**Agentgateway is a SEPARATE gateway from Envoy Gateway.** It's specifically designed for AI agent communications.

| Aspect | Envoy Gateway | Agentgateway |
|--------|---------------|--------------|
| **Purpose** | Traditional API traffic (HTTP, gRPC, TCP) | AI agent traffic (MCP, A2A protocols) |
| **Data Plane** | Envoy Proxy (C++) | Agentgateway (Rust) |
| **Use Cases** | Web apps, microservices, ingress | LLM tools, MCP servers, agent-to-agent |
| **GatewayClass** | `eg` (Envoy Gateway) | `agentgateway` |
| **Control Plane** | Envoy Gateway controller | agentgateway controller |

### Key Concepts

| Term | Description |
|------|-------------|
| **MCP** | Model Context Protocol - standardizes how LLMs connect to external tools |
| **A2A** | Agent-to-Agent protocol - enables AI agents to communicate |
| **agentgateway** | Standalone control plane and data plane for AI/agent traffic (decoupled from kgateway since v1.0) |
| **AgentgatewayBackend** | Custom resource defining MCP server targets |
| **AgentgatewayPolicy** | Tool-level allow/deny rules (CEL expressions) |

### When to Use Which?

- **Envoy Gateway**: Web applications, REST APIs, microservices, traditional L7 routing
- **Agentgateway**: LLM tool servers, MCP integrations, AI agent orchestration, tool access control

You can run **both** in the same cluster - they use different GatewayClasses and don't conflict.

---

## Prerequisites

This guide assumes you already have:
- A working KIND cluster (from the Gateway API tutorial — `./setup.sh` in `gateway-api-lab/`)
- Gateway API CRDs installed (the tutorial installs the Experimental channel of v1.5.0)
- A LoadBalancer configured so `LoadBalancer` Services get an IP — either MetalLB or Cilium LB-IPAM (see Part 3 of the tutorial / `LB_PROVIDER`). Agentgateway works the same with either.
- `kubectl` and `helm` installed

---

## Automated install (recommended)

As of June 2026, `gateway-api-lab/setup.sh` installs agentgateway and wires the Microsoft Learn MCP server automatically. Running `./setup.sh` with the default `INSTALL_AGENTGATEWAY=true` does steps 1, 2, 3 and 4 of this doc for you. Skip to [Section 5](#5-test-with-the-openai-agents-sdk) if you used the script.

To skip the AI-gateway step explicitly:

```bash
INSTALL_AGENTGATEWAY=false ./setup.sh
```

The sections below walk through what `setup.sh` does and how to do it by hand.

---

## 1) Install agentgateway (control plane)

As of agentgateway v1.0 the project was decoupled from kgateway and the Helm charts moved to `cr.agentgateway.dev/charts/`. The version is pinned in the lab's `versions.env` (single source of truth) — source it so this matches the rest of the lab:

```bash
source gateway-api-lab/versions.env          # defines AGENTGATEWAY_VERSION
export AGW_VERSION="${AGENTGATEWAY_VERSION:-v1.2.1}"   # fallback if versions.env isn't sourced
```

Install the CRDs (this also creates the `agentgateway-system` namespace):

```bash
helm upgrade -i agentgateway-crds \
  oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --create-namespace --namespace agentgateway-system \
  --version "${AGW_VERSION}"
```

Install the controller:

```bash
helm upgrade -i agentgateway \
  oci://cr.agentgateway.dev/charts/agentgateway \
  --namespace agentgateway-system \
  --version "${AGW_VERSION}"
```

Verify the controller is running and the `agentgateway` GatewayClass was auto-created:

```bash
kubectl get pods -n agentgateway-system
kubectl get gatewayclass agentgateway
```

Expected GatewayClass output:

```
NAME           CONTROLLER                       ACCEPTED   AGE
agentgateway   agentgateway.dev/agentgateway    True       30s
```

---

## 2) Create an agentgateway proxy (Gateway)

This creates:

- a `Gateway` named `agentgateway-proxy`
- a backing `Deployment` and `Service` of the same name in `agentgateway-system`

The manifest lives in `gateway-api-lab/10-agentgateway.yaml`:

```bash
kubectl apply -f 10-agentgateway.yaml

kubectl wait --timeout=5m -n agentgateway-system \
  gateway/agentgateway-proxy --for=condition=Programmed
```

Inspect:

```bash
kubectl get gateway,deployment,svc -n agentgateway-system
```

### Access methods

| Platform | Method | Command |
|---|---|---|
| Linux | LoadBalancer EXTERNAL-IP (direct) | `kubectl get svc -n agentgateway-system agentgateway-proxy` then curl the IP |
| Linux | `kubectl port-forward` | `kubectl -n agentgateway-system port-forward deployment/agentgateway-proxy 8081:80` |
| macOS | `kubectl port-forward` (required — LoadBalancer IP is not routable from the host) | `kubectl -n agentgateway-system port-forward deployment/agentgateway-proxy 8081:80` |
| macOS | `docker exec` into a kind node | `docker exec gateway-api-lab-control-plane curl ...` against the LoadBalancer IP |

For the OpenAI Agents SDK test in Section 5, **use port-forward on both platforms** so the script can target `http://localhost:8081/`.

> **Port convention.** This lab runs two gateways. Envoy Gateway (the webapp from the main tutorial) uses `8080`/`8443`; **agentgateway uses `8081`**. They're separate Gateway API implementations on separate IPs, so a single local port reaches only one of them — keep them split and both can run at once. All agentgateway commands in this doc use `8081`.

---

## 3) Option A: Route to a local MCP server (static MCP)

### 3.1 Deploy a sample MCP server (website fetcher)

```bash
kubectl apply -f- <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mcp-website-fetcher
spec:
  selector:
    matchLabels:
      app: mcp-website-fetcher
  template:
    metadata:
      labels:
        app: mcp-website-fetcher
    spec:
      containers:
      - name: mcp-website-fetcher
        image: ghcr.io/peterj/mcp-website-fetcher:main
        imagePullPolicy: Always
---
apiVersion: v1
kind: Service
metadata:
  name: mcp-website-fetcher
  labels:
    app: mcp-website-fetcher
spec:
  selector:
    app: mcp-website-fetcher
  ports:
  - port: 80
    targetPort: 8000
    appProtocol: kgateway.dev/mcp
EOF
```

### 3.2 Create an AgentgatewayBackend

```bash
kubectl apply -f- <<'EOF'
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: mcp-backend
spec:
  mcp:
    targets:
    - name: mcp-target
      static:
        host: mcp-website-fetcher.default.svc.cluster.local
        port: 80
        protocol: SSE
EOF
```

### 3.3 Create an HTTPRoute to the MCP backend

```bash
kubectl apply -f- <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: mcp
spec:
  parentRefs:
    - name: agentgateway-proxy
      namespace: agentgateway-system
  rules:
    - backendRefs:
      - name: mcp-backend
        group: agentgateway.dev
        kind: AgentgatewayBackend
EOF
```

### 3.4 Verify with MCP Inspector

In another terminal, keep port-forward running:
```bash
kubectl port-forward deployment/agentgateway-proxy -n agentgateway-system 8081:80
```

Run MCP Inspector:
```bash
npx modelcontextprotocol/inspector#0.18.0
```

Connect:
- Transport Type: Streamable HTTP
- URL: `http://localhost:8081/mcp`

---

## 4) Option B: Route to the remote Microsoft Learn MCP server (HTTPS, anonymous)

[Microsoft Learn MCP](https://learn.microsoft.com/en-us/training/support/mcp) is a public, anonymous streamable-HTTP MCP server hosted at `https://learn.microsoft.com/api/mcp`. It exposes tools for searching Microsoft documentation and fetching articles and code samples. No API key, no PAT — it just works.

This is what `setup.sh` configures automatically. Both resources live together in `gateway-api-lab/11-mcp-mslearn.yaml`:

```bash
kubectl apply -f 11-mcp-mslearn.yaml
```

That single manifest contains:

1. **AgentgatewayBackend `mslearn-mcp-backend`** — declares Microsoft Learn MCP as an upstream:
   - `protocol: StreamableHTTP` — matches Microsoft Learn's transport (one HTTP endpoint that can upgrade to SSE for streaming responses). The other valid value is `SSE` for SSE-only upstreams.
   - `path: /api/mcp` — the path on the upstream where the MCP endpoint lives.
   - `policies.tls.sni: learn.microsoft.com` — required because Microsoft's load balancer relies on SNI to route to the right backend.

2. **HTTPRoute `mcp-mslearn`** — attaches the backend to the proxy at `/mcp-mslearn`.

Clients now reach Microsoft Learn MCP at `http://<agentgateway-proxy>/mcp-mslearn`.

The file also contains a commented-out `AgentgatewayPolicy` snippet you can uncomment to restrict the backend to a single tool (see Section 7 for context).

---

## 5) Test with the OpenAI Agents SDK

The Microsoft Learn docs explicitly recommend using an agent framework rather than calling the MCP endpoint directly. We use the [OpenAI Agents SDK](https://openai.github.io/openai-agents-python/) for this, which has first-class support for streamable-HTTP MCP servers via `MCPServerStreamableHttp`.

### 5.1 Port-forward (both macOS and Linux)

The agentgateway proxy Service has a LoadBalancer EXTERNAL-IP, but on macOS that IP is not reachable from your host (Docker Desktop runs containers inside a Linux VM). The simplest cross-platform option is port-forward — keep it running in a dedicated terminal:

```bash
kubectl -n agentgateway-system port-forward \
  deployment/agentgateway-proxy 8081:80
```

On Linux you can alternatively curl the LoadBalancer IP directly, but port-forward keeps the rest of this section identical between platforms.

### 5.2 Install the OpenAI Agents SDK and export your API key

```bash
pip install --upgrade openai-agents
export OPENAI_API_KEY=sk-...
```

### 5.3 Run the included test client

`gateway-api-lab/test-mslearn-agent.py` connects to `http://localhost:8081/mcp-mslearn`, asks the agent a Microsoft-docs question, and prints the answer. The snippet below is **simplified to the MCP essentials** — the runnable script in the repo also routes the agent's LLM inference through agentgateway (see [Section 6](#6-route-the-agents-llm-calls-through-the-gateway)), so the two differ slightly:

```python
import asyncio, os, sys
from agents import Agent, Runner
from agents.mcp import MCPServerStreamableHttp

async def main():
    async with MCPServerStreamableHttp(
        name="Microsoft Learn Docs",
        params={"url": "http://localhost:8081/mcp-mslearn", "timeout": 30},
        cache_tools_list=True,
    ) as mcp_server:
        tools = await mcp_server.list_tools()
        print("Tools:", ", ".join(t.name for t in tools), file=sys.stderr)

        agent = Agent(
            name="Microsoft docs assistant",
            instructions=(
                "Use Microsoft Learn MCP tools to search official docs "
                "before answering. Cite the URLs you used."
            ),
            model=os.environ.get("OPENAI_MODEL", "gpt-4.5-mini"),
            mcp_servers=[mcp_server],
        )
        result = await Runner.run(
            agent,
            "What is Azure App Service and what languages does it support?",
        )
        print(result.final_output)

asyncio.run(main())
```

Run it:

```bash
cd gateway-api-lab
python3 test-mslearn-agent.py
```

What you should see:

1. A short line on stderr listing the tools Microsoft Learn MCP exposes — typically `microsoft_docs_search`, `microsoft_docs_fetch`, plus one or two related tools.
2. A multi-paragraph answer that quotes specific Microsoft Learn URLs.

If the Agent hangs or the tool list is empty, the most common causes are:
- Port-forward isn't running (or is binding a different port).
- The `mslearn-mcp-backend` AgentgatewayBackend is missing `protocol: StreamableHTTP`, in which case agentgateway defaults to SSE and silently fails the streamable-HTTP handshake.
- Egress from the cluster to `learn.microsoft.com:443` is blocked (rare for local KIND, common in corporate environments).

---

## 6) Route the agent's LLM calls through the gateway

So far only the agent's **tool** calls (MCP) flow through agentgateway — its **LLM inference** still goes straight to `api.openai.com`. Routing inference through the gateway too makes agentgateway the single control point for both legs, which is where the AI-gateway value shows up: the gateway holds the provider credential (the agent never does), and you get one place to enforce model allow-listing, token/cost limits, and rate limiting.

agentgateway has a built-in OpenAI provider for exactly this. The manifest lives in `gateway-api-lab/12-llm-openai.yaml`.

### 6.1 Store the OpenAI key in a Secret

The gateway reads the key from this Secret and injects it into upstream requests — it even overrides any key the client sends, so the agent can use a dummy key:

```bash
kubectl create secret generic openai-secret -n agentgateway-system \
  --from-literal=Authorization="Bearer $OPENAI_API_KEY"
```

### 6.2 Apply the LLM backend + route

```bash
kubectl apply -f 12-llm-openai.yaml
```

That manifest contains:

1. **AgentgatewayBackend `openai-llm-backend`** — `spec.ai.provider.openai` (upstream defaults to `api.openai.com:443`, no SNI needed), pinned to `gpt-4.5-mini`, with `policies.auth.secretRef` pointing at `openai-secret`.
2. **HTTPRoute `openai-llm`** — attaches the backend at `/openai`. agentgateway auto-rewrites matched requests to OpenAI's `/v1/chat/completions`.

### 6.3 Smoke-test the LLM path

```bash
curl -s http://localhost:8081/openai/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model":"gpt-4.5-mini","messages":[{"role":"user","content":"hi"}]}' \
  | jq -r '.choices[0].message.content // .error.message'
```

A completion means success; a `401` means the Secret holds a bad key.

### 6.4 How the test client routes inference

`test-mslearn-agent.py` points the OpenAI Agents SDK at `http://localhost:8081/openai`. Two non-obvious details are required:

- **`set_default_openai_api("chat_completions")`** — the SDK defaults to the Responses API, but agentgateway's OpenAI backend exposes Chat Completions; without this the inference leg wouldn't match the backend.
- the OpenAI client's `api_key` is a **dummy** — the gateway supplies the real key from the Secret, so no `OPENAI_API_KEY` export is needed for the run.

```python
from openai import AsyncOpenAI
from agents import set_default_openai_client, set_default_openai_api, set_tracing_disabled

set_default_openai_client(AsyncOpenAI(base_url="http://localhost:8081/openai",
                                      api_key="routed-via-agentgateway"))
set_default_openai_api("chat_completions")
set_tracing_disabled(True)   # the trace exporter would otherwise call OpenAI directly
```

Re-run the agent and confirm **both** legs traverse the gateway:

```bash
python3 test-mslearn-agent.py
kubectl -n agentgateway-system logs deploy/agentgateway-proxy --tail=30 \
  | grep -E '/openai|/mcp-mslearn'
```

You should see both `http.path=/openai/chat/completions` and `http.path=/mcp-mslearn` with `http.status=200`.

---

## 7) Tool allow/deny rules (AgentgatewayPolicy)

By default, all MCP tools are allowed. To restrict tools, attach an `AgentgatewayPolicy` to the backend and add CEL expressions.

### 7.1 Example: allow only doc search on Microsoft Learn MCP

This restricts the Microsoft Learn backend to a single tool — `microsoft_docs_search`. Re-running the OpenAI Agents SDK test from Section 5 after applying the policy will show only that tool in `mcp_server.list_tools()`, and the agent will be unable to fetch full articles or code samples.

```bash
kubectl apply -f- <<'EOF'
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: mslearn-tools-allowlist
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: mslearn-mcp-backend
  backend:
    mcp:
      authorization:
        action: Allow
        policy:
          matchExpressions:
            - 'mcp.tool.name == "microsoft_docs_search"'
EOF
```

Re-run `python3 test-mslearn-agent.py` (or reconnect in MCP Inspector) — the tool list should now contain only `microsoft_docs_search`.

### 7.2 Policy-as-code (programmatic management)

All allow/deny rules are Kubernetes resources:
- store YAML in Git
- apply with GitOps (Argo CD / Flux) or CI
- generate/patch them programmatically using the Kubernetes API (any client library)

Useful commands:
```bash
# show current policies
kubectl get agentgatewaypolicies -A

# update from file(s)
kubectl apply -f ./policies/

# quick patch example (change the match expression)
kubectl patch agentgatewaypolicy mslearn-tools-allowlist -n agentgateway-system --type='json' \
  -p='[{"op":"replace","path":"/spec/backend/mcp/authorization/policy/matchExpressions/0","value":"mcp.tool.name == \\\"microsoft_docs_fetch\\\""}]'
```

---

## 8) Cleanup

```bash
# Option A cleanup (local website-fetcher MCP)
kubectl delete deployment mcp-website-fetcher
kubectl delete service mcp-website-fetcher
kubectl delete agentgatewaybackend mcp-backend
kubectl delete httproute mcp

# Option B cleanup (Microsoft Learn MCP — what setup.sh creates)
kubectl delete agentgatewaybackend mslearn-mcp-backend -n agentgateway-system
kubectl delete httproute mcp-mslearn -n agentgateway-system
kubectl delete agentgatewaypolicy mslearn-tools-allowlist -n agentgateway-system 2>/dev/null || true

# LLM route cleanup (Section 6)
kubectl delete -f 12-llm-openai.yaml 2>/dev/null || true
kubectl delete secret openai-secret -n agentgateway-system 2>/dev/null || true

# proxy cleanup
kubectl delete gateway agentgateway-proxy -n agentgateway-system

# uninstall agentgateway
helm uninstall agentgateway -n agentgateway-system
helm uninstall agentgateway-crds -n agentgateway-system
```

---

## Troubleshooting

### Gateway Not Getting IP

```bash
# Check the Service got a LoadBalancer IP
kubectl get svc -n agentgateway-system agentgateway-proxy

# If no EXTERNAL-IP, check your LoadBalancer:
#   LB_PROVIDER=metallb
kubectl get pods -n metallb-system
kubectl get ipaddresspools -n metallb-system
#   LB_PROVIDER=cilium
kubectl get ciliumloadbalancerippool
kubectl get ciliuml2announcementpolicy
```

### MCP Connection Issues

```bash
# Check agentgateway pods
kubectl get pods -n agentgateway-system
kubectl logs -n agentgateway-system -l app.kubernetes.io/name=agentgateway

# Check backend status
kubectl get agentgatewaybackends -A
kubectl describe agentgatewaybackend mcp-backend
```

### Policy Not Applied

```bash
# Check policy status
kubectl get agentgatewaypolicies -A
kubectl describe agentgatewaypolicy mslearn-tools-allowlist -n agentgateway-system
```

---

## References

- [Agentgateway Docs](https://agentgateway.dev/docs/kubernetes/main/)
- [Agentgateway Helm install](https://agentgateway.dev/docs/kubernetes/main/install/helm/)
- [Agentgateway MCP connectivity](https://agentgateway.dev/docs/kubernetes/main/mcp/)
- [Agentgateway GitHub](https://github.com/agentgateway/agentgateway)
- [Microsoft Learn MCP Server](https://learn.microsoft.com/en-us/training/support/mcp)
- [OpenAI Agents SDK – MCP](https://openai.github.io/openai-agents-python/mcp/)
- [Model Context Protocol](https://modelcontextprotocol.io/)
- [kgateway (umbrella project)](https://kgateway.dev/)

---

*Created on a Saturday morning with the help of Claude Cowork and the relentless effort of Philippe Bogaerts for guiding, testing, and troubleshooting. Because nothing says "weekend fun" like debugging x509 certificate errors.* 🎉
