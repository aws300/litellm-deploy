# LiteLLM 云原生栈 · 控制台（界面化）部署手册

本文对应模板 `litellm/CloudNativeFormationLitellm.yaml`，给出两条部署路线：

| 路线 | 适合场景 | 部署耗时 | 结果 | 卸载 |
|---|---|---|---|---|
| **一、CloudFormation 一键部署** | 生产 / 演示，要完整可用的 LiteLLM | 30–45 分钟 | VPC + EKS + Aurora + Valkey + Cognito + CloudFront + Global Accelerator + EnvoyGateway + LiteLLM 全部就绪 | **一键卸载**：删除 Stack，所有资源按正确顺序自动清理，不留残余 |
| **二、逐项手动创建** | 想理解每个资源、或账号策略不允许 CloudFormation 建 IAM | 1.5–2 小时 | IAM 角色、VPC、EKS、Aurora（及可选的 Valkey / DynamoDB）+ kubectl 连通 + EnvoyGateway 就绪 | **逐个卸载**：必须按依赖倒序手动删除十几类资源，顺序错了会删不掉（见第五部分） |

两条路线都只用 AWS 控制台操作；只有连接 EKS 和部署 EnvoyGateway 的时候需要在 **CloudShell** 里复制粘贴几条 `kubectl` 命令（每条命令都可以原样粘贴，无需改写）。

**IAM 审批**：两条路线涉及的每个 IAM 角色的信任策略、托管策略和内联策略 JSON 都在 **2.1 节**（手动路线会建的 4 个角色）和 **附录 A**（一键部署创建的全部角色清单，含额外的 2 个 Lambda 角色）中完整列出，可在部署前交安全/运维团队审核。

> **选型建议**：除非账号策略禁止，优先用一键部署。它最大的优势除了"一键创建"，还有 **"一键卸载"**——CloudFormation 记录了它创建的每个资源，删除 Stack 时会自动按依赖倒序清理，并先清掉 Kubernetes 动态创建、CloudFormation 本身看不到的 NLB / ALB / 安全组规则。手动创建的资源没有这份记录，卸载时只能靠人逐个找、逐个删。

---

## 〇、通用前置条件

在开始任意一条路线之前，先逐项确认：

1. **权限**：部署者是 `AdministratorAccess`（或同等的 PowerUser + IAM 全权限）。模板/手动流程都会创建 IAM Role、VPC、EKS、Lambda、CloudFront、Global Accelerator。
2. **Region**：只能选下列 Region 之一。模板里 `BedrockConfig` 映射表只列了这 7 个，其它 Region 会在创建时报 `Unable to get mapping for BedrockConfig::<region>` 并直接失败：
   `us-east-1`、`us-west-2`、`ap-southeast-1`、`ap-northeast-1`、`ap-northeast-3`、`eu-west-1`、`eu-central-1`
3. **Bedrock 模型访问**：控制台 → **Amazon Bedrock** → 左侧 **Model access** → **Modify model access** → 勾选 Anthropic Claude 系列、OpenAI GPT-OSS 系列 → **Next** → **Submit**。
4. **配额**（控制台 → **Service Quotas** → **AWS services**）：

   | 服务 | 配额名称 | 代码 | 至少需要 |
   |---|---|---|---|
   | Amazon EC2 | EC2-VPC Elastic IPs | `L-0263D0A3` | 剩余 3 个（3 个 NAT 各占 1 个） |
   | Amazon VPC | VPCs per Region | `L-F678F1CE` | 剩余 1 个 |
   | Amazon VPC | NAT gateways per Availability Zone | `L-FE5A380F` | 每个 AZ 剩余 1 个 |
   | Amazon EC2 | Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances | `L-1216C47A` | ≥ 4 vCPU |

   另外目标 Region 至少要有 **3 个可用区**，且 **`m8g.xlarge`（Graviton）** 可用。配额不够就在 Service Quotas 里点 **Request increase at account level**。
5. **公司 SCP 强制标签**：如果账号要求所有 EC2 必须带某些 tag（如 `CostCenter`、`Owner`），提前准备好这组 tag，后面要用。

---

## 一、CloudFormation 一键部署

### 1.1 准备模板文件

模板约 188 KB，**不能**粘贴到控制台的模板设计器里，但有两种上传方式都可以：

- **方式 A（最简单）**：创建 Stack 时直接选 **Upload a template file** 上传本地文件。控制台会自动把它存进一个名为 `cf-templates-xxxx-<region>` 的 S3 桶（控制台上传上限是 1 MB）。
- **方式 B（便于复用 / 多人共享）**：先手动传到 S3，再用 S3 URL 创建：
  1. 打开 **S3** 控制台，右上角切到目标 Region
  2. **Create bucket** → 桶名如 `cfn-litellm-<账号ID>-<region>` → 其它默认 → **Create bucket**
  3. 进入桶 → **Upload** → **Add files** → 选 `CloudNativeFormationLitellm.yaml` → **Upload**
  4. 点开刚上传的对象，复制 **Object URL**

### 1.2 创建 Stack

1. 打开 **CloudFormation** 控制台，确认右上角 Region 正确
2. **Create stack** → **With new resources (standard)**

**Step 1 — Specify template**

- **Prepare template**：`Choose an existing template`
- **Template source**：方式 A 选 `Upload a template file` → **Choose file**；方式 B 选 `Amazon S3 URL` → 粘贴 Object URL
- **Next**

**Step 2 — Specify stack details**

| 参数 | 建议值 | 说明 |
|---|---|---|
| Stack name | `litellm-sg` | 任意，只用于 CloudFormation 自己 |
| ProjectName | `litellm` | 1–20 位字母数字、字母开头。**建议全小写** |
| EnvironmentId | `sg` | 1–12 位字母数字。**必须全小写**：它会拼进 Cognito 域名前缀 `cnf-<EnvironmentId>-<账号ID>`，Cognito 域名不允许大写 |
| VpcCidr | `10.80.0.0/16` | 必须是 `/16`，且不能和已有 VPC / 对等网络冲突 |
| EksVersion | `1.35` | 可选 1.33 / 1.34 / 1.35 |
| EnvoyGatewayVersion | `v1.7.1` | 保持默认 |
| AppRootPath | `/app` | 保持默认 |
| AdminRoleArn | 你平时登录控制台所用 IAM Role 的 ARN | 可留空。填了之后这个角色自动成为 EKS 集群管理员，省掉 3.3 节的授权步骤 |
| Tags | `{"CostCenter":"AI-Platform","Owner":"me@example.com"}` | JSON 对象，没有强制标签就保持 `{}` |

> **ProjectName + EnvironmentId 决定了几乎所有资源名**，例如 EKS 集群名 `litellmsg`、RDS 集群 `litellmsg-pg`、IAM 角色 `litellmsg-EKSClusterRole`。同一账号同一 Region 里这一组合必须唯一，模板第一步的预检会检查冲突。

