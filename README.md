# CloudNativeFormationLitellm.yaml

一份 CloudFormation 模板，一次点击部署完整的 LiteLLM 云原生栈：VPC(IPv6 双栈) + EKS(Auto Mode, 1.35) + EnvoyGateway + CloudFront + Global Accelerator + Cognito SSO + Aurora Postgres Serverless + ElastiCache Serverless(Valkey) + DynamoDB + LiteLLM Helm。已在 `ap-northeast-2` / `ap-southeast-1` 验证通过。

---

## 前置条件

- AWS 账号 **admin 权限**（模板会创建 IAM Role、VPC、EKS、Lambda、CloudFront 等）
- **Bedrock 已开通模型访问**（跨区推理走 `global.anthropic.*`，`bedrock-mantle` GPT-OSS 走 `us-east-2`）
  - 开通位置：AWS Console → Amazon Bedrock → 左侧 **Model access** → **Modify model access** → 勾选 Claude / GPT-OSS 系列 → **Next / Submit**
- 目标 Region 至少 **3 个 AZ**、EIP 配额 ≥ 3、On-Demand vCPU 配额 ≥ 4、`m8g.xlarge` 可用（模板启动时会预检并直接失败退出）

---

## 一、通过 Console 部署（推荐）

### 步骤 1：先把模板上传到 S3

模板文件 ~188 KB，超过 CloudFormation Console 51 KB 的 inline 上限，必须借助 S3。

