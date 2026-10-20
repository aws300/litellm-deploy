"""
BedrockTeamTagHook — async_pre_call_hook for LiteLLM proxy

每次调用 bedrock/ 前，从 user_api_key_dict 读取 team_alias，
通过 STS AssumeRole 注入 Session Tag team=<team_alias>，
使 AWS CUR 2.0 中 iamPrincipal/team 维度可在 Cost Explorer 按 Team 筛选。

依赖（均为镜像内置）：boto3、botocore、标准库 time/threading/re

IAM 前提：
  - nxdev-PodRole 有 sts:AssumeRole + sts:TagSession → nxdev-litellm-bedrock-exec
  - nxdev-litellm-bedrock-exec 信任策略允许 nxdev-PodRole TagSession
  - AWS Billing: iamPrincipal/team Cost Allocation Tag 已激活
  - CUR 2.0 Export 已勾选 "Include caller identity (IAM principal) allocation data"
"""

import re
import time
import threading
import boto3
from litellm.integrations.custom_logger import CustomLogger

BEDROCK_EXEC_ROLE_ARN = "arn:aws:iam::867344450900:role/nxdev-litellm-bedrock-exec"
_CRED_TTL_SECONDS = 3300   # 55 分钟（STS token 1 小时，提前刷新）

# Tag Value 合法字符集（AWS 规范 UTF-8 字母数字 + 特定符号）
_VALID_TAG_RE = re.compile(r"[^A-Za-z0-9 _.:/=+\-@]")

# 纯标准库实现的线程安全 TTL Cache（不依赖 cachetools）
_cache_lock = threading.Lock()
_cred_store: dict = {}   # {key: {"creds": {...}, "expires_at": float}}


def _cache_get(key: str):
    with _cache_lock:
        entry = _cred_store.get(key)
        if entry and time.monotonic() < entry["expires_at"]:
            return entry["creds"]
        if entry:
            del _cred_store[key]
        return None


def _cache_set(key: str, creds: dict) -> None:
    with _cache_lock:
        _cred_store[key] = {
            "creds": creds,
            "expires_at": time.monotonic() + _CRED_TTL_SECONDS,
        }


def _sanitize_tag(value: str) -> str:
    """清洗 Tag Value：替换非法字符为 _, 截断至 256 字符。"""
    return _VALID_TAG_RE.sub("_", value)[:256]


class BedrockTeamTagHook(CustomLogger):
    """
    在每次 bedrock/ 调用前注入带 team Session Tag 的临时凭证。
    无 team 的请求直接透传，使用 Pod 默认 Pod Identity 凭证。
    """

    async def async_pre_call_hook(
        self, user_api_key_dict, cache, data, call_type
    ):
        tag_value = None
        try:
            # 注意：本 proxy 只服务 Bedrock 模型。在 async_pre_call_hook 阶段
            # data["model"] 还是客户端别名（如 claude-sonnet-4-6 / auto /
            # qwen3-coder-480b），并非解析后的 bedrock/ 名称，所以**不能**用
            # "bedrock/" 前缀做门禁——否则所有正常别名流量都会被直接放行、
            # 永远不打 Session Tag（只有极少数裸 bedrock/* 透传调用才会命中）。

            # team 标签（按 LiteLLM Team 计费），无 team 时回退 team_id
            team_alias = (
                getattr(user_api_key_dict, "team_alias", None)
                or getattr(user_api_key_dict, "team_id", None)
            )
            # key 标签（按 API Key 计费），优先可读的 key_alias，回退 hash token
            key_id = (
                getattr(user_api_key_dict, "key_alias", None)
                or getattr(user_api_key_dict, "token", None)
            )
            if not team_alias and not key_id:
                # 无归属信息（如 master key）— 透传走 Pod 默认凭证
                return data

            session_tags = []
            if team_alias:
                session_tags.append(
                    {"Key": "team", "Value": _sanitize_tag(str(team_alias))}
                )
            if key_id:
                session_tags.append(
                    {"Key": "key", "Value": _sanitize_tag(str(key_id))}
                )

            tag_value = "_".join(t["Value"] for t in session_tags)
            cache_key = f"bedrock_creds_{tag_value}"
            creds = _cache_get(cache_key)

            if creds is None:
                # RoleSessionName 出现在 CUR principal ARN：仅允许 [\w+=,.@-]
                session_name = re.sub(
                    r"[^\w=,.@-]", "-", f"litellm-{tag_value}"
                )[:64]
                sts = boto3.client("sts", region_name="us-west-2")
                resp = sts.assume_role(
                    RoleArn=BEDROCK_EXEC_ROLE_ARN,
                    RoleSessionName=session_name,
                    DurationSeconds=3600,
                    Tags=session_tags,
                )
                creds = resp["Credentials"]
                _cache_set(cache_key, creds)

            # 绕过 Issue #25884（aws_role_name 在 YAML 中被静默丢弃）
            # 直接注入临时凭证
            data["aws_access_key_id"] = creds["AccessKeyId"]
            data["aws_secret_access_key"] = creds["SecretAccessKey"]
            data["aws_session_token"] = creds["SessionToken"]

        except Exception as exc:
            import logging
            logging.getLogger("litellm").warning(
                "BedrockTeamTagHook: STS AssumeRole failed for tag=%s: %s",
                tag_value or "unknown",
                exc,
            )

        return data


proxy_handler_instance = BedrockTeamTagHook()