> **SCP 强制标签一定要填在 `Tags` 参数里**，不要用下一步 "Configure stack options → Tags"。后者只会打到 CloudFormation 直接创建的资源上，不会传给 EKS Auto Mode（Karpenter）动态拉起的 EC2 节点，节点会被 SCP 拒绝启动。

点 **Next**。

**Step 3 — Configure stack options**

- **Stack failure options**：选 **Preserve successfully provisioned resources**（出错时保留已建资源，方便排查；排查完可以 **Retry** 或删除重建）
- 其它保持默认 → **Next**

**Step 4 — Review and create**

- 拉到页面最底部，勾选 **I acknowledge that AWS CloudFormation might create IAM resources with custom names.**
- **Submit**

### 1.3 观察创建过程

在 Stack 详情页：

- **Events** 页签：实时事件流，出错时看 `CREATE_FAILED` 那一行的 **Status reason**
- **Resources** 页签：每个资源的状态

模板的创建顺序与大致耗时：

| 阶段 | 内容 | 耗时 |
|---|---|---|
| 1. 预检 | `QuotaCheck` Lambda 检查 EIP / VPC / NAT / vCPU 配额、m8g 可用性、同名资源冲突 | ~1 分钟 |
| 2. 网络 | VPC（IPv4 + IPv6 双栈）、3 公有 + 3 私有子网、3 个 NAT Gateway、Egress-only IGW、S3 Gateway Endpoint | ~3 分钟 |
| 3. IAM | EKS 集群角色、节点角色、Lambda 角色、Pod 角色、EFS CSI 角色 | ~1 分钟 |
| 4. EKS | Auto Mode 集群（IPv6）、Access Entry、5 个自定义 NodePool + `default-tags` NodeClass、Add-ons | ~15 分钟 |
| 5. 数据层 | Aurora PostgreSQL Serverless v2、ElastiCache Serverless（Valkey 8）、DynamoDB、EFS | 与 EKS 并行，~10 分钟 |
| 6. 入口 | EnvoyGateway（Helm）、Gateway、内部 NLB、内部 ALB、CloudFront（VPC Origin）、Global Accelerator | ~10 分钟 |
| 7. 认证与应用 | Cognito User Pool + 管理员账号、Let's Encrypt 证书、LiteLLM Helm Chart | ~5 分钟 |

状态变为 **CREATE_COMPLETE** 即完成。

### 1.4 获取访问入口

Stack 详情页 → **Outputs** 页签：

| Output | 用途 |
|---|---|
| `LiteLLMAdminUI` | `https://<xxx>.cloudfront.net/ui/`，浏览器打开，走 Cognito SSO |
| `LiteLLMApiServer` | `https://<xxx>.awsglobalaccelerator.com/`，API 客户端端点 |
| `CognitoAdminUsername` / `CognitoAdminPassword` | 首次 SSO 登录账号（默认 `admin@example.aws`）。**密码请立即保存** |
| `LiteLLMMasterKey` | 只读 master key：只能查统计，不能调模型、不能建 key |
| `EksClusterName` | kubectl 连接用 |
| `AuroraEndpoint` / `ValkeyEndpoint` / `DynamoDBTableName` | 后端数据服务地址 |

> ⚠️ **数据库密码是可推算的**：模板里 Aurora 密码固定为 `<ProjectName><EnvironmentId>Pg2026!`，Valkey 密码为 `<ProjectName><EnvironmentId>Valkey2026!`，并原样出现在 Outputs 中。数据库只开放给集群安全组、不对公网暴露，但仍建议：①限制谁能查看这个 Stack 的 Outputs；②生产环境部署后在 RDS / ElastiCache 控制台修改密码，并同步更新集群内 `litellm` 命名空间的 `postgres-creds` Secret。

### 1.5 首次登录并生成 API Key

1. 打开 `LiteLLMAdminUI`，会跳转到 Cognito 登录页
2. 输入 `CognitoAdminUsername` / `CognitoAdminPassword` 登录
3. 进入 LiteLLM Dashboard → 左侧 **Virtual Keys** → **+ Create New Key**
   - **Key Name**：如 `verify-key`
   - **Models**：留空表示全部模型
   - 展开 **Optional Settings**：**Max Budget (USD)** 填如 `100`，**Reset Budget** 选 `monthly`
   - **Create Key**
4. 复制弹窗中的 `sk-...`（只显示一次），即可调用 `LiteLLMApiServer` 的 `/v1/chat/completions`、`/v1/models`

### 1.6 连接集群

