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
import json
import logging
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

from openai import AsyncOpenAI
from agents import (
    Agent,
    Runner,
    set_default_openai_api,
    set_default_openai_client,
    set_tracing_disabled,
)
from agents.mcp import MCPServerStreamableHttp


class JSONLLogger:
    """Logger that writes JSONL (JSON Lines) format logs for runtime troubleshooting."""
    
    def __init__(self, log_path: str = "/home/runner/work/_temp/runtime-logs/fw.jsonl"):
        self.log_path = Path(log_path)
        self.log_path.parent.mkdir(parents=True, exist_ok=True)
        # Keep file handle open for better performance with frequent logging
        self.log_file = None
        self._open_log_file()
        
    def _open_log_file(self) -> None:
        """Open the log file in append mode."""
        try:
            self.log_file = open(self.log_path, "a")
        except Exception as e:
            print(f"Warning: Failed to open log file: {e}", file=sys.stderr)
            self.log_file = None
    
    def close(self) -> None:
        """Close the log file explicitly."""
        if self.log_file is not None:
            try:
                self.log_file.close()
            except Exception:
                pass  # Silently ignore errors during cleanup
            self.log_file = None
    
    def __enter__(self):
        """Context manager entry."""
        return self
    
    def __exit__(self, exc_type, exc_val, exc_tb):
        """Context manager exit - closes the log file."""
        self.close()
        return False
    
    def __del__(self) -> None:
        """Clean up: close the log file."""
        self.close()
        
    def log(self, level: str, message: str, **fields) -> None:
        """Log an entry in JSONL format."""
        entry = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "level": level,
            "message": message,
            **fields
        }
        try:
            if self.log_file is None:
                self._open_log_file()
            if self.log_file is not None:
                self.log_file.write(json.dumps(entry) + "\n")
                self.log_file.flush()  # Ensure data is written immediately
        except Exception as e:
            print(f"Warning: Failed to write log entry: {e}", file=sys.stderr)
    
    def info(self, message: str, **fields) -> None:
        """Log an info entry."""
        self.log("INFO", message, **fields)
    
    def error(self, message: str, **fields) -> None:
        """Log an error entry."""
        self.log("ERROR", message, **fields)
    
    def debug(self, message: str, **fields) -> None:
        """Log a debug entry."""
        self.log("DEBUG", message, **fields)


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
MODEL = os.environ.get("OPENAI_MODEL", "gpt-4o-mini")


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
    # Initialize the JSONLLogger for runtime troubleshooting
    runtime_logger = JSONLLogger()
    runtime_logger.info("Test script started", script="test-mslearn-agent.py")
    
    print(
        f"Routing LLM inference via {LLM_URL} and MCP via {MCP_URL}",
        file=sys.stderr,
    )
    
    runtime_logger.info(
        "Configuring gateway routes",
        llm_url=LLM_URL,
        mcp_url=MCP_URL,
        model=MODEL
    )

    try:
        async with MCPServerStreamableHttp(
            name="Microsoft Learn Docs",
            params={
                "url": MCP_URL,
                "timeout": 30,
            },
            cache_tools_list=True,
        ) as mcp_server:
            runtime_logger.info("MCP server connection established", mcp_url=MCP_URL)
            
            # List the tools the gateway exposes so we see what the agent has access to.
            tools = await mcp_server.list_tools()
            tool_names = [t.name for t in tools]
            print(
                "Tools exposed by Microsoft Learn MCP (via agentgateway): "
                + ", ".join(tool_names),
                file=sys.stderr,
            )
            runtime_logger.info(
                "MCP tools listed",
                tool_count=len(tool_names),
                tools=tool_names
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
            runtime_logger.info("Agent created", agent_name="Microsoft docs assistant")

            prompt = (
                "What is Azure App Service, what programming languages does it "
                "support, and what is the difference between an App Service Plan "
                "and an App Service? Search the Microsoft Learn docs and cite "
                "the URLs you used."
            )
            runtime_logger.info("Starting agent execution", prompt_length=len(prompt))

            result = await Runner.run(agent, prompt)
            print()
            print("=" * 80)
            print("Agent final answer:")
            print("=" * 80)
            print(result.final_output)
            
            runtime_logger.info(
                "Agent execution completed successfully",
                output_length=len(result.final_output)
            )

        return 0
    
    except Exception as e:
        runtime_logger.error(
            "Agent execution failed",
            error_type=type(e).__name__,
            error_message=str(e)
        )
        print(f"Error: {e}", file=sys.stderr)
        print("\nFor troubleshooting, view the runtime logs:", file=sys.stderr)
        print("  python3 show-runtime-logs.py", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
