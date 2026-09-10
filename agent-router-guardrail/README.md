# Guardrail on Agent Router (formerly Envoy AI Gateway) — WORKING PoC

Agent Router has **no native content guardrail** (checked the v1.1 capabilities:
LLM integrations, inference optimization, gateway config, traffic mgmt, security
= upstream auth only, MCP, observability). But because it's **real Envoy +
Envoy Gateway**, you can add one with `EnvoyExtensionPolicy` + `ext_proc`.

## The point

This is the guardrail we built for agentgateway — but there, **agentgateway
v1.2.1 ext_proc could not block or mutate the body** (`ImmediateResponse` /
`mode_override` were ignored), so we fell back to its native promptGuard webhook.
On Agent Router the **same ext_proc idea works end-to-end**, because genuine
Envoy honors buffered request bodies and `ImmediateResponse(403)`.

## What it does

`main.go` implements `envoy.service.ext_proc.v3.ExternalProcessor`. It buffers
the request body and, for the LLM leg (`/v1/chat/completions`), blocks prompts
containing `execute` (HTTP 403) and allows the rest.

## Deploy

```bash
docker build -t agent-router-guardrail:poc ./agent-router-guardrail
# docker-desktop k8s can't pull a local docker tag (separate containerd ns);
# push to a local registry (5001 because macOS AirPlay owns 5000):
docker run -d -p 5001:5000 --name local-registry registry:2
docker tag agent-router-guardrail:poc localhost:5001/agent-router-guardrail:poc
docker push localhost:5001/agent-router-guardrail:poc

kubectl apply -f agent-router-guardrail/deploy.yaml
```

`deploy.yaml` = Deployment + Service (gRPC/h2c :18080) + an `EnvoyExtensionPolicy`
that attaches the ext_proc to the AIGatewayRoute's generated HTTPRoute
(`envoy-ai-gateway-basic`, the mock `testupstream` route) with
`processingMode.request.body: Buffered`.

## Verified on the live docker-desktop cluster

Against the mock `testupstream` (model `some-cool-self-hosted-model`, no real key):

```
"execute a production deployment now"      -> HTTP 403
    Blocked by intent guardrail (LLM): matched blocked keyword "execute"
"teach me something about kubernetes"      -> HTTP 200  (mock completion)
```

ext_proc log:

```
→ request headers, path=/v1/chat/completions
→ request body chunk len=116 eos=true total=116
⛔ BLOCK  leg=LLM path=/v1/chat/completions — matched blocked keyword "execute" [model=some-cool-self-hosted-model last_msg="execute a production deployment now"]
✅ ALLOW  leg=LLM path=/v1/chat/completions — no blocked keyword [model=... last_msg="teach me something about kubernetes"]
```

## Response masking — attempted, hits a dual-ext_proc limitation

`main.go` also implements response-body masking (redact emails + "secret"), and
enabling `processingMode.response.body: Buffered` in the policy *should* mask the
completion. On this deployment it does **not** work: buffering the response in
our ext_proc collides with **Agent Router's own ext_proc**, which must process
the response for token metering / OpenAI-schema translation. The result is
**HTTP 500** on every response (both the mock and the real OpenAI route), and
our response handler never even runs.

So response masking is left **dormant**: the code stays in `main.go`, but the
`response:` block is commented out in `deploy.yaml`. Request-side blocking is
unaffected and works on both routes.

Verified with response buffering ON (the failure):

```
teach me   (mock)   -> HTTP 500, empty body
say hi     (openai) -> HTTP 500, empty body     # no MASK/PASS log = our handler not reached
```

Verified after reverting to request-only (healthy):

```
teach me (mock)   -> 200      say hi (openai) -> 200      execute -> 403
```

This is itself a useful finding for the agentgateway-vs-Agent-Router comparison:
**agentgateway's native promptGuard does response masking cleanly in-proxy**;
on Agent Router, a bring-your-own response ext_proc clashes with the AI
gateway's own response processor. Likely paths forward (untested): run the
masking ext_proc on a plain (non-AIGatewayRoute) HTTPRoute, or use a single
ext_proc that also assumes the metering role — i.e. cooperate with, not stack
on top of, the AI gateway processor.

## Logging the actual prompt content

The metadata access log (`access-log.yaml`) can't include bodies. But the
guardrail ext_proc already buffers the request body, so it emits one structured
`PROMPT` JSON line per call — the **full** prompt (all messages), model, and the
allow/block decision — tagged with the Envoy `x-request-id` so it **correlates
with the access-log line**.

The PROMPT line is emitted as a pure JSON line (no log-timestamp prefix), so it
pipes straight into jq:

```
kubectl -n default logs deploy/agent-router-guardrail | grep '"type":"prompt"' | jq .
```

Verified (block case), joined by request_id:

```
access log : {"request_id":"1b5a4f74…","model":"gpt-4o-mini","status":403,"upstream":null}
prompt log : {"request_id":"1b5a4f74…","decision":"block","model":"gpt-4o-mini",
              "messages":[{"role":"user","content":"execute a deploy"}]}
```

So: access log = who/when/status/latency/model (every call); prompt log =
what was actually asked. Join on `request_id`.

Response/completion content is still not logged here (same dual-ext_proc
collision as masking). For that, use Envoy's `tap` filter or the AI gateway's
own processor.

## Notes

- Agent Router normalizes to the OpenAI schema, so the guardrail parses one body
  shape regardless of provider — and request-side blocking works identically on
  the mock route and the real OpenAI route.
- vs agentgateway: agentgateway gives a first-class promptGuard webhook (request
  block **and** response mask, in-proxy, less code); Agent Router gives no
  built-in guardrail but a capable standard Envoy ext_proc that blocks requests
  cleanly — while response mutation collides with its own processor (above).

## Cleanup

```bash
kubectl delete -f agent-router-guardrail/deploy.yaml
```