与手动路线相同，见 [第三部分：用 kubectl 控制 EKS](#三用-kubectl-控制-eks)。

### 1.7 常见失败

**常见失败原因**（按出现频率）：

1. 配额不足 → 预检 `QuotaCheck` 直接失败，Status reason 会列出缺哪一项
2. SCP 拒绝（CloudFront / Global Accelerator / 未打强制 tag 的 EC2）
3. EnvironmentId 含大写字母 → Cognito 域名创建失败
4. Region 不在支持列表 → 映射表报错
5. Bedrock 模型未开通 → 部署成功但调用报 `AccessDeniedException`

自定义资源（`QuotaCheck`、`K8sNodePools`、`K8sInfraResources`、`LiteLLMDeploy` 等）失败时，到 **CloudWatch** → **Log groups** 查看 `/aws/lambda/<ProjectName><EnvironmentId>-<函数名>`，如 `/aws/lambda/litellmsg-kubectl`。

**关于 `default` NodeClass 一直 NotReady**：在有强制标签 SCP 的账号里这是正常的。模板不用内置 `default`，而是复制出一个带上你 `Tags` 的 `default-tags` NodeClass，所有自定义 NodePool 都引用它。只要 `default-tags` 为 Ready 即可。

### 1.8 一键卸载

这是一键部署相对手动路线最大的优势之一：**整套环境只需删除一个 Stack**。

1. **CloudFormation** 控制台 → 选中 Stack（如 `litellm-sg`）
2. 右上角 **Delete** → 弹窗中点 **Delete**
3. 等待状态从 `DELETE_IN_PROGRESS` 变为消失（约 15–25 分钟），**Events** 页签可看进度

CloudFormation 会自动完成以下工作，运维无需任何手工步骤：

- 先由模板的自定义资源卸载 EnvoyGateway、删除 Kubernetes 里的 LoadBalancer Service 和 Ingress，使 Auto Mode 回收它动态创建的 **内部 NLB、内部 ALB 及其安全组规则**——这些资源不是 CloudFormation 直接创建的，手动删除时最容易遗漏，遗漏后残留的网卡（ENI）会让 VPC 删不掉
- 再按依赖倒序删除 Global Accelerator、CloudFront、Cognito、LiteLLM、EKS 集群和节点、Aurora、Valkey、DynamoDB、EFS、NAT Gateway、弹性 IP、子网、VPC，最后删除全部 IAM 角色和 Lambda

**删除前请注意**：

- Aurora 数据库、DynamoDB 表、EFS 中的数据会**一并删除且不可恢复**。需要保留时，先在 RDS 控制台对集群 **Actions → Take snapshot**，在 DynamoDB 控制台 **Backups → Create backup**
- 如果删除失败（状态 `DELETE_FAILED`），在 **Events** 页签找到失败的资源和原因，处理后再次点 **Delete**；仍失败时可在弹窗中勾选跳过该资源，然后到对应控制台手动删除它

---

## 二、逐项手动创建

下面按依赖顺序逐个在控制台创建。命名统一用前缀 `litellm-sg`（请替换成自己的）。

```
2.1 IAM 角色 ─┬─> 2.2 VPC ──> 2.3 EKS 集群 ──> 2.4 数据安全组 ──> 2.5 Aurora
              │                    │                         └──> 2.6 Valkey / DynamoDB（可选）
              └────────────────────┴──> 2.7 Pod Identity 关联
                                   └──> 三、kubectl 连接 ──> 四、部署 EnvoyGateway
```

### 2.1 创建 IAM 角色

手动路线需要 3 个必需角色 + 1 个可选角色。每个角色都按同一套控制台步骤创建，只是粘贴的 JSON 和勾选的托管策略不同：

**通用创建步骤**（IAM 控制台 → 左侧 **Roles** → **Create role**）：

1. **Trusted entity type** 选 **Custom trust policy**
2. 清空编辑框里的默认内容，粘贴该角色的 **信任策略 JSON** → **Next**
3. **Add permissions** 页：在搜索框逐个搜索该角色的 **托管策略**，勾选 → **Next**（没有托管策略就直接 **Next**）
4. **Role name** 填该角色的名字 → 拉到底 **Create role**
5. 如果该角色有 **内联策略**：在角色列表点进刚创建的角色 → **Permissions** 页签 → **Add permissions** → **Create inline policy** → 右上角切到 **JSON** → 清空后粘贴内联策略 JSON → **Next** → **Policy name** 填表中的名字 → **Create policy**

JSON 中出现的 `<REGION>`（如 `ap-southeast-1`）和 `<ACCOUNT_ID>`（12 位账号 ID，控制台右上角账号菜单可见）要替换成实际值，其余内容原样粘贴。

| # | 角色名 | 谁来使用 | 必需 |
|---|---|---|---|
| ① | `litellm-sg-EKSClusterRole` | EKS 控制面（含 Auto Mode 拉起节点、创建负载均衡器、挂载 EBS） | 是 |
| ② | `litellm-sg-EKSNodeRole` | Auto Mode 拉起的 EC2 节点 | 是 |
| ③ | `litellm-sg-PodRole` | LiteLLM Pod（调用 Bedrock、读写 DynamoDB） | 是 |
| ④ | `litellm-sg-EfsCsiRole` | EFS CSI 驱动 | 仅装了 EFS CSI 时 |

> 另外 EKS、ElastiCache、RDS 首次使用时会自动创建各自的 **服务关联角色**（如 `AWSServiceRoleForAmazonEKS`），无需手动操作；若公司禁止自动创建服务关联角色，需提前请管理员放行。

#### ① EKS 集群角色 `litellm-sg-EKSClusterRole`

**信任策略**——只允许 EKS 服务扮演。`sts:TagSession` 不能少，Auto Mode 需要用它给拉起的实例打集群标签：

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "eks.amazonaws.com" },
      "Action": ["sts:AssumeRole", "sts:TagSession"]
    }
  ]
}
```

**托管策略**（5 个，全部勾选）：

| 托管策略 | 作用 |
|---|---|
| `AmazonEKSClusterPolicy` | 集群控制面基础权限 |
| `AmazonEKSComputePolicy` | Auto Mode 创建/回收 EC2 节点 |
| `AmazonEKSBlockStoragePolicy` | Auto Mode 内置的 EBS 卷管理 |
| `AmazonEKSLoadBalancingPolicy` | Auto Mode 内置的负载均衡器控制器（创建 NLB/ALB） |
| `AmazonEKSNetworkingPolicy` | Auto Mode 内置的 VPC 网络管理 |

**内联策略** `AllowCustomNodeClassTags`——**仅当**公司 SCP 要求 EC2 必须带标签、需要自定义带标签的 NodeClass 时添加（一键部署模板默认会加）。它只允许在请求里带有本集群标签时创建实例，不会放大权限范围：

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:CreateLaunchTemplate",
        "ec2:CreateFleet",
        "ec2:RunInstances"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:RequestTag/eks:eks-cluster-name": "${aws:PrincipalTag/eks:eks-cluster-name}"
        },
        "StringLike": {
          "aws:RequestTag/eks:kubernetes-node-class-name": "*",
          "aws:RequestTag/eks:kubernetes-node-pool-name": "*"
        }
      }
    }
  ]
}
```

> 注意 `${aws:PrincipalTag/eks:eks-cluster-name}` 是 IAM 策略变量，**原样粘贴，不要替换**。

#### ② EKS 节点角色 `litellm-sg-EKSNodeRole`

**信任策略**——只允许 EC2 实例扮演：

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

**托管策略**（3 个）：

| 托管策略 | 作用 |
|---|---|
| `AmazonEKSWorkerNodeMinimalPolicy` | 节点加入集群所需的最小权限 |
| `AmazonEC2ContainerRegistryPullOnly` | 从 ECR 拉镜像（只读） |
| `AmazonSSMManagedInstanceCore` | 允许用 Session Manager 登录节点排障（不需要可不选） |

**内联策略**：无。

#### ③ 应用 Pod 角色 `litellm-sg-PodRole`

LiteLLM Pod 通过 EKS Pod Identity 获得这个角色的临时凭证，**不需要任何 AK/SK**。

