# aws-example FAQ (sample document for the S3 Vectors store)

## What is the aws-example guardrail?
aws-example is an Amazon Bedrock guardrail attached to LiteLLM. It blocks hate,
insults, sexual content, violence, misconduct and prompt attacks, refuses
personalised investment advice, anonymises e-mail addresses and phone numbers,
and blocks credit card numbers, US social security numbers and AWS secret keys.
A request opts in with "guardrails": ["aws-example"].

## Which agent runs on Amazon Bedrock AgentCore?
The aws-example agent is a Strands agent hosted on Amazon Bedrock AgentCore
Runtime (runtime name aws_example). It uses Claude Haiku 5.5 and has two tools:
utc_now returns the current UTC time and aws_doc_url returns the documentation
link of an AWS service. LiteLLM exposes it at /a2a/aws-example.

## How does web search work?
Web Search on Amazon Bedrock is a managed connector of Amazon Bedrock AgentCore
Gateway. The gateway aws-example-websearch has one target, web-search-tool, and
LiteLLM serves it as POST /v1/search/aws-example.

## Where are the vectors stored?
In Amazon S3 Vectors: one vector bucket and one index named aws-example with
1536 dimensions and cosine distance, filled with Cohere Embed v4 embeddings
through LiteLLM's /v1/rag/ingest. The chunk text is kept in the non-filterable
metadata key source_text.

## What does it cost to keep aws-example running?
The guardrail, the gateway and the vector index cost nothing while idle; the
AgentCore runtime bills only for active sessions. Run cleanup.sh to remove all
of them.
