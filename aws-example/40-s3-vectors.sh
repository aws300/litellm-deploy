#!/usr/bin/env bash
# 40-s3-vectors.sh — Amazon S3 Vectors as a LiteLLM vector store (`aws-example`).
#
# Why: S3 Vectors stores and queries embeddings in S3 at S3 prices, with no
# cluster to run; LiteLLM's s3_vectors provider queries it for
# /v1/vector_stores/<id>/search (OpenAI shape) and for chat completions that
# pass "vector_store_ids", and its /v1/rag/ingest pipeline chunks, embeds and
# writes documents into it — all SigV4-signed with the Pod role (00-iam.sh).
# This script:
#   1. creates the vector bucket litellm-aws-example-<account>-<region> and the index
#      aws-example: 1536 dimensions (Cohere Embed v4's default output), cosine,
#      metadata key source_text non-filterable (LiteLLM keeps the chunk text in it);
#   2. registers the vector store `aws-example` in LiteLLM (POST /vector_store/new,
#      DB-stored), id "<bucket>:<index>", query embeddings by model cohere.embed-v4;
#   3. ingests sample/*.md through LiteLLM (/v1/rag/ingest, 800-char chunks),
#      so the store is searchable right away.
# Idempotent: bucket / index / store are reused. LiteLLM gives every ingested
# chunk a new key, so ingesting a file twice stores it twice: without
# arguments the sample is ingested only into an empty index; files given as
# arguments are always added.
#
# Usage: LITELLM_ADMIN_KEY=sk-... ./40-s3-vectors.sh [file ...]   (default: sample/*.md)
source "$(dirname "$0")/lib.sh"

# S3 Vectors reserves bucket names starting with "aws" (ValidationException
# "The requested bucket name is reserved"), hence the litellm- prefix.
BUCKET=litellm-$NAME-$ACCOUNT-$REGION
INDEX=$NAME
DIM=1536
EMBED=cohere.embed-v4
STORE_ID=$BUCKET:$INDEX

say "1. S3 Vectors bucket $BUCKET / index $INDEX"
if aws s3vectors get-vector-bucket --region "$REGION" --vector-bucket-name "$BUCKET" >/dev/null 2>&1; then
  ok "bucket exists"
else
  aws s3vectors create-vector-bucket --region "$REGION" --vector-bucket-name "$BUCKET" >/dev/null; ok "bucket created"
fi
if aws s3vectors get-index --region "$REGION" --vector-bucket-name "$BUCKET" --index-name "$INDEX" >/dev/null 2>&1; then
  ok "index exists"
else
  aws s3vectors create-index --region "$REGION" --vector-bucket-name "$BUCKET" --index-name "$INDEX" \
    --data-type float32 --dimension "$DIM" --distance-metric cosine \
    --metadata-configuration '{"nonFilterableMetadataKeys":["source_text"]}' >/dev/null
  ok "index created ($DIM dims, cosine)"
fi

say "2. LiteLLM vector store $NAME"
params=$(jq -n --arg b "$BUCKET" --arg i "$INDEX" --arg r "$REGION" --arg e "$EMBED" \
  '{vector_bucket_name: $b, index_name: $i, aws_region_name: $r, litellm_embedding_model: $e}')
if litellm GET "/vector_store/list" | jq -e --arg id "$STORE_ID" '.data[] | select(.vector_store_id==$id)' >/dev/null; then
  litellm POST /vector_store/update "$(jq -n --arg id "$STORE_ID" --argjson p "$params" \
    '{vector_store_id: $id, litellm_params: $p}')" >/dev/null
  ok "updated $STORE_ID"
else
  litellm POST /vector_store/new "$(jq -n --arg id "$STORE_ID" --arg n "$NAME" --argjson p "$params" '{
    vector_store_id: $id, custom_llm_provider: "s3_vectors", vector_store_name: $n,
    vector_store_description: "Amazon S3 Vectors index aws-example (Cohere Embed v4, 1536 dims)",
    litellm_params: $p}')" >/dev/null
  ok "created $STORE_ID"
fi

say "3. ingest"
files=("$@")
if [[ ${#files[@]} -eq 0 ]]; then
  count=$(aws s3vectors list-vectors --region "$REGION" --vector-bucket-name "$BUCKET" --index-name "$INDEX" \
    --max-results 1 --query 'length(vectors)' --output text)
  if [[ $count != 0 ]]; then ok "index already holds vectors: sample not re-ingested (pass files to add more)"; files=()
  else files=("$HERE"/sample/*.md); fi
fi
opts=$(jq -n --arg b "$BUCKET" --arg i "$INDEX" --arg r "$REGION" --arg e "$EMBED" --argjson d "$DIM" '{
  vector_store: {custom_llm_provider: "s3_vectors", vector_store_id: "\($b):\($i)", vector_bucket_name: $b,
                 index_name: $i, aws_region_name: $r, dimension: $d, litellm_embedding_model: $e},
  embedding: {model: $e},
  chunking_strategy: {chunk_size: 800, chunk_overlap: 100}}')
for f in "${files[@]+"${files[@]}"}"; do
  code=$(curl -sS -m 300 -o /tmp/aws-example.body -w '%{http_code}' -X POST "$GA/v1/rag/ingest" \
    -H "Authorization: Bearer $LITELLM_ADMIN_KEY" -F "file=@$f;type=text/markdown" --form-string "request=$(jq -c '{ingest_options: .}' <<<"$opts")")
  # Multipart: the file + field `request` holding the JSON body ({"ingest_options": ...});
  # --form-string because -F would parse the ; and quotes inside the JSON.
  [[ $code == 2* ]] || die "ingest $f -> $code: $(head -c 500 /tmp/aws-example.body)"
  ok "$(basename "$f"): $(jq -c '{status, vector_store_id, chunks: (.chunks // .chunk_count // .file_count // null)}' /tmp/aws-example.body)"
done
echo "Search it: POST $GA/v1/vector_stores/$STORE_ID/search {\"query\": \"...\"}"