**信任策略**——只允许 EKS Pod Identity 服务扮演：

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "pods.eks.amazonaws.com" },
      "Action": ["sts:AssumeRole", "sts:TagSession"]
    }
  ]
}
```

> 一键部署模板的信任策略里还多一条 IRSA（`sts:AssumeRoleWithWebIdentity`，主体为集群的 OIDC Provider），作为 Pod Identity 之外的备用方式。手动路线只用 Pod Identity，不需要这一条，也就不需要创建 OIDC Provider。

**托管策略**：无。

**内联策略** `LiteLLMPodPolicy`：

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "STSCallerIdentity",
      "Effect": "Allow",
      "Action": "sts:GetCallerIdentity",
      "Resource": "*"
    },
    {
      "Sid": "BedrockInvoke",
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream",
        "bedrock:ListFoundationModels",
        "bedrock:GetFoundationModel",
        "bedrock:ListInferenceProfiles",
        "bedrock:GetInferenceProfile"
      ],
      "Resource": "*"
    },
    {
      "Sid": "BedrockMantleInference",
      "Effect": "Allow",
      "Action": [
        "bedrock-mantle:CreateInference",
        "bedrock-mantle:GetInference",
        "bedrock-mantle:CancelInference",
        "bedrock-mantle:DeleteInference",
        "bedrock-mantle:ListModels",
        "bedrock-mantle:GetModel"
      ],
      "Resource": "*"
    },
    {
      "Sid": "IAMRoleRead",
      "Effect": "Allow",
      "Action": [
        "iam:GetRole",
        "iam:ListAttachedRolePolicies",
        "iam:ListRolePolicies"
      ],
      "Resource": "arn:aws:iam::<ACCOUNT_ID>:role/litellm-sg-PodRole"
    },
    {
      "Sid": "DynamoDBSessionTable",
      "Effect": "Allow",
      "Action": [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:UpdateItem",
        "dynamodb:DeleteItem",
        "dynamodb:Query",
        "dynamodb:BatchWriteItem",
        "dynamodb:BatchGetItem"
      ],
      "Resource": "arn:aws:dynamodb:<REGION>:<ACCOUNT_ID>:table/litellm-sg-sessions*"
    }
  ]
}
```

各段说明：

| Sid | 为什么需要 |
|---|---|
| `STSCallerIdentity` | 排障时在 Pod 里确认拿到的是哪个角色 |
| `BedrockInvoke` | 调用 Claude 等模型（含跨区推理配置文件 `global.anthropic.*`） |
| `BedrockMantleInference` | GPT-5.x 走 OpenAI 兼容的 `bedrock-mantle` 端点，它是**独立的 IAM 服务前缀**，授权动作是 `bedrock-mantle:CreateInference` 而不是 `bedrock:InvokeModel`；漏掉这一段，GPT 模型会返回 403 |
| `IAMRoleRead` | 只读自己这个角色，用于自检；范围限定到本角色 ARN |
| `DynamoDBSessionTable` | 读写会话表；范围限定到 `litellm-sg-sessions` 开头的表 |

> 若不使用 DynamoDB（跳过了 2.6），可删除 `DynamoDBSessionTable` 一段。

#### ④（可选）EFS CSI 角色 `litellm-sg-EfsCsiRole`

仅在 2.3 中勾选了 **Amazon EFS CSI Driver** 时需要。

**信任策略**：与 ③ 完全相同（主体 `pods.eks.amazonaws.com`，动作 `sts:AssumeRole` + `sts:TagSession`）。

**托管策略**：`AmazonEFSCSIDriverPolicy`

**内联策略**：无。

创建后在 EKS 集群 → **Access** → **Pod Identity associations** → **Create**：IAM role 选 `litellm-sg-EfsCsiRole`，命名空间 `kube-system`，Service account `efs-csi-controller-sa`。

### 2.2 创建 VPC（IPv4 + IPv6 双栈）

打开 **VPC** 控制台 → **Create VPC**。

| 设置项 | 值 |
|---|---|
| Resources to create | **VPC and more** |
| Name tag auto-generation | 勾选 Auto-generate，填 `litellm-sg` |
| IPv4 CIDR block | `10.80.0.0/16` |
| IPv6 CIDR block | **Amazon-provided IPv6 CIDR block** |
| Tenancy | Default |
| Number of Availability Zones | **3** |
| Number of public subnets | **3** |
| Number of private subnets | **3** |
| Customize subnets CIDR blocks | 展开，公有子网填 `10.80.0.0/20`、`10.80.16.0/20`、`10.80.32.0/20`；私有子网填 `10.80.128.0/20`、`10.80.144.0/20`、`10.80.160.0/20` |
| NAT gateways | **Zonal → 1 per AZ**（每个可用区一个，单 AZ 故障不影响其它 AZ 出网；想省钱可选 In 1 AZ） |
| Egress only internet gateway | **Yes**（私有子网的 IPv6 出网） |
| VPC endpoints | **S3 Gateway** |
| DNS options | **Enable DNS hostnames** 和 **Enable DNS resolution** 都勾选 |

点 **Create VPC**，等待约 3–5 分钟（NAT Gateway 最慢）。

创建完成后**必须**补做两件事（左侧 **Subnets**）：

1. **给子网打 Kubernetes 负载均衡标签**——EKS 据此决定把 NLB/ALB 放在哪些子网。选中子网 → **Tags** 页签 → **Manage tags** → **Add new tag**：

   | 子网 | Key | Value |
   |---|---|---|
   | 3 个 public 子网 | `kubernetes.io/role/elb` | `1` |
   | 3 个 private 子网 | `kubernetes.io/role/internal-elb` | `1` |

2. **开启私有子网的 IPv6 自动分配**——集群是 IPv6 的，Pod 和节点都依赖它。依次选中 3 个 private 子网 → **Actions** → **Edit subnet settings** → 勾选 **Enable auto-assign IPv6 address** → **Save**。

   （公有子网的 **Enable auto-assign public IPv4 address** 保持不勾选即可，本方案所有负载均衡器都是内部的。）

### 2.3 创建 EKS 集群（Auto Mode + IPv6）

打开 **EKS** 控制台 → **Clusters** → **Create cluster** → 选 **Custom configuration**（不要用 Quick configuration，它不能选 IPv6）→ 保持 **Use EKS Auto Mode** 打开。

**Step 1 — Configure cluster**

| 设置项 | 值 |
|---|---|
| Name | `litellm-sg` |
| Kubernetes version | `1.35` |
| Cluster IAM role | `litellm-sg-EKSClusterRole` |
| Cluster access → Bootstrap cluster administrator access | **Allow**（当前登录身份自动成为集群管理员） |
| Cluster authentication mode | **EKS API** |
| Auto Mode Compute → Node pools | 勾选 **system** 和 **general-purpose** |
| Node IAM role | `litellm-sg-EKSNodeRole` |
| Tags | 有强制标签要求时在此填写 |

**Step 2 — Specify networking**

| 设置项 | 值 |
|---|---|
| VPC | `litellm-sg-vpc` |
| Subnets | **只选 3 个 private 子网** |
| Security groups | 留空（EKS 会自动创建集群安全组） |
| Choose cluster IP address family | **IPv6** |
| Cluster endpoint access | **Public and private** |

> **为什么必须 IPv6**：模板里的 Pod 全部只有 IPv6 地址，这样不会耗尽子网的 IPv4。代价是所有 Envoy/应用容器都要显式监听 IPv6（见第四部分 `ipFamily: IPv6`），否则会出现"容器在跑，但健康检查一直连接拒绝，且日志里什么都没有"的现象。

**Step 3 — Configure observability**

