"""aws-example agent: a Strands agent on Amazon Bedrock AgentCore Runtime.

LiteLLM reaches it two ways, with two payload shapes (LiteLLM v1.106.6):
  - /a2a/aws-example (Agents page, A2A clients): LiteLLM's bedrock_agentcore A2A
    provider forwards the A2A JSON-RPC envelope unchanged —
    {"jsonrpc": "2.0", "id": ..., "method": "message/send" | "message/stream",
     "params": {"message": {"parts": [{"kind": "text", "text": ...}]}}} —
    and expects a JSON-RPC response (an SSE stream of them for message/stream);
  - model bedrock/agentcore/<runtime ARN> on /v1/chat/completions: LiteLLM sends
    {"prompt": "<last user message>"} and reads {"result": "<text>"}.
Both are answered here, so the same runtime serves either route.

The model is Claude Haiku 5.5 through Bedrock (global cross-region profile),
called with the runtime's execution role; two small tools (utc_now,
aws_doc_url) make a reply show real tool use.
"""

import datetime
import os
import uuid

from bedrock_agentcore.runtime import BedrockAgentCoreApp
from strands import Agent, tool
from strands.models import BedrockModel

MODEL_ID = os.environ.get("MODEL_ID", "global.anthropic.claude-haiku-5-5")
SYSTEM_PROMPT = (
    "You are aws-example, a concise assistant for AWS questions. "
    "Use the tools when the user asks for the time or for documentation links."
)


@tool
def utc_now() -> str:
    """Return the current date and time in UTC (ISO 8601)."""
    return datetime.datetime.now(datetime.UTC).isoformat(timespec="seconds")


@tool
def aws_doc_url(service: str) -> str:
    """Return the AWS documentation URL of an AWS service, e.g. "bedrock" or "s3vectors"."""
    return f"https://docs.aws.amazon.com/{service.strip().lower()}/"


def answer(prompt: str) -> str:
    # A fresh Agent per request: the runtime serves concurrent sessions, and a
    # shared Agent would mix their conversation histories.
    agent = Agent(
        model=BedrockModel(model_id=MODEL_ID, region_name=os.environ.get("AWS_REGION", "us-east-1")),
        tools=[utc_now, aws_doc_url],
        system_prompt=SYSTEM_PROMPT,
        callback_handler=None,
    )
    return str(agent(prompt)).strip()


def a2a_text(params: dict) -> str:
    parts = ((params or {}).get("message") or {}).get("parts") or []
    return "\n".join(str(p.get("text")) for p in parts if isinstance(p, dict) and p.get("text"))


def a2a_message(rpc_id, text: str, context_id: str | None) -> dict:
    message = {"kind": "message", "role": "agent", "messageId": uuid.uuid4().hex,
               "parts": [{"kind": "text", "text": text}]}
    if context_id:
        message["contextId"] = context_id
    return {"jsonrpc": "2.0", "id": rpc_id, "result": message}


app = BedrockAgentCoreApp()


@app.entrypoint
def invoke(payload: dict):
    if payload.get("jsonrpc") == "2.0":
        rpc_id = payload.get("id")
        params = payload.get("params") or {}
        prompt = a2a_text(params)
        if not prompt:
            return {"jsonrpc": "2.0", "id": rpc_id, "error": {"code": -32602, "message": "no text part in params.message"}}
        reply = a2a_message(rpc_id, answer(prompt), ((params.get("message") or {}).get("contextId")))
        if payload.get("method") == "message/stream":
            # One SSE event carrying the final message (the app streams a generator as SSE).
            return (event for event in [reply])
        return reply
    return {"result": answer(str(payload.get("prompt", "")))}


if __name__ == "__main__":
    app.run()
