"""
OpenAI Agents SDK + Microsoft Learn MCP via Agentgateway
========================================================

This script validates that BOTH legs of the agent run through agentgateway:

    OpenAI Agents SDK (Agent + Runner)
        |                      |
        | LLM inference        | MCP tool calls
        v                      v
    http://localhost:8081/openai      http://localhost:8081/mcp-mslearn
        |                      |
        +----------+-----------+
                   v
        agentgateway proxy (agentgateway-system)
           |                         |
           v                         v
   api.openai.com/v1/chat/...   learn.microsoft.com/api/mcp
   (12-llm-openai.yaml)         (11-mcp-mslearn.yaml)

Prerequisites
-------------
1. The lab cluster is up with setup.sh INSTALL_AGENTGATEWAY=true (the default).
2. The OpenAI API key Secret exists (the gateway injects it, see 12-llm-openai.yaml):

       kubectl create secret generic openai-secret -n agentgateway-system \
           --from-literal=Authorization="Bearer $OPENAI_API_KEY"

3. A port-forward to agentgateway is running in another terminal (port 8081 by
   convention, so it never collides with the Envoy webapp forward on 8080):

       kubectl -n agentgateway-system port-forward \
           deployment/agentgateway-proxy 8081:80

4. openai-agents is installed:

       pip install --upgrade openai-agents

Usage
-----
    python3 test-mslearn-agent.py

This runs a single agent turn asking about Azure App Service. The agent
will call Microsoft Learn MCP tools (e.g. docs search / fetch) via
agentgateway and incorporate the results into its answer.
"""

from __future__ import annotations

import asyncio
import logging
import os
import sys

from openai import AsyncOpenAI
from agents import (
    Agent,
    Runner,
    set_default_openai_api,
    set_default_openai_client,
    set_tracing_disabled,
)
from agents.mcp import MCPServerStreamableHttp


# The agentgateway proxy replies to the session-ending DELETE with HTTP 202
# (Accepted) — a valid success. The MCP streamable-HTTP client, however, only
# treats 200/204 as success and logs "Session termination failed: 202" as a
# warning. The session does terminate correctly, so this is a false alarm;
# silence that one logger to avoid the misleading message on clean shutdown.
logging.getLogger("mcp.client.streamable_http").setLevel(logging.ERROR)


# Base URL of the agentgateway proxy listener. BOTH legs of this agent — the
# MCP tool calls AND the LLM inference calls — go through this one gateway:
#   <base>/mcp-mslearn  -> Microsoft Learn MCP   (11-mcp-mslearn.yaml)
#   <base>/openai       -> OpenAI chat completions (12-llm-openai.yaml)
#
# Port convention for this lab (avoids the two gateways fighting over a port):
#   localhost:8080 / 8443 -> Envoy Gateway   (webapp HTTP/TLS routes)
#   localhost:8081        -> agentgateway    (MCP + LLM, this script)
# Start the agentgateway forward with:
#   kubectl -n agentgateway-system port-forward deployment/agentgateway-proxy 8081:80
GATEWAY_BASE = os.environ.get("AGENTGATEWAY_URL", "http://localhost:8081").rstrip("/")
MCP_URL = f"{GATEWAY_BASE}/mcp-mslearn"
LLM_URL = f"{GATEWAY_BASE}/openai"

# The model used by the Agent. Override with OPENAI_MODEL if you want a
# cheaper/faster or a stronger model.
MODEL = os.environ.get("OPENAI_MODEL", "gpt-4.5-mini")


# Route the OpenAI Agents SDK's inference calls through agentgateway instead of
# straight to api.openai.com.
#
# - base_url points the OpenAI client at the gateway's /openai route. The SDK
#   posts to "<base_url>/chat/completions", i.e. /openai/chat/completions.
# - api_key is intentionally a DUMMY: the gateway injects the real key from the
#   "openai-secret" Secret and overrides whatever the client sends, so the agent
#   never holds the provider credential. (Set a real OPENAI_API_KEY only if you
#   remove the gateway's auth policy.)
# - set_default_openai_api("chat_completions"): the SDK defaults to the Responses
#   API, but agentgateway's OpenAI backend exposes Chat Completions — without
#   this the requests would not match the backend.
# - tracing is disabled because the SDK's trace exporter would otherwise call
#   api.openai.com directly with the dummy key.
set_default_openai_client(
    AsyncOpenAI(
        base_url=LLM_URL,
        api_key=os.environ.get("OPENAI_API_KEY", "routed-via-agentgateway"),
    )
)
set_default_openai_api("chat_completions")
set_tracing_disabled(True)


async def main() -> int:
    print(
        f"Routing LLM inference via {LLM_URL} and MCP via {MCP_URL}",
        file=sys.stderr,
    )

    async with MCPServerStreamableHttp(
        name="Microsoft Learn Docs",
        params={
            "url": MCP_URL,
            "timeout": 30,
        },
        cache_tools_list=True,
    ) as mcp_server:
        # List the tools the gateway exposes so we see what the agent has access to.
        tools = await mcp_server.list_tools()
        print(
            "Tools exposed by Microsoft Learn MCP (via agentgateway): "
            + ", ".join(t.name for t in tools),
            file=sys.stderr,
        )

        agent = Agent(
            name="Microsoft docs assistant",
            instructions=(
                "You are an assistant that answers questions about Microsoft "
                "technologies. Always use the Microsoft Learn MCP tools to "
                "search the official documentation before answering. When you "
                "use information from a doc, cite its URL."
            ),
            model=MODEL,
            mcp_servers=[mcp_server],
        )

        prompt = (
            "What is Azure App Service, what programming languages does it "
            "support, and what is the difference between an App Service Plan "
            "and an App Service? Search the Microsoft Learn docs and cite "
            "the URLs you used."
        )

        result = await Runner.run(agent, prompt)
        print()
        print("=" * 80)
        print("Agent final answer:")
        print("=" * 80)
        print(result.final_output)

    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