- **Control plane logs**：勾选 **API server**、**Audit**、**Authenticator**

**Step 4 — Select add-ons**

Auto Mode 已内置 VPC CNI、CoreDNS、kube-proxy、EBS CSI 和 AWS Load Balancer Controller，这些**不用**再装。额外勾选：

| Add-on | 用途 |
|---|---|
| **Amazon EKS Pod Identity Agent** | 2.7 节的 Pod 角色要用 |
| **Metrics Server** | HPA 依赖 |
| **cert-manager** | 后续为 Gateway 签发 Let's Encrypt 证书 |
| Amazon EFS CSI Driver（可选） | 需要共享卷时再装 |

**Step 5 — Configure selected add-ons settings**

- 版本保持默认
- 展开 **cert-manager** → **Optional configuration settings** → **Configuration values** 填：
  ```json
  {"extraArgs": ["--enable-gateway-api=true"]}
  ```
  让 cert-manager 能通过 Gateway API 的 HTTPRoute 完成 HTTP-01 验证。

**Step 6 — Review and create** → **Create**。等待 **Status** 变为 **Active**（约 10–15 分钟）。

创建完成后，进入集群 → **Networking** 页签，记下 **Cluster security group**（形如 `sg-0abc...`，名字为 `eks-cluster-sg-litellm-sg-xxxx`），下一步要用。

> **可选：Graviton 专用节点池**。模板没有使用内置 `general-purpose` 池，而是建了一个只用 `m8g`（arm64）实例的 `cpu` 池，并把所有自定义池都指向带强制标签的 `default-tags` NodeClass。如果你的账号有标签 SCP，内置池的节点会被拒绝启动，此时需要照模板 `K8sNodePools` 资源（模板第 1270 行起）用 `kubectl apply` 建同样的 NodeClass/NodePool，并确保 2.1 ① 的内联策略已加上。

### 2.4 创建数据服务安全组

**VPC** 控制台 → **Security groups** → **Create security group**：

| 设置项 | 值 |
|---|---|
| Security group name | `litellm-sg-data-sg` |
| Description | `Aurora and Valkey from EKS` |
| VPC | `litellm-sg-vpc` |

**Inbound rules** → **Add rule**：

| Type | Port | Source |
|---|---|---|
| PostgreSQL | 5432 | Custom → 选 2.3 记下的 **EKS 集群安全组** |
| Custom TCP | 6379 | Custom → 同上（Valkey，不用 Valkey 可不加） |

Outbound 保持默认 → **Create security group**。

> 源用集群安全组而不是 VPC 网段：Auto Mode 节点默认挂的就是这个安全组，这样只有集群内的工作负载能连数据库。

### 2.5 创建 Aurora PostgreSQL Serverless v2

**① 先建 DB 子网组**（否则控制台会把公有子网也放进去）

**RDS** 控制台 → 左侧 **Subnet groups** → **Create DB subnet group**：

- **Name**：`litellm-sg-aurora-subnets`
- **VPC**：`litellm-sg-vpc`
- **Availability Zones**：选 3 个 AZ
- **Subnets**：只选 3 个 **private** 子网（`10.80.128.0/20`、`10.80.144.0/20`、`10.80.160.0/20`）
- **Create**

**② 创建数据库**

**RDS** 控制台 → **Databases** → **Create database**：

| 设置项 | 值 |
|---|---|
| Choose a database creation method | **Full configuration**（Standard create） |
| Engine type | **Aurora (PostgreSQL Compatible)** |
| Engine version | **Aurora PostgreSQL 17.7**（或该 Region 最新的 17.x） |
| Templates | Production（或 Dev/Test） |
| DB cluster identifier | `litellm-sg-pg` |
| Master username | `pgadmin` |
| Credentials management | **Self managed**，填一个强密码并妥善保存（也可选 Managed in AWS Secrets Manager） |
| Cluster storage configuration | Aurora Standard |
| Instance configuration | **Serverless v2**，Minimum capacity **0.5 ACU**，Maximum capacity **2 ACU** |
| Availability & durability | Don't create an Aurora Replica（与模板一致，单实例；生产高可用可选创建副本） |
| Compute resource | Don't connect to an EC2 compute resource |
| Network type | IPv4 |
| VPC | `litellm-sg-vpc` |
| DB subnet group | `litellm-sg-aurora-subnets` |
| Public access | **No** |
| VPC security group | Choose existing → 只保留 `litellm-sg-data-sg`（移除 default） |
| Additional configuration → Initial database name | **`litellm`** |
| Encryption | 保持 **Enable encryption** |

**Create database**，约 10 分钟。完成后点进集群，**Connectivity & security** 页签里的 **Writer endpoint** 就是 LiteLLM 的数据库地址。

> 集群是 IPv6，数据库是 IPv4 也能连：EKS IPv6 集群中，Pod 访问 IPv4 目标时会经节点的 IPv4 地址做 SNAT。

### 2.6 （可选）ElastiCache Valkey 与 DynamoDB

LiteLLM 用 Valkey 做多副本之间的限流/缓存共享，用 DynamoDB 存会话。只装 EnvoyGateway 可跳过本节。

**Valkey Serverless**

1. **ElastiCache** 控制台 → 左侧 **User management** → **Create user**：User ID `litellm-sg-valkey-user`、User name `default`、Engine **Valkey**、Authentication mode **Password**（填强密码）、Access string `on ~* +@all` → **Create**
2. 左侧 **User group management** → **Create user group**：ID `litellm-sg-valkey-ug`、Engine **Valkey**、加入上一步的用户 → **Create**
3. 左侧 **Valkey caches** → **Create Valkey cache** → **Serverless**：
   - Name：`litellm-sg-valkey`
   - Engine version：**8**
   - **Customize default settings** → VPC 选 `litellm-sg-vpc`，Subnets 只选 3 个 private，Security groups 选 `litellm-sg-data-sg`
   - Access control：**User group access control list** → 选 `litellm-sg-valkey-ug`
   - **Create**

**DynamoDB**

**DynamoDB** 控制台 → **Create table**：

- Table name：`litellm-sg-sessions`
- Partition key：`pk`（String）；Sort key：`sk`（String）
- Table settings：**Customize settings** → Capacity mode **On-demand**
- **Create table**；建好后进入表 → **Additional settings** → **Time to Live (TTL)** → **Turn on**，属性名 `ttl`

### 2.7 关联 Pod 角色（Pod Identity）

**EKS** 控制台 → 集群 `litellm-sg` → **Access** 页签 → **Pod Identity associations** → **Create**：

| 设置项 | 值 |
|---|---|
| IAM role | `litellm-sg-PodRole` |
| Kubernetes namespace | `litellm` |
| Kubernetes service account | `litellm-sa` |