1. 进入 [https://console.aws.amazon.com/s3](https://console.aws.amazon.com/s3)
2. 右上角切换到目标 Region（例如 **Asia Pacific (Singapore) ap-southeast-1**）
3. 点 **Create bucket**
   - Bucket name: `cfn-litellm-deploy-<你的账号12位>-ap-southeast-1`（全球唯一即可）
   - Region: 与目标部署 Region 一致
   - 其它保持默认 → **Create bucket**
4. 进入新建的桶 → **Upload** → **Add files** → 选中本地的 `CloudNativeFormationLitellm.yaml` → **Upload**
5. 上传完成后点这个对象，复制它的 **Object URL**（形如 `https://cfn-litellm-deploy-xxx.s3.ap-southeast-1.amazonaws.com/CloudNativeFormationLitellm.yaml`），下一步要用

### 步骤 2：创建 CloudFormation Stack

1. 打开 [https://console.aws.amazon.com/cloudformation](https://console.aws.amazon.com/cloudformation)
2. 右上角确认 Region 是目标 Region
3. 点 **Create stack** → **With new resources (standard)**
4. **Step 1 — Specify template**
   - **Prerequisite - Prepare template**: 选 **Choose an existing template**
   - **Specify template**: 选 **Amazon S3 URL**
   - 粘贴步骤 1 复制的 Object URL
   - 点 **Next**
5. **Step 2 — Specify stack details**
   - **Stack name**: `litellm-sg`（或任意名字）
   - **ProjectName**: `litellm`
   - **EnvironmentId**: `sg`（1-12 位字母数字，用来给资源加后缀）
   - **VpcCidr**: `10.80.0.0/16`（默认，改成不冲突的 `/16` 即可）
   - **EksVersion**: `1.35`
   - **AppRootPath**: `/app`
   - **AdminRoleArn**（可选）: 如果希望某个 IAM Role 自动获得 EKS console 访问权，填它的 ARN；不填也没问题（后面可通过 Access Entry 添加）
   - **Tags**（可选）: JSON 对象，例如 `{"Env":"prod","Team":"platform"}`
   - 点 **Next**
6. **Step 3 — Configure stack options**
   - **Stack failure options**: 选 **Preserve successfully provisioned resources**（等价于 CLI 的 `--on-failure DO_NOTHING`，出错时保留资源便于排查）
   - 其它保持默认 → **Next**
7. **Step 4 — Review**
   - 拉到最底，**Capabilities** 处勾选 **I acknowledge that AWS CloudFormation might create IAM resources with custom names**
   - 点 **Submit**

### 步骤 3：等待创建完成（30-45 分钟）

- Stack 详情页 → **Events** 页签实时看事件
- **Resources** 页签看各资源状态
- 主要耗时：EKS 集群 ~15 min、Aurora ~10 min、CloudFront 分发 ~10 min、Helm 部署 ~5 min
- 状态变成 **CREATE_COMPLETE** 即可

### 步骤 4：拿到访问入口和凭据

Stack 详情页 → **Outputs** 页签，重点看这几项（点右边小图标可以复制）：

| Output Key | 用途 |
|---|---|
| `LiteLLMAdminUI` | `https://<cf-domain>/ui/` — 浏览器打开走 Cognito SSO 登录 |
| `LiteLLMApiServer` | `https://<ga-dns>/` — API 客户端端点（Global Accelerator 双栈） |
| `CognitoAdminUsername` / `CognitoAdminPassword` | 首次 SSO 登录用，**密码只显示一次，立即保存！** |
| `LiteLLMMasterKey` | 只读 master key，只能读统计信息，**不能调模型也不能建 key** |
| `EksClusterName` | 用于 `kubectl` 连接 |
| `AuroraEndpoint` / `ValkeyEndpoint` / `DynamoDBTableName` | 后端数据服务地址 |

---

## 二、首次登录并生成可用的 API Key

Master key 是只读的（详见"安全模型"），要调模型必须先通过 SSO 登录 UI 后生成一个虚拟 key。

1. 浏览器打开 `LiteLLMAdminUI` 的地址
2. 会被跳转到 Cognito 登录页
3. 用户名填 Outputs 里的 `CognitoAdminUsername`（默认 `admin@example.aws`），密码填 `CognitoAdminPassword`
4. 首次登录会要求改密码
5. 登录后进 LiteLLM Dashboard，左侧默认在 **Virtual Keys** 页
6. 点 **+ Create New Key**
   - **Key Name**: 起个名字，例如 `verify-key`
   - **Models**: 留空 = 允许所有模型（也可以点开选特定模型）
   - **Optional Settings** 展开：
     - **Max Budget (USD)**: 例如 `100`（必填，是安全护栏）
     - **Reset Budget**: 选 `monthly`
   - **Create Key**
7. 弹窗显示 `sk-xxxxx...`，**复制并保存**（只显示一次）
8. 用这个 key 就可以调 `LiteLLMApiServer` 的 `/v1/chat/completions`、`/v1/models` 等等

---

## 三、部署后：在 AWS CloudShell 里控制 K8s 集群

CloudShell 已预装 `aws` CLI，只需要装 `kubectl`。

### 步骤 1：打开 CloudShell

1. AWS Console 右上角有一个 **CloudShell 图标**（`>_`），点开
2. 或直接访问 [https://console.aws.amazon.com/cloudshell](https://console.aws.amazon.com/cloudshell)
3. 确认右上角 Region 与部署 Region 一致（例如 ap-southeast-1）

### 步骤 2：下载 kubectl

CloudShell 只保留 `~` 目录持久化，把 kubectl 放到 `~/bin/` 即可长期使用。

```bash
# 下载 EKS 官方 kubectl（1.35 集群装 1.35.x）
curl -sSLO "https://s3.us-west-2.amazonaws.com/amazon-eks/1.35.0/2024-12-12/bin/linux/amd64/kubectl"
chmod +x kubectl
mkdir -p ~/bin
mv kubectl ~/bin/
export PATH=$HOME/bin:$PATH
echo 'export PATH=$HOME/bin:$PATH' >> ~/.bashrc
kubectl version --client
```

### 步骤 3：授权 CloudShell 身份访问集群（如果部署时没填 AdminRoleArn）

CloudShell 使用你当前登录的 IAM 用户/角色身份。默认这个身份**没有**集群访问权，需要一次性授权：

1. 进入 [https://console.aws.amazon.com/eks](https://console.aws.amazon.com/eks) → 选到你的集群（例如 `litellmsg`）
2. **Access** 页签 → **IAM access entries** → **Create access entry**
3. **IAM principal ARN**: 填你在 CloudShell 里的身份 ARN
   - 想快速拿到自己的 ARN：在 CloudShell 里跑 `aws sts get-caller-identity`
   - 若显示是 `arn:aws:sts::.../assumed-role/<RoleName>/<Session>` 形式，实际填的是 `arn:aws:iam::<账号>:role/<RoleName>`
4. **Type**: STANDARD → **Next**
5. **Access policies** → **Add policy**
   - Policy: `AmazonEKSClusterAdminPolicy`
   - Access scope: `Cluster` → **Add policy**
6. **Next** → **Create**

（如果部署时 `AdminRoleArn` 已经填了当前身份，模板已经建好 access entry，可以跳过这一步。）

### 步骤 4：生成 kubeconfig 并连接

回到 CloudShell：

```bash
REGION=ap-southeast-1
CLUSTER=litellmsg          # 就是 Outputs 里的 EksClusterName

aws eks update-kubeconfig --region ${REGION} --name ${CLUSTER}

kubectl get nodes
kubectl get ns
kubectl get pods -A
```

### 步骤 5：常用观测

```bash
# LiteLLM 副本
kubectl -n litellm get pods -o wide
kubectl -n litellm logs -l app.kubernetes.io/name=litellm --tail=100

# EnvoyGateway + NLB
kubectl -n envoy-gateway-system get svc,pods
kubectl get gateway,httproute -A

# Karpenter Auto Mode 节点池
kubectl get nodepool,nodeclass

# LiteLLM 环境变量（确认 SSO/CloudFront 挂对）
kubectl -n litellm exec -it deploy/litellm -- env | grep -E 'PROXY|COGNITO|CLOUDFRONT'
```

---

## 四、注意事项

### 权限相关

- **部署者必须是 admin 或 PowerUser**。模板会创建 IAM Role、VPC、EKS 集群、Lambda、CloudFront、Global Accelerator，任何单一权限缺失都会在半途失败。
- **SCP / Permission Boundary 限制**：如果公司账号被 Service Control Policy 限制了 CloudFront / Global Accelerator / Bedrock 之类的服务，模板会在对应资源上卡住。可以先在 Console 里手动尝试同类操作确认权限是否放开。
- **CloudShell / kubectl 需要单独的 EKS Access Entry**：AWS 控制台 IAM 权限**不等于** EKS 集群访问权限（EKS 用 Access Entry / aws-auth 单独授权）。见"三、步骤 3"。部署时把 `AdminRoleArn` 填成实际会用来管集群的 IAM Role ARN 可以省掉这一步。

### 配额相关

模板启动第一步 `QuotaCheck` Lambda 会跑预检；如果预检失败会直接终止部署并返回缺失项。手动确认清单：

- **EIP** ≥ 3（3 个 NAT Gateway 各占一个）— Service Quotas Console → EC2 → **EC2-VPC Elastic IPs (L-0263D0A3)**
- **VPC per Region** 至少剩 1 — Service Quotas → VPC → **VPCs per Region (L-F678F1CE)**
- **NAT Gateway per AZ** 至少剩 1 每 AZ — Service Quotas → VPC → **NAT gateways per Availability Zone (L-FE5A380F)**
- **Running On-Demand Standard vCPU** ≥ 4 — Service Quotas → EC2 → **Running On-Demand Standard instances (L-1216C47A)**
- **m8g.xlarge 在目标 Region 可用**（大多数主流 Region OK，个别新 Region 需要用其它 arm64 家族替换）

如果配额差得不多（例如 EIP 只差 1 个），Service Quotas Console 里可以直接提交 quota increase request，通常几分钟到几小时批复。

### 打 Tag 的强制要求（重要！）

- **EKS Auto Mode 默认 NodePool 可能"启动失败"，但不影响部署继续**：许多公司账号有 SCP 规定「所有 EC2 必须带某组 tag（例如 `CostCenter`、`Owner`），否则 `RunInstances` 直接拒绝」。EKS Auto Mode 自带一个内置 `default` NodePool + NodeClass，它上面**没有**这些强制 tag，因此在这类账号里默认 NodePool 会长期处于 `NotReady` 或 pod 一直 pending。
- **模板已经对这种情况做了兼容**：不会依赖 `default` NodePool 调度 pod。真正调度用的是模板显式创建、并且带上"部署时通过 `Tags` 参数注入"的 tag 的 5 个自定义 NodePool（`cpu-system` / `cpu` / `cpu-large` / `cpu-general` / `gpu`）+ `default-tags` NodeClass。
- **只要 `default-tags` NodeClass 变成 Ready 就说明部署没问题**：
  ```bash
  kubectl get nodeclass
  # NAME           READY   AGE
  # default        False   ...   ← 忽略，可能永远 False，正常
  # default-tags   True    ...   ← 这个才是我们真正用的
  ```
- **如何在部署时把强制 tag 传进去**：在 Step 2 参数页 `Tags` 字段里填 JSON，例如 `{"CostCenter":"AI-Platform","Owner":"me@company.com","Env":"prod"}`。模板会把它作为 tag 应用到：
  1. 所有由 CloudFormation 直接创建的资源（VPC、EKS、Aurora、Lambda 等）
  2. `default-tags` NodeClass（自动把这些 tag 传给 Karpenter 创建的 EC2 实例）
- **不要用 CloudFormation Console 的 "Advanced options → Tags"** 单独打 tag：这个入口只影响 CFN 直接创建的资源，**不会**传给 Karpenter 生成的 EC2，等于漏掉了真正的计算节点。要用参数里的 `Tags` 字段。

### 部署期间

- **模板 >51 KB 必须走 S3 URL**，Console 不支持粘贴上传本地文件到 CloudFormation 直接使用（会被截断）。
- **`Preserve successfully provisioned resources`** 强烈推荐：出错时保留资源，可以直接进 CloudWatch 看 Lambda / kubectl 日志。改完模板后 **Update stack**，或先 Delete stack 再重建。
- **不要通过 Console `Update stack` 修改 EKS `ComputeConfig` / `NodePools` 字段**：Karpenter Auto Mode 的 NodeClass/NodePool 是通过自定义资源应用的，改这些字段之前先 `kubectl get nodepool` 观察，避免节点池被强制重建。
- **默认 5 个 NodePool**：`cpu-system`、`cpu` (arm64 通用)、`cpu-large` (arm64 大机型，tainted)、`cpu-general` (x86, tainted)、`gpu` (g6e.2xlarge, tainted)。LiteLLM 只用 arm64 `cpu` 池。
- **`g6e.2xlarge` 在 ap-southeast-1 不可用**：只影响 GPU pool，LiteLLM 是纯 CPU 部署，不影响生产。
- **首次部署失败先看 CloudFormation Events 页签**：找 `CREATE_FAILED` 那行的 `Status reason`，90% 的问题是配额 / SCP / IAM 权限、剩下 10% 是 Bedrock 未开通。Custom Resource（`QuotaCheck` / `K8sInfraResources` / `HelmDeploy` 等）失败时同时看对应 Lambda 的 CloudWatch 日志组 `/aws/lambda/<ProjectName><EnvironmentId>-<function>`。

### 已知 Bedrock 限制（非模板问题）

- `claude-fable-5` 在某些账号下会返回 `data retention mode 'default' is not available for this model` — 是 Bedrock **账号级 data retention 策略**，需在 Bedrock 控制台 → **Settings** → **Model invocation logging / data retention** 里调整。
- `bedrock-mantle`（GPT-5.4/5.5）目前只在 `us-east-2` 有服务，模板已固定跨区调用。

### 拆栈

1. 进 [https://console.aws.amazon.com/cloudformation](https://console.aws.amazon.com/cloudformation) → 选中 `litellm-sg`
2. 右上角 **Delete**
3. 弹窗 **Delete stack**
4. 耗时 15-25 分钟

模板已内置 `Custom::K8s*` 资源在删除前清理 NLB / LoadBalancer Service，避免残留 ENI 阻塞 VPC 删除。**LoadBalancerController 卡住 VPC 删除是最常见的删栈失败原因**，本模板已规避。

---

## 五、安全模型

**Master key 是只读的**，通过 LiteLLM `custom_auth` hook 硬编码限制：

- ✅ 可调 `/models`、`/spend/*`、`/global/spend`、`/*/info` 等只读路径
- ❌ `/v1/chat/completions` → 403（不能调模型）
- ❌ `/key/generate` → 403（不能建 key）

调模型和建 key 必须用 **SSO 登录后在 UI 里生成的虚拟 key**。这个设计让 master key 可以放在 CloudFormation Outputs 里，即使泄漏也无法造成损失。

**模型列表**内置在模板里（`LiteLLMDeploy` 资源），部署时通过 Helm `--set` 注入。当前包含：Claude Sonnet 5 / Opus 4.8 / Fable 5、Claude 4.5-4.6 全家族、GPT-5.4 / 5.5（走 `bedrock-mantle` 固定 us-east-2）。

---

## 六、架构速记

- **入口两条路**：
  - CloudFront (`.cloudfront.net`) → 内部 ALB → EnvoyGateway → LiteLLM（浏览器 UI 走这条，SSO 回调也走这条）
  - Global Accelerator (`.awsglobalaccelerator.com`) → 内部 NLB → EnvoyGateway → LiteLLM（API 客户端走这条）
- **认证**：Cognito User Pool → EnvoyGateway `SecurityPolicy` (OIDC) 拦截 `/apis/v1/` 前缀；UI 走 LiteLLM 自己的 SSO
- **存储**：Aurora Postgres（LiteLLM key/spend 元数据）、Valkey（rate limit）、DynamoDB（会话消息）、EFS（可选共享卷）
- **计算**：EKS Auto Mode + Karpenter，纯 arm64 (m8g) 节点，1 min 弹性
- **TLS**：cert-manager + Let's Encrypt（`ClusterIssuer: letsencrypt-gateway`），Gateway 上双证书（GA hostname + Envoy 默认 hostname）
