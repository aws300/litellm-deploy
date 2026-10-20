#!/usr/bin/env python3
"""
litellm-team-spend.py — LiteLLM × Bedrock 团队费用查询工具

用法:
    python3 litellm-team-spend.py [--days N] [--team TEAM_ALIAS] [--json]

功能:
    1. 查看所有 Team 的累计费用（LiteLLM Spend Tracking）
    2. 查看指定 Team 的详细日志
    3. 从 AWS Cost Explorer 查看 iamPrincipal/team 维度费用
    4. 输出对比报告

依赖: requests (或 urllib), boto3
"""
import argparse
import json
import os
import subprocess
import sys
import urllib.request
import urllib.error
from datetime import date, timedelta


# ── 配置 ──────────────────────────────────────────────────────────
LITELLM_BASE_URL = os.environ.get("LITELLM_BASE_URL", "http://localhost:4000")
LITELLM_API_KEY  = os.environ.get("LITELLM_API_KEY", "sk-litellm-proxy-master-key")
AWS_REGION       = os.environ.get("AWS_REGION", "us-west-2")
# ─────────────────────────────────────────────────────────────────


def api(path: str, method: str = "GET", data: dict = None) -> dict:
    url = f"{LITELLM_BASE_URL}{path}"
    body = json.dumps(data).encode() if data else None
    req = urllib.request.Request(
        url, data=body,
        headers={
            "Authorization": f"Bearer {LITELLM_API_KEY}",
            "Content-Type": "application/json",
        },
        method=method,
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        return {"error": f"HTTP {e.code}: {e.read().decode()[:200]}"}
    except Exception as e:
        return {"error": str(e)}


def get_all_teams() -> list:
    resp = api("/team/list")
    if "error" in resp:
        return []
    return resp if isinstance(resp, list) else resp.get("data", [])


def get_team_spend_summary() -> list:
    resp = api("/spend/teams")
    if "error" in resp:
        return []
    return resp if isinstance(resp, list) else resp.get("data", [])


def get_team_logs(team_id: str, limit: int = 50) -> list:
    resp = api(f"/spend/logs?team_id={team_id}&limit={limit}")
    if "error" in resp:
        return []
    return resp if isinstance(resp, list) else resp.get("data", [])


def get_aws_bedrock_cost_by_team(days: int = 7) -> dict:
    """从 AWS Cost Explorer 查询 Bedrock 费用，按 iamPrincipal/team 分组。"""
    try:
        import boto3
        ce = boto3.client("ce", region_name="us-east-1")
        end = date.today()
        start = end - timedelta(days=days)
        resp = ce.get_cost_and_usage(
            TimePeriod={"Start": str(start), "End": str(end)},
            Granularity="MONTHLY",
            Filter={"Dimensions": {"Key": "SERVICE", "Values": ["Amazon Bedrock"]}},
            GroupBy=[{"Type": "TAG", "Key": "iamPrincipal/team"}],
            Metrics=["UnblendedCost"],
        )
        result = {}
        for day in resp.get("ResultsByTime", []):
            for group in day.get("Groups", []):
                tag_val = (group.get("Keys", [""])[0] or "")
                # 去掉 AWS 自动加的前缀
                team = tag_val.replace("iamPrincipal/team$", "").strip() or "untagged"
                cost = float(group.get("Metrics", {}).get("UnblendedCost", {}).get("Amount", 0))
                result[team] = result.get(team, 0.0) + cost
        return result
    except ImportError:
        return {"error": "boto3 not installed"}
    except Exception as e:
        return {"error": str(e)}


def print_team_summary(teams_spend: list, aws_costs: dict, as_json: bool = False):
    if as_json:
        print(json.dumps({
            "litellm_spend": teams_spend,
            "aws_bedrock_cost_by_team": aws_costs,
        }, indent=2, default=str))
        return

    print("\n┌─────────────────────────────────────────────────────────────────────────┐")
    print("│            LiteLLM Team Spend Summary (Internal Tracking)              │")
    print("└─────────────────────────────────────────────────────────────────────────┘")
    if not teams_spend:
        print("  无数据（可能 LiteLLM 连接失败或无 Team 费用记录）")
    else:
        teams_sorted = sorted(teams_spend, key=lambda t: t.get("spend", 0), reverse=True)
        print(f"  {'Team Alias':<30}  {'Budget':>10}  {'Spend (USD)':>12}  {'Used%':>6}")
        print(f"  {'─'*30}  {'─'*10}  {'─'*12}  {'─'*6}")
        total = 0
        for t in teams_sorted:
            alias  = (t.get("team_alias") or t.get("team_id", "N/A"))[:30]
            budget = t.get("max_budget") or 0
            spend  = t.get("spend", 0)
            pct    = (spend / budget * 100) if budget > 0 else 0
            total += spend
            pct_str = f"{pct:.1f}%" if budget > 0 else "N/A"
            budget_str = f"${budget:.2f}" if budget > 0 else "no limit"
            print(f"  {alias:<30}  {budget_str:>10}  ${spend:>11.4f}  {pct_str:>6}")
        print(f"  {'─'*62}")
        print(f"  {'TOTAL':<30}  {'':>10}  ${total:>11.4f}")

    print("\n┌─────────────────────────────────────────────────────────────────────────┐")
    print("│     AWS Cost Explorer — iamPrincipal/team (24-48h delay)               │")
    print("└─────────────────────────────────────────────────────────────────────────┘")
    if "error" in aws_costs:
        print(f"  ⚠️  AWS Cost Explorer 查询失败: {aws_costs['error']}")
        print("  → 检查 AWS 权限，或 iamPrincipal/team Tag 是否已在 Billing Console 激活")
    elif not aws_costs:
        print("  无数据（Tag 尚未激活，或无 Bedrock 使用记录）")
    else:
        sorted_costs = sorted(aws_costs.items(), key=lambda x: x[1], reverse=True)
        print(f"  {'iamPrincipal/team':<40}  {'Bedrock Cost (USD)':>18}")
        print(f"  {'─'*40}  {'─'*18}")
        total = 0
        for team, cost in sorted_costs:
            print(f"  {team:<40}  ${cost:>17.4f}")
            total += cost
        print(f"  {'─'*60}")
        print(f"  {'TOTAL':<40}  ${total:>17.4f}")


def print_team_logs(team_alias: str, logs: list, as_json: bool = False):
    if as_json:
        print(json.dumps(logs, indent=2, default=str))
        return

    print(f"\n┌─────────────────────────────────────────────────────────────────────────┐")
    print(f"│  Team: {team_alias:<65}│")
    print(f"└─────────────────────────────────────────────────────────────────────────┘")
    if not logs:
        print("  无消费日志")
        return

    logs_sorted = sorted(logs, key=lambda x: x.get("startTime", "") or "", reverse=True)
    print(f"  {'Time':<22}  {'Model':<45}  {'Tokens':>8}  {'Cost':>10}")
    print(f"  {'─'*22}  {'─'*45}  {'─'*8}  {'─'*10}")
    total_cost = 0
    total_tok = 0
    for log in logs_sorted[:50]:
        ts    = (log.get("startTime") or "")[:19]
        model = (log.get("model") or "?").split("/")[-1][:45]
        tok   = log.get("total_tokens", 0)
        cost  = log.get("spend", 0)
        total_cost += cost
        total_tok  += tok
        print(f"  {ts:<22}  {model:<45}  {tok:>8}  ${cost:>9.5f}")
    print(f"  {'─'*90}")
    print(f"  {'TOTAL':<68}  {total_tok:>8}  ${total_cost:>9.5f}")


def main():
    parser = argparse.ArgumentParser(description="LiteLLM × Bedrock 团队费用查询")
    parser.add_argument("--days",  type=int, default=30, help="查询最近 N 天 (default: 30)")
    parser.add_argument("--team",  type=str, default="",  help="查看指定 Team 的详细日志")
    parser.add_argument("--json",  action="store_true",   help="输出 JSON 格式")
    parser.add_argument("--aws-only",  action="store_true", help="只查 AWS Cost Explorer")
    parser.add_argument("--litellm-only", action="store_true", help="只查 LiteLLM")
    args = parser.parse_args()

    teams_spend = []
    aws_costs = {}

    if not args.aws_only:
        teams_spend = get_team_spend_summary()

    if not args.litellm_only:
        aws_costs = get_aws_bedrock_cost_by_team(days=args.days)

    print_team_summary(teams_spend, aws_costs, as_json=args.json)

    if args.team:
        # 找 team_id
        all_teams = get_all_teams()
        team_obj = next(
            (t for t in all_teams
             if t.get("team_alias") == args.team or t.get("team_id") == args.team),
            None
        )
        if team_obj:
            logs = get_team_logs(team_obj["team_id"], limit=50)
            print_team_logs(args.team, logs, as_json=args.json)
        else:
            print(f"\n  ⚠️  找不到 Team: {args.team}")
            print("  可用的 Teams:")
            for t in get_all_teams():
                print(f"    - {t.get('team_alias', 'N/A')} (id: {t.get('team_id', 'N/A')})")


if __name__ == "__main__":
    main()