**Create**。命名空间和 ServiceAccount 可以之后再建，关联会在它们出现时生效；之后部署 LiteLLM 时让 Pod 使用 `litellm` 命名空间下的 `litellm-sa` 即可自动拿到 Bedrock 权限。

### 2.8 手动路线与模板的差异

手动路线覆盖到"集群 + 网关可用"为止，下列模板资源未包含：

| 模板资源 | 作用 | 手动补齐方式 |
|---|---|---|
| Cognito User Pool / App Client / 管理员用户 | UI 的 SSO 登录 | Cognito 控制台按模板 `CognitoUserPool` / `LiteLLMCognitoClient` 的属性创建 |
| 内部 ALB + CloudFront（VPC Origin） | 浏览器 UI 入口 | 依赖 EnvoyGateway 已运行；参考模板 SECTION 8 |
| Global Accelerator | API 客户端入口，指向 Envoy 的内部 NLB | GA 控制台 → 监听 TCP 80/443 → 端点组选第四部分生成的 NLB |
| LiteLLM Helm Chart | 应用本身 | 见 `litellm/helm-deployment.md` |
| 5 个自定义 NodePool + `default-tags` NodeClass | Graviton 专用池、强制标签 | 见 2.3 末尾说明 |
| EFS + `efs-sc` StorageClass | 共享卷 | 可选 |

---

## 三、用 kubectl 控制 EKS

两条路线通用。推荐在 **AWS CloudShell** 里操作，免装 AWS CLI、免配凭证。

### 3.1 打开 CloudShell

控制台右上角点 **CloudShell** 图标（`>_`），确认右上角 Region 与集群一致。

### 3.2 准备 kubectl

先检查是否已有：

```bash
kubectl version --client
```

如果没有，或版本与集群相差超过 1 个小版本（集群 1.35 时 kubectl 需在 1.34–1.36 之间），下载一个放到 `~/bin`（CloudShell 只有 home 目录是持久化的）：

```bash
mkdir -p ~/bin
curl -L -o ~/bin/kubectl https://dl.k8s.io/release/v1.35.0/bin/linux/amd64/kubectl
chmod +x ~/bin/kubectl
echo 'export PATH=$HOME/bin:$PATH' >> ~/.bashrc && source ~/.bashrc
kubectl version --client
```

> 若 `uname -m` 输出 `aarch64`，把 URL 里的 `amd64` 换成 `arm64`。

### 3.3 授予当前身份集群访问权限

**AWS 控制台的 IAM 权限不等于 EKS 集群权限**，集群内权限由 EKS Access Entry 单独授予。以下情况可以跳过本步：

- 手动路线中创建集群时选了 **Bootstrap cluster administrator access: Allow**，且现在用的是同一个身份
- 一键部署时 `AdminRoleArn` 填的就是当前身份

否则：

1. 在 CloudShell 运行 `aws sts get-caller-identity` 查看当前身份。若返回 `arn:aws:sts::<账号>:assumed-role/<角色名>/<会话名>`，实际要授权的是 `arn:aws:iam::<账号>:role/<角色名>`
2. **EKS** 控制台 → 集群 → **Access** 页签 → **IAM access entries** → **Create access entry**
3. **IAM principal ARN** 填上一步的角色 ARN，**Type** 选 `Standard` → **Next**
4. **Policy name** 选 `AmazonEKSClusterAdminPolicy`，**Access scope** 选 `Cluster` → **Add policy** → **Next** → **Create**

### 3.4 生成 kubeconfig 并验证

```bash
aws eks update-kubeconfig --region ap-southeast-1 --name litellm-sg
```

> 集群名：一键部署看 Outputs 里的 `EksClusterName`（如 `litellmsg`）；手动路线就是你填的 `litellm-sg`。

```bash
kubectl get nodes -o wide        # Auto Mode 按需拉节点，刚建好的空集群可能显示 No resources，属正常
kubectl get ns
kubectl get pods -A
kubectl get nodepool,nodeclass   # Auto Mode 节点池；一键部署时 default-tags 应为 READY=True
```

### 3.5 常用观测命令

```bash
# EnvoyGateway 控制面与数据面
kubectl -n envoy-gateway-system get pods,svc
kubectl get gatewayclass,gateway,httproute -A

# LiteLLM（一键部署才有）
kubectl -n litellm get pods,hpa -o wide
kubectl -n litellm logs deploy/litellm --tail=100

# 节点为什么没拉起来
kubectl get events -A --sort-by=.lastTimestamp | tail -30
```

---

## 四、部署 EnvoyGateway

> 一键部署已经自动完成本节全部内容（Helm release `eg`，命名空间 `envoy-gateway-system`）。本节用于手动路线。

整体分三步：装控制器 → 声明代理参数（IPv6 + 内部 NLB）→ 创建 Gateway。

### 4.1 安装 EnvoyGateway 控制器

在 CloudShell 中执行（版本与模板一致：`v1.7.1`）：

```bash
kubectl apply --server-side \
  -f https://github.com/envoyproxy/gateway/releases/download/v1.7.1/install.yaml

kubectl wait -n envoy-gateway-system deployment/envoy-gateway \
  --for=condition=Available --timeout=5m
```

`install.yaml` 会创建 `envoy-gateway-system` 命名空间、Gateway API CRD、Envoy Gateway CRD 和控制器 Deployment。`--server-side` 是必须的，CRD 体积超过客户端 apply 的注解大小上限。

> 已经有 Helm 的环境也可以用和模板完全相同的方式安装：
> `helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version v1.7.1 -n envoy-gateway-system --create-namespace`

### 4.2 创建 EnvoyProxy、GatewayClass 和 Gateway

在本地电脑新建文件 `eg-gateway.yaml`，内容如下；然后在 CloudShell 右上角 **Actions** → **Upload file** 上传它。

