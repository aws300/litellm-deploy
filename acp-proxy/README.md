# CloudNativeFormation.yaml — LiteLLM + acp-proxy 一键部署

一份 CloudFormation 模板，一次点击部署完整的云原生栈：VPC(IPv6 双栈) + EKS(Auto Mode, **1.37**) + EnvoyGateway + CloudFront + Global Accelerator + Cognito SSO + Aurora Postgres Serverless + ElastiCache Serverless(Valkey) + DynamoDB + EFS，上面跑两个**都可选**的应用：

| 应用 | 参数 | 挂载路径 | 说明 |
|---|---|---|---|
| **LiteLLM** v1.106.6 | `DeployLiteLLM` (默认 `true`) | `/`（UI 在 `/ui/`） | Bedrock 模型的 OpenAI / Anthropic 兼容网关，虚拟 key + 预算 |
| **acp-proxy** 0.2.3 | `DeployAcpProxy` (默认 `true`) | `/acp-proxy/` | Anthropic Messages API 兼容代理，后端是一组 Kiro 账号（`kiro-cli acp`） |

**域名约定**：后端（API）域名 = **Global Accelerator** 的域名，前端（控制台 / 管理 UI）域名 = **CloudFront** 的域名。两个域名后面是同一个 EnvoyGateway，按路径分发：`/acp-proxy*` → acp-proxy，其余 → LiteLLM。

本模板由 [`../CloudNativeFormationLitellm.yaml`](../CloudNativeFormationLitellm.yaml) 演化而来，**包含它的全部内容**（117 个资源里 108 个与原模板一致：VPC、EKS、节点池、Addon、EnvoyGateway、CloudFront、GA、Cognito、Aurora、Valkey、DynamoDB、EFS、LiteLLM 的全部 K8s 对象 / Helm values / access_policy / 模型列表 / HPA），只做了三类改动：

1. 两个开关 `DeployLiteLLM` / `DeployAcpProxy`：LiteLLM 专属资源（Cognito 客户端、Pod Identity、K8s 对象、Helm 部署）挂条件；Aurora / Valkey 只在至少装一个应用时创建（`DeployAnyApp`）。原 `K8sAppResources` 拆成网关级的 `K8sAppResources`（始终存在，HTTP/2 ClientTrafficPolicy）+ `LiteLLMK8sResources`（LiteLLM 的 11 个对象，逐字未改）。
2. acp-proxy 的资源（下文「acp-proxy 部分」）。
3. CloudFront 增加两条 `/acp-proxy*` 行为（`DeployAcpProxy=false` 时不存在）。

所以 LiteLLM 侧的文档照常适用：[../API.md](../API.md)（LiteLLM API）、[../aws-example/](../aws-example/README.md)、[../docs/console-deployment.md](../docs/console-deployment.md)、`../scripts/e2e-test.sh`（Outputs 键名 `A1..A4` 不变）。

- **Kiro 账号初始化**（acp-proxy 必读）：[kiro-init.md](kiro-init.md)
- **不用 CloudFormation，直接 `helm install` acp-proxy**：见「八」

---

## 前置条件

- AWS 账号 **admin 权限**（模板会创建 IAM Role、VPC、EKS、Lambda、CloudFront、Global Accelerator、Secrets Manager 等）
- **acp-proxy 的 GHCR 包必须是 public**（部署 Lambda 匿名拉取）：
  - Helm chart：`oci://ghcr.io/aws300/charts/acp-proxy`（包名 `charts/acp-proxy`）
  - 镜像：`ghcr.io/aws300/acp-proxy-server`（linux/arm64）
  - 自检：`helm show chart oci://ghcr.io/aws300/charts/acp-proxy --version 0.2.3`（未登录 GHCR 的机器上能拉到即可）
- **LiteLLM 需要 Bedrock 模型访问**（`DeployLiteLLM=true` 时）：Claude opus/sonnet/haiku 5.5、GLM 5.3、Kimi K3、Cohere Embed v4 走本 Region 的 `global.*` 跨区推理配置文件；GPT-6 / GPT-6.1 走 `us-east-1` 的 `bedrock-mantle`（参数 `BedrockRegion` / `BedrockMantleRegion` 可改）
  - 开通位置：AWS Console → Amazon Bedrock → **Model access** → **Modify model access** → 勾选 → **Submit**
- **acp-proxy 需要 Kiro 订阅**：一个 IAM Identity Center 实例里有已订阅 Kiro 的用户，见 [kiro-init.md](kiro-init.md)。部署本身不需要，装完再加账号即可。
- 目标 Region 至少 **2 个 AZ**（`us-west-1` 只有 2 个，见模板 `TwoAzRegion` 条件）、EIP 配额 ≥ 3、On-Demand vCPU 配额 ≥ 4（两个应用都装建议 ≥ 16）、`m8g.xlarge` 可用（模板启动时预检并直接失败退出）

