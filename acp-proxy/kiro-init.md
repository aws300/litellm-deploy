# Kiro 初始化：给 acp-proxy 加账号

acp-proxy 本身不带模型额度：每个请求由池里某个 **Kiro 账号**（一个独立 `HOME` 的 `kiro-cli acp` 进程）完成。部署完 Stack 后，至少要加一个账号并登录，`/acp-proxy/v1/messages` 才能用。

本栈用的是 **custom account**（自定义账号）：账号属于你自己的 IAM Identity Center，通过 **device flow** 登录，由人在浏览器里批准一次。acp-proxy 不保存任何密码，只把 Kiro 签发的 token 存在该账号所在 Pod 的 EBS 卷上。

> 另一种 managed 模式（acp-proxy 自己在 Identity Center 里建用户、重置密码、无头登录）需要 chart 的 `config.identityCenter.*` + 一个有 `identitystore:*` / `sso:*` / `sso-admin:*` 权限的 IRSA 角色，本模板不默认开启；需要时用 `helm upgrade --reuse-values` 自行配置。

---

## 1. 准备：Identity Center + Kiro 订阅（每个组织一次）

1. **IAM Identity Center 实例**：[IAM Identity Center 控制台](https://console.aws.amazon.com/singlesignon) → **Enable**（建议组织实例）。记下 **Settings** 里的：
   - **AWS access portal URL**，形如 `https://d-xxxxxxxxxx.awsapps.com/start` → 这就是 **Start URL**
   - Identity Center 所在 **Region**（控制台右上角，如 `us-east-1`）→ 这就是 **Region**
   
   注意：这是 Identity Center 的 Region，与 Stack 部署在哪个 Region 无关。
2. **用户**：**Users** → **Add user**（或从外部 IdP 同步）。建议每个池账号一个专用用户，例如 `kiro-pool-01@yourcorp.com`，设置好密码 / MFA。
3. **订阅 Kiro**：在 AWS 控制台打开 **Kiro** 的订阅管理页，选择这个 Identity Center 实例，把上面的用户（或其所在组）订阅到 Kiro 的付费档位（Pro / Pro+ / Power 等）。具体入口和档位以 Kiro 官方文档为准：<https://kiro.dev/docs/>。
4. **（可选）本地验证该用户可用**，装了 `kiro-cli` 的任意机器上：
   ```bash
   kiro-cli login --license pro \
     --identity-provider https://d-xxxxxxxxxx.awsapps.com/start \
     --region us-east-1 --use-device-flow
   kiro-cli whoami          # 能看到用户与订阅即 OK
   kiro-cli logout          # 本地验证完登出，不影响 acp-proxy
   ```

每个 Kiro 账号同时可以服务多个会话（每账号最多 4 个 kiro 进程），但订阅有各自的用量限额：并发 / 用量大时多加几个账号，acp-proxy 会按会话粘性把新会话分散到不同账号（`accountRateLimit` 可做软限流）。

---

## 2. 在控制台添加并登录（推荐）

1. 打开 Outputs 的 **`B2AcpProxyConsole`**：`https://<cloudfront-domain>/acp-proxy/`，用 Cognito 管理员（`CognitoAdminUsername` / `CognitoAdminPassword`）登录。
2. 左侧 **Accounts** → 添加区：
   - 打开开关 **Custom account — my own Identity Center**
   - **Label / email**：账号的显示名，建议就填 Identity Center 用户名（如 `kiro-pool-01@yourcorp.com`），在池里唯一
   - **Start URL**：`https://d-xxxxxxxxxx.awsapps.com/start`
   - **Region**：Identity Center 的 Region，如 `us-east-1`
   - 点 **Add custom account**
3. 在新出现的那一行点 **Login**。几秒后弹出：
   - 一个**验证链接**（AWS 的 device 授权页）和一个**验证码**
4. 在浏览器里打开该链接（任何电脑/手机都行，不需要能访问集群），确认页面上的验证码与控制台一致 → 用**这个 Kiro 用户**登录 Identity Center → **Allow / 允许**。
5. 回到控制台，该行状态在几秒内变成已登录（控制台每 2.5 秒轮询一次）。首页的 Accounts 统计会 +1。
6. 重复 2–5 添加更多账号。

多副本时不需要关心账号落在哪个 Pod：添加写入共享的 Aurora，**Login** 会被自动转发到该账号的归属 Pod（Valkey 成员表 + rendezvous 哈希）。

---

## 3. 用脚本添加（admin token）

管理 API 在 `/acp-proxy/admin/api/*`，用 Outputs 的 **`B4AcpProxyAdminToken`** 作为 Bearer token。控制台走 CloudFront，脚本走 GA / CloudFront 都可以：

```bash
STACK=cnf-sg
out(){ aws cloudformation describe-stacks --stack-name $STACK --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }
BASE=$(out B1AcpProxyApiBaseUrl)          # https://<ga-dns>/acp-proxy
TOKEN=$(out B4AcpProxyAdminToken)
H=(-H "Authorization: Bearer $TOKEN" -H 'content-type: application/json')

# 1) 添加 custom account（返回 {"id": "...", "username": "..."}）
ID=$(curl -s "${H[@]}" $BASE/admin/api/accounts \
  -d '{"username":"kiro-pool-01@yourcorp.com","startUrl":"https://d-xxxxxxxxxx.awsapps.com/start","region":"us-east-1"}' \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')

# 2) 发起 device flow：返回 {"state":"waiting_approval","url":"https://...","code":"ABCD-EFGH"}
curl -s "${H[@]}" -X POST $BASE/admin/api/accounts/$ID/manual-login

# 3) 浏览器打开 url，用该 Kiro 用户登录并批准；然后轮询直到 state=succeeded
watch -n3 "curl -s -H 'Authorization: Bearer $TOKEN' $BASE/admin/api/accounts/$ID/login-status"

# 4) 查看池
curl -s "${H[@]}" $BASE/admin/api/accounts | python3 -m json.tool | head -40
```

`state` 取值：`starting` → `waiting_approval` → `succeeded` | `failed`。device code 有有效期（约 10 分钟），过期就重新 `manual-login`。

---

## 4. 验证

```bash
KEY=$(out B3AcpProxyApiKey)
curl -sN $BASE/v1/messages -H "x-api-key: $KEY" -H 'content-type: application/json' \
  -d '{"model":"claude-sonnet-5-5","max_tokens":128,"stream":true,"messages":[{"role":"user","content":"ping"}]}'
```

控制台 **Logs** 页能看到这次请求落在哪个账号、哪个会话。也可以用控制台 **Playground**（填 `B3AcpProxyApiKey`）直接试。

---

## 5. 日常：重新登录、删除

- **需要重新登录**：Kiro 的登录有有效期；token 失效时账号被标记为 **sign-in required**（不会被自动无头重登，也不会被踢出池），控制台顶部出现黄色提示。点该行 **Login**，按第 2 节第 3–5 步再批准一次即可。
- **Pod 重启 / 节点替换**：`AcpProxyPersistence=true`（默认）时 token 在 EBS 卷上，Pod 重建后同名 Pod（`acp-proxy-N`）挂回同一卷，**不需要**重新登录。`false` 时每次 Pod 重启都要重新登录。
- **扩缩副本**（`AcpProxyReplicas`）：账号的归属 Pod 会按哈希重新分配，迁移到新 Pod 的账号在那里没有 token，需要重新 **Login** 一次。
- **删除账号**：Accounts 行的删除按钮，或 `curl -X DELETE "${H[@]}" $BASE/admin/api/accounts/$ID`。只从池里移除，不影响 Identity Center 里的用户与订阅。
- **检查单个账号**：`curl -X POST "${H[@]}" $BASE/admin/api/accounts/$ID/check` → `{"healthy":true,"loggedIn":true}`。