```yaml
# 代理参数：IPv6 监听 + 内部双栈 NLB
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: custom-proxy-config
  namespace: envoy-gateway-system
spec:
  # IPv6 集群必须设置：不设时 Envoy 只监听 0.0.0.0，
  # kubelet 用 IPv6 探活会一直 ECONNREFUSED，且任何日志都看不到原因。
  ipFamily: IPv6
  logging:
    level:
      default: warn
  provider:
    type: Kubernetes
    kubernetes:
      envoyDeployment:
        container:
          resources:
            requests: { cpu: 200m, memory: 512Mi }
            limits:   { cpu: "2", memory: 1Gi }
        strategy:
          type: RollingUpdate
          rollingUpdate: { maxUnavailable: 0, maxSurge: 1 }
      envoyHpa:
        minReplicas: 2
        maxReplicas: 50
        # 只按 CPU 扩缩：网关的内存是常驻基线，与负载无关，
        # 用内存做指标会让副本数长期卡在 maxReplicas。
        metrics:
          - type: Resource
            resource:
              name: cpu
              target: { type: Utilization, averageUtilization: 60 }
      envoyService:
        type: LoadBalancer
        externalTrafficPolicy: Local
        annotations:
          # 内部 NLB：没有公网 IP，外部流量只能经 CloudFront / Global Accelerator 进入
          service.beta.kubernetes.io/aws-load-balancer-scheme: internal
          # Pod 只有 IPv6，目标组必须是 IP 模式 + 双栈
          service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
          service.beta.kubernetes.io/aws-load-balancer-ip-address-type: dualstack
          service.beta.kubernetes.io/aws-load-balancer-enable-prefix-for-ipv6-source-nat: "on"
          service.beta.kubernetes.io/aws-load-balancer-attributes: load_balancing.cross_zone.enabled=true
          service.beta.kubernetes.io/aws-load-balancer-healthcheck-port: "10080"
---
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
  parametersRef:
    group: gateway.envoyproxy.io
    kind: EnvoyProxy
    name: custom-proxy-config
    namespace: envoy-gateway-system
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: eg
  namespace: envoy-gateway-system
spec:
  gatewayClassName: eg
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: All      # 允许任意命名空间的 HTTPRoute 挂到这个 Gateway 上
```

应用：

```bash
kubectl apply -f eg-gateway.yaml
```

> 这里先只开 HTTP 80。模板还给 Gateway 加了 HTTPS 443 监听，证书由 cert-manager 通过 Let's Encrypt 为 Global Accelerator 域名签发（模板中的 `ClusterIssuer letsencrypt-gateway` 与 `GAHttpsSetup` 资源），在 Global Accelerator 建好后再按需添加。

### 4.3 验证

```bash
kubectl get gatewayclass eg                    # ACCEPTED = True
kubectl -n envoy-gateway-system get gateway eg # PROGRAMMED = True，ADDRESS 为 NLB 域名
kubectl -n envoy-gateway-system get pods       # envoy-gateway 控制器 + 2 个 envoy-envoy-gateway-system-eg-xxx 代理
kubectl -n envoy-gateway-system get svc        # 代理 Service 的 EXTERNAL-IP 为 internal-...elb.amazonaws.com
```

到 **EC2** 控制台 → **Load Balancers**，应能看到一个 **Scheme = Internal**、**IP address type = Dualstack** 的 Network Load Balancer，其目标组中的目标为 Envoy Pod 的 IPv6 地址且状态 **Healthy**（NLB 首次注册目标约需 2–3 分钟）。

从集群内部发一个请求确认 Envoy 在监听（还没有任何路由，返回 `404` 即说明正常）。先在上面 `get svc` 的输出里找到名字以 `envoy-envoy-gateway-system-eg-` 开头的那个 Service，把下面命令中的 `<代理Service名>` 替换成它，再整条粘贴：

```bash
kubectl run curl-test --rm -it --restart=Never --image=curlimages/curl -- curl -s -o /dev/null -w '%{http_code}\n' http://<代理Service名>.envoy-gateway-system.svc.cluster.local/
```

### 4.4 把应用挂到网关上

之后任何应用只需在自己的命名空间里创建 HTTPRoute，`parentRefs` **指向 `envoy-gateway-system` 命名空间里的 `eg`**：

```yaml
parentRefs:
  - name: eg
    namespace: envoy-gateway-system
```

不要写成应用自己的命名空间——那样路由不会挂到网关上（`kubectl get httproute` 的 `Accepted` 条件为 False），所有请求都会失败。应用 Chart 也不应再自建 Gateway 或 LoadBalancer Service，全部复用这一个网关和 NLB。

LiteLLM 本身的 Helm 部署、HTTPRoute、超时策略等后续步骤见 [`../helm-deployment.md`](../helm-deployment.md)。

---

## 五、手动路线的卸载（逐个删除）

手动创建的资源没有 CloudFormation 那样的统一记录，**只能按依赖倒序逐个删除**。顺序很重要：被别的资源引用的东西删不掉（例如还有网卡在用的子网、还被数据库引用的安全组）。请按下表从上到下执行，每一步确认删除完成再做下一步。

| 步骤 | 位置 | 操作 | 说明 |
|---|---|---|---|
| 1 | CloudShell | `kubectl delete -f eg-gateway.yaml` | **必须最先做**。删除 Gateway 会让 Auto Mode 回收它创建的内部 NLB；若直接删集群，NLB 和它的网卡会残留，第 9 步删 VPC 时卡住 |
| 2 | EC2 → **Load Balancers** | 确认第 1 步的 NLB 已消失（约 2–5 分钟）；若还在，手动选中 → **Actions → Delete load balancer** | 名字通常以 `k8s-envoyga` 开头 |
| 3 | CloudShell（可选） | `kubectl delete -f https://github.com/envoyproxy/gateway/releases/download/v1.7.1/install.yaml` | 卸载 EnvoyGateway 控制器；马上要删集群的话可跳过 |
| 4 | EKS → 集群 → **Access** → **Pod Identity associations** | 逐个选中 → **Delete** | — |
| 5 | EKS → **Clusters** | 选中集群 → **Delete** → 输入集群名确认 | 约 10 分钟。Auto Mode 拉起的 EC2 节点会随集群自动终止，到 EC2 → **Instances** 确认无残留 |
| 6 | RDS → **Databases** | 先删实例（选中 writer 实例 → **Actions → Delete**），再删集群；按提示选择是否保留最终快照 | 若开启了删除保护，先 **Modify** 关闭 **Deletion protection** |
| 7 | RDS → **Subnet groups** | 删除 `litellm-sg-aurora-subnets` | 须在第 6 步完全删除后 |
| 8 | ElastiCache / DynamoDB（若创建了） | ① **Valkey caches** 删除 `litellm-sg-valkey`；② 待其删除完，**User group management** 删用户组；③ **User management** 删用户；④ DynamoDB → **Tables** 删 `litellm-sg-sessions` | 用户组在缓存删完前删不掉 |
| 9 | EFS（若创建了） | 删除文件系统 | — |
| 10 | VPC → **Security groups** | 删除 `litellm-sg-data-sg`；若还有名字含 `k8s` 或 `eks-cluster-sg-litellm-sg` 的残留安全组也一并删除 | 提示"被引用"时说明上面某一步还没删干净 |
| 11 | VPC → **Your VPCs** | 选中 `litellm-sg-vpc` → **Actions → Delete VPC** | 控制台会连带删除子网、路由表、IGW、Egress-only IGW、S3 Endpoint 和 NAT Gateway |
| 12 | EC2 → **Elastic IPs** | 选中原 NAT 用的 3 个弹性 IP → **Actions → Release Elastic IP addresses** | NAT Gateway 删除后 EIP **不会**自动释放，不释放会持续计费 |
| 13 | IAM → **Roles** | 删除 `litellm-sg-PodRole`、`litellm-sg-EfsCsiRole`、`litellm-sg-EKSNodeRole`、`litellm-sg-EKSClusterRole` | 必须在集群删除后，否则集群会失去权限而卡在删除中 |
| 14 | CloudWatch → **Log groups** | 删除 `/aws/eks/litellm-sg/cluster` | 控制面日志组不会随集群删除 |