---

## 一、通过 Console 部署（推荐）

### 步骤 1：把模板上传到 S3

模板 ~230 KB，超过 CloudFormation Console 51 KB 的 inline 上限，必须借助 S3。

1. 打开 [https://console.aws.amazon.com/s3](https://console.aws.amazon.com/s3)，右上角切到目标 Region
2. **Create bucket**，名字如 `cfn-deploy-<账号12位>-<region>`，Region 与部署 Region 一致，其余默认
3. 进入桶 → **Upload** → 选本目录的 `CloudNativeFormation.yaml` → **Upload**
4. 点这个对象，复制 **Object URL**

### 步骤 2：创建 Stack

1. 打开 [https://console.aws.amazon.com/cloudformation](https://console.aws.amazon.com/cloudformation)，确认 Region
2. **Create stack** → **With new resources (standard)**
3. **Specify template**：**Choose an existing template** → **Amazon S3 URL** → 粘贴 Object URL → **Next**
4. **Specify stack details**：

   | 参数 | 建议值 | 说明 |
   |---|---|---|
   | Stack name | `cnf-sg` | 任意 |
   | `ProjectName` | `cnf` | 资源名前缀，字母开头 1–20 位字母数字 |
   | `EnvironmentId` | `sg01` | 1–12 位字母数字，给资源加后缀，同账号同 Region 不可重复 |
   | **`DeployLiteLLM`** | `true` / `false` | 是否装 LiteLLM |
   | **`DeployAcpProxy`** | `true` / `false` | 是否装 acp-proxy |
   | `AcpProxyChartRef` | `oci://ghcr.io/aws300/charts/acp-proxy` | 一般不改 |
   | `AcpProxyChartVersion` | `0.2.3` | 升级 acp-proxy 时改这里再 Update stack |
   | `AcpProxyImageRepository` / `AcpProxyImageTag` | `ghcr.io/aws300/acp-proxy-server` / 空 | 空 tag = chart 的 appVersion |
   | `AcpProxyReplicas` | `2` | acp-proxy Pod 数；Kiro 账号经 Valkey 分片到各 Pod |
   | `AcpProxyPersistence` | `true` | 每个 Pod 一块 gp3 EBS 存 Kiro 登录态；`false` = Pod 重启后账号需重新登录 |
   | `AcpProxyVolumeSize` | `20` | 每个 Pod 的 EBS 大小 (GiB) |
   | `VpcCidr` | `10.80.0.0/16` | 改成不冲突的 `/16` |
   | `EnvoyGatewayVersion` | `v1.10.0` | |
   | `BedrockRegion` / `BedrockMantleRegion` | 空 / `us-east-1` | 只影响 LiteLLM |
   | `CloudFrontOriginReadTimeout` | `60` | CloudFront 等首字节的秒数（最大 180，需先提配额 L-AECE9FA7）。API 客户端走 GA 不受影响 |
   | `AdminRoleArn` | 可选 | 自动获得 EKS 管理员权限的 Role。**不要填部署 Stack 所用的身份**（EKS 已自动给集群创建者建了 access entry，重复会 `409 AlreadyExists` 导致整个 Stack 失败） |
   | `Tags` | `{"Env":"prod"}` | JSON；同时打到 Karpenter 的 EC2（见「打 Tag 的强制要求」） |

5. **Configure stack options** → **Stack failure options** 选 **Preserve successfully provisioned resources** → **Next**
6. **Review** → 勾选 **I acknowledge that AWS CloudFormation might create IAM resources with custom names** → **Submit**

### 步骤 3：等待完成（35–50 分钟）

主要耗时：EKS ~15 min、Aurora ~10 min、CloudFront ~10 min、LiteLLM Helm ~5 min、acp-proxy（拉 ~1 GB 镜像 + 等 Pod Ready）~5 min。状态 **CREATE_COMPLETE** 即可。`AcpProxyDeploy` 会等到至少一个 acp-proxy Pod Ready 才成功；镜像拉不下来 / 持续崩溃会在 3 分钟后带原因失败。

### 用 CLI 部署（等价）

```bash
REGION=ap-southeast-1; BUCKET=cfn-deploy-$(aws sts get-caller-identity --query Account --output text)-$REGION
aws s3 mb s3://$BUCKET --region $REGION 2>/dev/null
aws s3 cp CloudNativeFormation.yaml s3://$BUCKET/ --region $REGION
aws cloudformation create-stack --region $REGION --stack-name cnf-sg \
  --template-url https://$BUCKET.s3.$REGION.amazonaws.com/CloudNativeFormation.yaml \
  --capabilities CAPABILITY_NAMED_IAM --disable-rollback \
  --parameters ParameterKey=ProjectName,ParameterValue=cnf ParameterKey=EnvironmentId,ParameterValue=sg01 \
               ParameterKey=DeployLiteLLM,ParameterValue=true ParameterKey=DeployAcpProxy,ParameterValue=true
aws cloudformation wait stack-create-complete --region $REGION --stack-name cnf-sg
aws cloudformation describe-stacks --region $REGION --stack-name cnf-sg --query 'Stacks[0].Outputs' --output table
```

用 `--disable-rollback`（等价于 Console 的 *Preserve successfully provisioned resources*），**不要**用 `--on-failure DO_NOTHING`：后者建出来的 Stack 在 `CREATE_FAILED` 后不能 Update，只能删了重建；前者可以修好原因（例如把 GHCR 包设为 public）后直接 `aws cloudformation update-stack --use-previous-template ...` 重试失败的那一步。

### 步骤 4：Outputs

| Output Key | 条件 | 用途 |
|---|---|---|
| `A1ApiUrlGlobalAccelerator` | LiteLLM | `https://<ga-dns>` — LiteLLM API（推荐给 API 客户端），见 [../API.md](../API.md) |
| `A2ApiUrlCloudFront` | LiteLLM | `https://<cf-domain>` — 同一套 LiteLLM API 经 CloudFront |
| `A3AdminUI` | LiteLLM | `https://<cf-domain>/ui/` — LiteLLM UI（Cognito SSO） |
| `A4MasterKey` | LiteLLM | 只读 master key：只能读统计，**不能调模型、不能建 key、不能登录 UI** |
| **`B1AcpProxyApiBaseUrl`** | acp-proxy | `https://<ga-dns>/acp-proxy` — Anthropic base URL（`ANTHROPIC_BASE_URL`） |
| **`B2AcpProxyConsole`** | acp-proxy | `https://<cf-domain>/acp-proxy/` — acp-proxy 控制台（Cognito SSO） |
| **`B3AcpProxyApiKey`** | acp-proxy | `sk-acp-...` — 调 `/v1/messages` 的 API key |
| **`B4AcpProxyAdminToken`** | acp-proxy | 管理 API 的 bearer token（脚本用） |
| **`B5ClaudeCodeEnv`** | acp-proxy | 直接可 `export` 的 Claude Code 环境变量 |
| `CognitoAdminUsername` / `CognitoAdminPassword` | 总有 | 两个控制台共用的 SSO 账号，**密码只显示一次，立即保存** |
| `EksClusterName` | 总有 | `kubectl` 连接用 |
| `AuroraEndpoint` / `ValkeyEndpoint` / `DynamoDBTableName` | 装了任一应用 | 后端数据服务 |

acp-proxy 的三个生成凭据同时存在 Secrets Manager（Stack 资源 `AcpProxyAdminTokenSecret` / `AcpProxyApiKeySecret` / `AcpProxyStoreKeySecret`，名字由 CloudFormation 生成；API key 为 `sk-acp-` + `AcpProxyApiKeySecret` 的值），Stack Update 时保持不变。

---

## 二、LiteLLM：首次登录并生成 API Key

Master key 是只读的（见「安全模型」），调模型必须先 SSO 登录 UI 生成虚拟 key。

1. 浏览器打开 `A3AdminUI`，跳转到 Cognito 登录页
2. 用户名 `CognitoAdminUsername`（默认 `admin@example.aws`），密码 `CognitoAdminPassword`
3. 进 LiteLLM Dashboard → **Virtual Keys** → **+ Create New Key**
   - **Key Name**：如 `verify-key`；**Models** 留空 = 全部
   - **Optional Settings**：**Max Budget (USD)** 如 `100`（必填，安全护栏）、**Reset Budget** `monthly`
4. 复制弹出的 `sk-xxxxx...`（只显示一次）
5. 用它调 `A1`（GA）或 `A2`（CloudFront）的 `/v1/chat/completions`、`/v1/messages`、`/v1/responses`、`/v1/embeddings`，见 [../API.md](../API.md)；端到端验证：`LITELLM_KEY=sk-... ../scripts/e2e-test.sh --stack <stack> --region <region>`

---

## 三、acp-proxy：登录控制台、加 Kiro 账号、调用

### 3.1 登录控制台

1. 打开 `B2AcpProxyConsole`（`https://<cf-domain>/acp-proxy/`）→ 跳到 Cognito 登录（与 LiteLLM 同一个用户池）
2. 用 `CognitoAdminUsername` / `CognitoAdminPassword` 登录。只有 Cognito 组 **`admin`** 的成员能进（模板创建的管理员已在组里；新用户需在 Cognito 控制台加入 `admin` 组）
3. 首页 **Public endpoint** 显示的是 GA 域名上的 API 地址 `https://<ga-dns>/acp-proxy/v1/messages`

### 3.2 加 Kiro 账号（必须，否则 `/v1/messages` 无账号可用）

**Accounts** 页 → 打开 **Custom account — my own Identity Center** → 填 **Label / email**、**Start URL**（`https://d-xxxxxxxxxx.awsapps.com/start`）、**Region**（Identity Center 所在 Region）→ **Add custom account** → 该行点 **Login** → 出现验证链接和验证码 → 浏览器打开链接、用该 Kiro 用户登录并 **Allow** → 行状态变为已登录。

完整步骤（Identity Center / Kiro 订阅准备、脚本方式、重新登录、多账号）见 **[kiro-init.md](kiro-init.md)**。

### 3.3 调用

```bash
BASE=$(aws cloudformation describe-stacks --stack-name cnf-sg --query "Stacks[0].Outputs[?OutputKey=='B1AcpProxyApiBaseUrl'].OutputValue" --output text)
KEY=$(aws cloudformation describe-stacks --stack-name cnf-sg --query "Stacks[0].Outputs[?OutputKey=='B3AcpProxyApiKey'].OutputValue" --output text)

curl -s $BASE/v1/models -H "x-api-key: $KEY"

curl -sN $BASE/v1/messages -H "x-api-key: $KEY" -H 'content-type: application/json' \
  -d '{"model":"claude-sonnet-5-5","max_tokens":256,"stream":true,
       "messages":[{"role":"user","content":"用一句话介绍你自己"}]}'
```

**Claude Code**（`B5ClaudeCodeEnv` 即这两行）：

```bash
export ANTHROPIC_BASE_URL=https://<ga-dns>/acp-proxy
export ANTHROPIC_AUTH_TOKEN=sk-acp-...
claude
```

**Anthropic SDK**：`Anthropic(base_url="https://<ga-dns>/acp-proxy", api_key="sk-acp-...")`。

- 模型名按家族映射：含 `opus` / `sonnet` / `haiku` 的任意模型名分别落到 `claude-opus-5.5` / `claude-sonnet-5.5` / `claude-haiku-5.5`，其他落到默认模型。
- 联网搜索：请求里带 Anthropic 原生 `web_search` / `web_fetch` server tool，或 header `X-Acp-Web-Search: true`。
- **API 走 GA**（无响应超时）。CloudFront 上同样可用（`https://<cf-domain>/acp-proxy`），但非流式长调用超过 `CloudFrontOriginReadTimeout` 会 504。
- 会话粘性：Claude Code 自带 `X-Claude-Code-Session-Id`，Envoy 按它一致性哈希到同一 Pod；其他客户端可带 `X-Session-Id`。

---

## 四、部署后：在 AWS CloudShell 里控制 K8s 集群

CloudShell 已预装 `aws` CLI，只需要装 `kubectl`。

### 步骤 1：打开 CloudShell

AWS Console 右上角 **CloudShell 图标**（`>_`），或 [https://console.aws.amazon.com/cloudshell](https://console.aws.amazon.com/cloudshell)，确认 Region 与部署 Region 一致。

### 步骤 2：下载 kubectl

```bash
curl -sSLO "https://dl.k8s.io/release/v1.37.0/bin/linux/amd64/kubectl"
chmod +x kubectl && mkdir -p ~/bin && mv kubectl ~/bin/
export PATH=$HOME/bin:$PATH; echo 'export PATH=$HOME/bin:$PATH' >> ~/.bashrc
kubectl version --client
```

### 步骤 3：授权 CloudShell 身份访问集群（部署时没填 AdminRoleArn 且不是部署者本人时）

1. [EKS 控制台](https://console.aws.amazon.com/eks) → 你的集群 → **Access** → **IAM access entries** → **Create access entry**
2. **IAM principal ARN**：`aws sts get-caller-identity` 的身份；`assumed-role/<RoleName>/<Session>` 形式填 `arn:aws:iam::<账号>:role/<RoleName>`
3. **Type** STANDARD → **Add policy**：`AmazonEKSClusterAdminPolicy`，scope `Cluster` → **Create**

### 步骤 4：连接

```bash
REGION=ap-southeast-1
CLUSTER=<Outputs 里的 EksClusterName>
aws eks update-kubeconfig --region ${REGION} --name ${CLUSTER}
kubectl get nodes; kubectl get pods -A
```

### 步骤 5：常用观测

```bash
# LiteLLM
kubectl -n litellm get pods -o wide
kubectl -n litellm logs -l app.kubernetes.io/name=litellm --tail=100

# acp-proxy（StatefulSet，Pod 名 acp-proxy-0/1…，每个 Pod 一块 PVC data-acp-proxy-N）
kubectl -n acp-proxy get sts,pods,pvc -o wide
kubectl -n acp-proxy logs acp-proxy-0 --tail=100
kubectl -n acp-proxy get cm acp-proxy-config -o jsonpath='{.data.config\.yaml}' | head -30
helm -n acp-proxy list   # 若本地装了 helm

# EnvoyGateway + 路由（acp-proxy 的 HTTPRoute 前缀 /acp-proxy，挂 CF + GA 两个 hostname）
kubectl -n envoy-gateway-system get svc,pods
kubectl get gateway,httproute -A

# Karpenter Auto Mode 节点池
kubectl get nodepool,nodeclass
```

---

## 五、注意事项

### 权限相关

- **部署者必须是 admin 或 PowerUser**：任何单一权限缺失都会在半途失败。
- **SCP / Permission Boundary**：账号被限制了 CloudFront / Global Accelerator / Bedrock / Secrets Manager 时会卡在对应资源上，先在 Console 手动试一下同类操作。
- **kubectl 需要单独的 EKS Access Entry**：Console IAM 权限不等于集群访问权，见「四、步骤 3」，或部署时填 `AdminRoleArn`。

### 配额相关

`QuotaCheck` Lambda 先做预检（含 Lambda 名 `<ProjectName><EnvironmentId>-acp-deploy` 的冲突检查），失败直接终止并列出缺失项。手动确认：

- **EIP** ≥ 3 — EC2-VPC Elastic IPs (L-0263D0A3)
- **VPC per Region** 至少剩 1 — L-F678F1CE
- **NAT Gateway per AZ** 每 AZ 至少剩 1 — L-FE5A380F
- **Running On-Demand Standard vCPU** ≥ 4（LiteLLM 每 Pod request 2 CPU × 至少 3 副本，acp-proxy 每 Pod 0.5 CPU，两个都装建议 ≥ 16）— L-1216C47A
- **m8g.xlarge 在目标 Region 可用**

### 打 Tag 的强制要求（重要！）

- 很多公司账号的 SCP 要求 EC2 必须带某组 tag，否则 `RunInstances` 被拒。EKS Auto Mode 内置的 `default` NodePool/NodeClass 没有这些 tag，会一直 `NotReady`——**不影响部署**：真正调度用的是模板创建、带 `Tags` 参数注入的 5 个 NodePool（`cpu-system` / `cpu` / `cpu-large` / `cpu-general` / `gpu`）+ `default-tags` NodeClass。
- `kubectl get nodeclass` 里 `default-tags` 为 `True` 即正常（`default` 为 `False` 忽略）。
- 强制 tag 要填在参数 **`Tags`**（JSON）里，它会打到 CFN 资源和 Karpenter 生成的 EC2；**不要**只用 Console 的 "Advanced options → Tags"（不会传给 EC2）。

### 部署期间

- **模板 >51 KB 必须走 S3 URL**。
- 推荐 **Preserve successfully provisioned resources**；出错看 CloudWatch 日志组 `/aws/lambda/<ProjectName><EnvironmentId>-<function>`：`kubectl`、`eg-installer`、`helm-deploy`（LiteLLM）、**`acp-deploy`**（acp-proxy）。
- **EKS 版本固定 1.37**；旧模板（1.33–1.35）建的 Stack 不能直接 Update 到本模板，先在 EKS 控制台逐级升级或删除重建。
- **不要通过 Update stack 改 EKS `ComputeConfig` / `NodePools`**。
- 默认 5 个 NodePool；LiteLLM 与 acp-proxy 都只用 arm64 `cpu` 池（acp-proxy 镜像只有 linux/arm64，chart 里 `nodeSelector: kubernetes.io/arch: arm64`）。`g6e.2xlarge` 在 ap-southeast-1 不可用，只影响 GPU 池。
- **Update stack 可以改的开关**：`DeployLiteLLM` / `DeployAcpProxy` 都能事后打开或关闭（关闭 = 卸载对应应用及其 Cognito 客户端；Aurora / Valkey 在两个都关时才删）。`AcpProxyChartVersion` / `AcpProxyImageTag` / `AcpProxyReplicas` 改完 Update 即 `helm upgrade`。`AcpProxyPersistence` 切换时部署 Lambda 会孤儿删除并重建 StatefulSet（volumeClaimTemplates 不可变），再替换被接管的 Pod（Pod 的卷不可原地修改），**切换后所有 Kiro 账号需重新登录**（期间服务短暂中断）。开启时每个 Pod 一块 gp3 EBS 卷；EBS 卷属于单个可用区，PV 的 node affinity 让 `acp-proxy-N` 每次重启都回到同一可用区，两个副本按可用区打散（`zoneSpread`）。
- **首次部署失败先看 Events 页签** `CREATE_FAILED` 的 `Status reason`：多为配额 / SCP / IAM，或 Bedrock 未开通；acp-proxy 特有的是 GHCR 包未公开（见「故障排查」）。

### 已知 Bedrock 限制（LiteLLM，非模板问题）

- GPT-6 / GPT-6.1 只能走 `bedrock-mantle`（Responses API）；五个 GPT-6 只有 `us-east-1` 的 mantle 全部提供，所以 `BedrockMantleRegion` 默认 `us-east-1`。
- `kimi-k3` 在 Bedrock 上不支持提示缓存，模板里没有它的缓存注入点。

### 拆栈

CloudFormation → 选中 Stack → **Delete**，15–30 分钟。删除顺序已内置：acp-proxy `helm uninstall` → 删除每个 Pod 的 PVC 并等待 EBS 卷释放（避免残留卷计费）→ 删 `acp-proxy` 命名空间 / StorageClass → LiteLLM `helm uninstall` → 清理 NLB / LoadBalancer Service（避免残留 ENI 阻塞 VPC 删除）。Secrets Manager 的三个 acp-proxy 密钥按默认恢复窗口删除；名字由 CloudFormation 生成，所以同一个 `EnvironmentId` 可以立刻重建。

---

## 六、安全模型

### LiteLLM：只能用虚拟 key 调模型

- **Master key 只读**：`access_policy.py` 包装 LiteLLM 所有入口共用的认证函数：✅ `GET` 统计 / 信息类接口；❌ 所有模型调用 → 403；❌ 所有写操作（`/key/generate` …）→ 403；❌ 不能当 UI 密码登录（`disable_env_credential_login`），UI 只走 Cognito SSO。
- **每个 key 必须带预算**；Spend Log 不存提示词与回复（`store_prompts_in_spend_logs: false`）。
- **模型列表**写死在 `LiteLLMDeploy.Properties.LiteLLMValues`（UI 新增的模型不生效；无 `bedrock/*` 通配）。
- master key 由 StackId 的 GUID 派生，每个 Stack 不同；升级镜像后跑一遍 `../scripts/e2e-test.sh`。

### acp-proxy

- **API**：只接受 `B3AcpProxyApiKey`（`x-api-key` 或 `Authorization: Bearer`）。要加更多 key：`helm upgrade --reuse-values --set 'secrets.apiKeys={sk-a,sk-b}'`（注意下次 Stack Update 会以模板生成的单个 key 覆盖）。
- **控制台**：Cognito OIDC（服务端 BFF，PKCE + client secret），只放行 `groups` 含 `admin` 的用户；会话 cookie `HttpOnly`、`Secure`、`Path=/acp-proxy`。`B4AcpProxyAdminToken` 是脚本用的后备入口，等同管理员。
- **不存密码**：自定义账号走人工批准的 device flow，Kiro 的 token 只在各 Pod 自己的 EBS 卷上（每个账号独立 `HOME`）。请求内容不会写进 kiro 进程环境。
- **凭据**：admin token / API key / store key 由 Secrets Manager 随机生成；Aurora DSN 走 K8s Secret（`ACP_DB_DSN`），Valkey 密码在 ConfigMap 的 redis DSN 里（与 LiteLLM 一样是集群内可见）。

### 两个应用共用的

- **入口没有公网负载均衡器**（NLB、ALB 都是 `internal`）。CloudFront 对 API 前缀一律不缓存（`CachingDisabled`），只缓存静态资源，缓存键含 `Host`。

---

## 七、架构速记

```
                 ┌─ CloudFront (<cf>.cloudfront.net)  前端：/ui/ (LiteLLM)  /acp-proxy/ (acp-proxy 控制台)
   浏览器 ────────┤     └─ VPC Origin → 内部 ALB ─┐
                 │                              ├─► EnvoyGateway (Gateway eg, HTTP:80 / HTTPS:443)
   API 客户端 ────┴─ Global Accelerator          │      ├─ HTTPRoute /acp-proxy*  ─► acp-proxy StatefulSet ×N ─► kiro-cli acp（每账号一个进程）
     (Claude Code)   (<ga>.awsglobalaccelerator.com) → 内部 NLB ┘      └─ HTTPRoute /           ─► LiteLLM Deployment (HPA 3–30) ─► Bedrock
                                                                     共享：Aurora PG（litellm 库 / acp-proxy 库）· Valkey · Cognito · DynamoDB · EFS
```

- **前缀路由**：acp-proxy 的 HTTPRoute 用 `PathPrefix /acp-proxy`，比 LiteLLM 的 `/` 长，同一 hostname 上优先匹配；前缀不在网关剥离，由 acp-proxy 自己处理（chart `rootPath`）。路由不绑定 listener，也不做 HTTP→HTTPS 跳转（CloudFront 回源走 Envoy 的 HTTP listener）。
- **acp-proxy 多副本**：Pod 经 Valkey（`acp:members`）发现彼此，Kiro 账号按 rendezvous 哈希分到唯一 Pod 登录；L1 = Envoy 按 `X-Claude-Code-Session-Id` / `X-Session-Id` 一致性哈希，L2 = 无会话 header 的请求由应用转发到账号所在 Pod。控制台里添加的账号写入 Aurora（`acp-proxy` 库，首次启动自动建库），各 Pod 30s 内同步。
- **认证**：LiteLLM UI 与 acp-proxy 控制台都走同一个 Cognito 用户池（组 `admin`），各自一个 App Client（回调 `…/sso/callback` 与 `…/acp-proxy/auth/oidc/callback`）。
- **计算**：EKS Auto Mode + Karpenter，纯 arm64 (m8g)。**存储**：acp-proxy 每 Pod 一块 gp3 EBS（StorageClass `acp-proxy-gp3`，EKS Auto Mode 内置 EBS 驱动），EFS 为默认 StorageClass（`efs-sc`）。
- **TLS**：cert-manager + Let's Encrypt 为 GA hostname 签发证书（`ga-https-cert`）；CloudFront 用自己的证书。

---

## 八、不用 CloudFormation：直接 `helm install` acp-proxy

已有 Kubernetes 集群（EKS 或其他）时，acp-proxy 可以直接用 Helm 装，CloudFormation 里的 `AcpProxyDeploy` 做的也就是这一步。

### 8.1 前置条件

- **Gateway API + Envoy Gateway**，以及一个 `Gateway`（chart 默认 `envoy-gateway-system/eg`，`global.gateway` / `global.gatewayNamespace` 可改）。默认路由挂在名为 **`https`** 的 listener 上，并在名为 **`http`** 的 listener 上加 HTTP→HTTPS 跳转（`gateway.listener` / `gateway.httpsRedirect` 可改，见 8.4）。
- **linux/arm64 节点**（镜像只有 arm64）。
- 可选依赖：Postgres（请求日志、会话亲和、控制台添加的账号持久化）、Redis（多副本必需）、OIDC 或 Basic Auth（控制台登录）。
- Helm ≥ 3.8（OCI chart）。chart 与镜像都是公开的，不需要 `helm registry login`：
  ```bash
  helm show values oci://ghcr.io/aws300/charts/acp-proxy --version 0.2.3   # 全部可配置项
  ```

### 8.2 最小安装（单副本，无外部依赖）

```bash
ADMIN_TOKEN=$(openssl rand -hex 24)
API_KEY=sk-acp-$(openssl rand -hex 20)

helm install acp-proxy oci://ghcr.io/aws300/charts/acp-proxy --version 0.2.3 \
  -n acp-proxy --create-namespace \
  --set host=acp.example.com \
  --set secrets.adminToken=$ADMIN_TOKEN \
  --set secrets.storeKey=$(openssl rand -hex 32) \
  --set "secrets.apiKeys[0]=$API_KEY" \
  --set dependencies.auth="admin:$(openssl rand -hex 12)" \
  --set nodeSelector."kubernetes\.io/arch"=arm64

kubectl -n acp-proxy rollout status statefulset/acp-proxy
echo "admin token: $ADMIN_TOKEN   api key: $API_KEY"
```

- 控制台：`https://acp.example.com/acp-proxy/`（浏览器弹 Basic Auth，用户名 `admin`，密码为上面 `dependencies.auth` 的冒号后部分，可 `helm get values acp-proxy -n acp-proxy` 查看）
- API：`ANTHROPIC_BASE_URL=https://acp.example.com/acp-proxy`，`x-api-key: $API_KEY`
- `host` 的 DNS 要指向 Gateway，TLS 证书由 Gateway 的 `https` listener 提供。
- 不设 `dependencies.db` 时数据在内存 / Pod 本地：请求日志、控制台添加的账号在 Pod 重启后丢失，适合试用。
- 想挂在域名根路径：`--set rootPath=""`。

### 8.3 生产安装（多副本 + Postgres + Redis + OIDC + EBS）

`values-prod.yaml`：

```yaml
host: acp-console.example.com        # 控制台（前端）域名；OIDC 回调 https://<host>/acp-proxy/auth/oidc/callback
apiHost: acp-api.example.com         # 可选：API（后端）域名，控制台显示 https://<apiHost>/acp-proxy
rootPath: /acp-proxy
replicas: 2                          # >1 必须配置 dependencies.redis
nodeSelector:
  kubernetes.io/arch: arm64
persistence:                         # 每个 Pod 一块卷保存 Kiro 登录态
  enabled: true
  storageClass: gp3                  # EKS Auto Mode：provisioner ebs.csi.eks.amazonaws.com 的 StorageClass
  size: 20Gi
dependencies:
  # TLS Redis / ElastiCache Serverless：rediss://default:<url-encoded 密码>@<host>:6379
  redis: "rediss://default:CHANGE_ME@my-cache.serverless.use1.cache.amazonaws.com:6379"
  # Cognito：pre-token-generation Lambda 把组写进顶层 groups 声明，groups=admin 只放行 admin 组
  auth: "oidc://<clientId>:<clientSecret>@cognito-idp.us-east-1.amazonaws.com/<userPoolId>?scope=openid%20profile%20email&groups=admin"
secrets:
  adminToken: "CHANGE_ME"            # openssl rand -hex 24
  storeKey: "CHANGE_ME"              # openssl rand -hex 32；多副本必须一致（chart 共用一个 Secret）
  apiKeys:
    - "sk-acp-CHANGE_ME"
  # Postgres DSN 放 Secret（不进 ConfigMap）；库不存在会在首次启动时自动创建
  dbDSN: "postgres://pgadmin:CHANGE_ME@my-aurora.cluster-xxxx.us-east-1.rds.amazonaws.com:5432/acp-proxy?sslmode=require"
```

```bash
helm upgrade --install acp-proxy oci://ghcr.io/aws300/charts/acp-proxy --version 0.2.3 \
  -n acp-proxy --create-namespace -f values-prod.yaml
```

- 机密也可以预先建好 Secret，用 `--set secretName=<name>`；Secret 里需要 `ACP_ADMIN_TOKEN`、`KP_SECRET_KEY`、`ACP_API_KEY_0..N` 和可选的 `ACP_DB_DSN`；`secrets.apiKeys` 仍要写同样条数的占位值（ConfigMap 按条数生成 `${ACP_API_KEY_i}` 引用），用 Secret 里的 DSN 时再设 `secrets.dbDSN` 为任意非空占位。
- OIDC 客户端需登记回调 `https://<host>/acp-proxy/auth/oidc/callback`、登出地址 `https://<host>/acp-proxy/`。

### 8.4 装进本模板创建的集群 / 放在 CloudFront 后面

CloudFront VPC Origin 经 Envoy 的 **HTTP** listener 回源，所以路由不能只挂 `https`，也不能做 HTTPS 跳转（否则重定向循环）。这正是 `AcpProxyDeploy` 传给 chart 的值：

```yaml
host: <CloudFront 域名>              # 例：d1234abcd.cloudfront.net（Outputs: CloudFrontDomain）
apiHost: <GA 双栈域名>               # 例：a1b2.awsglobalaccelerator.com（Outputs: GlobalAcceleratorHost）
gateway:
  listener: ""                       # 挂到 Gateway 的全部 listener
  httpsRedirect: false
persistence: {enabled: true, storageClass: acp-proxy-gp3, size: 20Gi}
```

另外 CloudFront 需要 `/acp-proxy*` 不缓存的行为（本模板 `DeployAcpProxy=true` 时自带）。

### 8.5 安装后

- 加 Kiro 账号：[kiro-init.md](kiro-init.md)（把文中的 `BASE` 换成 `https://<host 或 apiHost>/acp-proxy`，`TOKEN` 换成 `secrets.adminToken`）。
- 升级：`helm upgrade acp-proxy oci://ghcr.io/aws300/charts/acp-proxy --version <新版本> -n acp-proxy --reuse-values`。
- `persistence.enabled` 不能在已有 release 上直接切换（StatefulSet 的 volumeClaimTemplates 不可变）：先 `kubectl -n acp-proxy delete sts acp-proxy --cascade=orphan` 再 `helm upgrade`，之后账号需重新登录。
- 卸载：`helm uninstall acp-proxy -n acp-proxy`，然后 `kubectl -n acp-proxy delete pvc --all`（StatefulSet 的 PVC 不随 release 删除，不删会一直计费）。

---

## 九、故障排查（acp-proxy）

| 现象 | 原因 / 处理 |
|---|---|
| `AcpProxyDeploy` 失败：`chart pull refused (is the GHCR package public?)` | `charts/acp-proxy` 包还是 private。在 GitHub → aws300 → Packages → `charts/acp-proxy` → Package settings → Change visibility → Public，然后 **Retry / Update stack** |
| 失败：`pod acp-proxy-0: ImagePullBackOff` | 镜像包 `acp-proxy-server` 未公开，或 `AcpProxyImageTag` 写错 |
| 失败：`CrashLoopBackOff` | `kubectl -n acp-proxy logs acp-proxy-0 --previous`。常见：OIDC 发现失败（Cognito 不可达）、Aurora 冷启动（会自动重试） |
| 控制台登录后 `access denied` | 该 Cognito 用户不在 `admin` 组 |
| 控制台登录后 `login session expired` | 在 GA 域名上打开了控制台：控制台只在 CloudFront 域名（`B2AcpProxyConsole`）上登录 |
| `/v1/messages` 报 `no enabled accounts configured` / `not logged in and auto-login disabled` | 还没加 Kiro 账号，或账号还没 Login / 需重新登录，见 [kiro-init.md](kiro-init.md) |
| 经 CloudFront 调 API 偶发 504 | 非流式长调用超过 `CloudFrontOriginReadTimeout`；API 请走 GA（`B1`） |
| Pod 重启后账号显示 sign-in required | `AcpProxyPersistence=false`（emptyDir），或切换过持久化；重新 Login 即可 |