> 常见卡点：第 11 步删 VPC 报 "has dependencies"——到 EC2 → **Network Interfaces**，按 VPC 筛选，找到仍处于 in-use 的网卡，看它的 **Description** 判断是哪个服务留下的（通常是第 2 步的 NLB 或第 6 步的数据库），回到对应步骤删干净即可。

---

## 附录 A：CloudFormation 一键部署创建的全部 IAM 角色

一键部署共创建 6 个 IAM 角色，角色名中的 `<P><E>` 代表 `ProjectName` + `EnvironmentId`（如 `litellmsg`）。供部署前安全/运维审核；删除 Stack 时全部自动删除。

| 角色名 | 使用者 | JSON 详见 |
|---|---|---|
| `<P><E>-EKSClusterRole` | EKS 控制面 | 2.1 ①（含内联策略 `AllowCustomNodeClassTags`） |
| `<P><E>-EKSNodeRole` | EKS 节点 | 2.1 ② |
| `<P><E>-PodRole` | LiteLLM Pod | 2.1 ③（信任策略额外多一条 IRSA，见下文） |
| `<P><E>-EfsCsiRole` | EFS CSI 驱动 | 2.1 ④ |
| `<P><E>-KubectlLambdaRole` | 部署期间操作集群的 Lambda（装 EnvoyGateway / Helm、建 Cognito 用户、查 NLB/ALB） | 下文 A.2 |
| 系统自动命名（`<StackName>-QuotaCheckRole-xxxx`） | 部署前预检配额、创建 EFS 挂载点的 Lambda | 下文 A.1 |

`<P><E>-PodRole` 在一键部署中的信任策略（比手动路线多第二条，允许通过集群 OIDC Provider 以 IRSA 方式扮演）：

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "pods.eks.amazonaws.com" },
      "Action": ["sts:AssumeRole", "sts:TagSession"]
    },
    {
      "Effect": "Allow",
      "Principal": { "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/oidc.eks.<REGION>.amazonaws.com/id/<集群OIDC_ID>" },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": { "oidc.eks.<REGION>.amazonaws.com/id/<集群OIDC_ID>:aud": "sts.amazonaws.com" }
      }
    }
  ]
}
```

### A.1 预检 Lambda 角色（QuotaCheckRole）

**信任策略**：

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "lambda.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

**托管策略**：`AWSLambdaBasicExecutionRole`（写 CloudWatch 日志）

**内联策略** `QuotaCheckPolicy`——除 EFS 挂载点和网卡操作外全部是只读查询：

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeAddresses",
        "ec2:DescribeAccountAttributes",
        "ec2:DescribeAvailabilityZones",
        "ec2:DescribeVpcs",
        "ec2:DescribeNatGateways",
        "ec2:DescribeSubnets",
        "ec2:DescribeInstanceTypeOfferings",
        "eks:DescribeCluster",
        "iam:GetRole",
        "lambda:GetFunction",
        "cognito-idp:DescribeUserPoolDomain",
        "sts:GetCallerIdentity",
        "servicequotas:GetServiceQuota",
        "elasticfilesystem:CreateMountTarget",
        "elasticfilesystem:DeleteMountTarget",
        "elasticfilesystem:DescribeMountTargets",
        "elasticfilesystem:DescribeFileSystems",
        "ec2:CreateNetworkInterface",
        "ec2:DescribeNetworkInterfaces",
        "ec2:DescribeNetworkInterfaceAttribute",
        "ec2:DeleteNetworkInterface",
        "ec2:ModifyNetworkInterfaceAttribute",
        "ec2:DescribeSecurityGroups"
      ],
      "Resource": "*"
    }
  ]
}
```

> 网卡相关权限是因为 EFS `CreateMountTarget` 会以调用者身份在子网里创建网卡。

### A.2 集群操作 Lambda 角色（`<P><E>-KubectlLambdaRole`）

该角色同时被 EKS 授予了 **集群管理员**（Access Entry + `AmazonEKSClusterAdminPolicy`），用于部署期间向集群下发 Kubernetes 资源；Cognito 的 Pre Token Generation 触发器 Lambda 也使用这个角色。

**信任策略**：与 A.1 相同（主体 `lambda.amazonaws.com`）。

**托管策略**：`AWSLambdaVPCAccessExecutionRole`（Lambda 运行在 VPC 内，需要创建网卡和写日志）

**内联策略** `EksAndSts`：

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "eks:DescribeCluster",
        "eks:ListClusters",
        "eks:ListAddons",
        "eks:DescribeAddon"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": "sts:GetCallerIdentity",
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "elasticloadbalancing:DescribeLoadBalancers",
        "elasticloadbalancing:DescribeListeners",
        "elasticloadbalancing:DescribeTargetHealth",
        "elasticloadbalancing:DescribeTargetGroups"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeSecurityGroups",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:RevokeSecurityGroupIngress"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "cognito-idp:DescribeUserPool",
        "cognito-idp:DescribeUserPoolClient",
        "cognito-idp:UpdateUserPoolClient",
        "cognito-idp:UpdateUserPool",
        "cognito-idp:AdminCreateUser",
        "cognito-idp:AdminSetUserPassword",
        "cognito-idp:AdminAddUserToGroup"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:*:*:*"
    },
    {
      "Effect": "Allow",
      "Action": "lambda:InvokeFunction",
      "Resource": "arn:aws:lambda:<REGION>:<ACCOUNT_ID>:function:<P><E>-*"
    },
    {
      "Effect": "Allow",
      "Action": "cloudformation:DescribeStackEvents",
      "Resource": "*"
    }
  ]
}
```

| 权限段 | 为什么需要 |
|---|---|
| `eks:*`（只读） | 获取集群地址和证书，等待 Add-on 就绪 |
| `elasticloadbalancing:Describe*` | 查找 Auto Mode 为 Gateway / Ingress 创建的 NLB、ALB，交给 Global Accelerator 和 CloudFront 使用 |
| `ec2:Authorize/RevokeSecurityGroupIngress` | 把 CloudFront VPC Origin 的托管安全组加入内部 ALB 安全组的入站规则（删除时撤销） |
| `cognito-idp:*` | 创建管理员用户、设置密码、写入 App Client 回调地址、挂 Pre Token 触发器 |
| `lambda:InvokeFunction` | 仅限本 Stack 自己的 Lambda（`<P><E>-` 前缀）互相调用 |
| `cloudformation:DescribeStackEvents` | 失败时把 Stack 事件写进日志便于排查 |

