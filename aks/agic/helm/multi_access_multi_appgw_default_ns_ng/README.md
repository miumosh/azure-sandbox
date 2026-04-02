# multi_access_multi_appgw — Ingress の Private / Public 二系統構成検証

Ingress 経由の Private 接続 (オンプレ想定) と Public 接続 (顧客想定) を、それぞれ専用の WAF_v2 AppGW で受けて AKS の同一アプリにルーティングする構成。

- **Private Ingress**: Hub VNet の VM → VNet Peering → Private AppGW (10.2.1.10) → Pod
- **Public Ingress**: インターネット → Public AppGW (Public IP) → Pod
- **AKS Egress**: デフォルト LB を使わず Azure Firewall (Basic SKU) 経由

両 AppGW とも Spoke VNet に配置し、AKS と同一 VNet 内で Pod へルーティングする。

---

## アーキテクチャ

```
                  Internet
                     │
  ┌─── Spoke VNet (10.2.0.0/16) ─────────────────────────┐
  │           ┌──────┴───────┐                           │
  │           │ Public AppGW │ (WAF_v2)     ← Public     │
  │           │  Public IP   │               Ingress     │
  │           └──────┬───────┘                           │
  │                  │                                   │
  │  ┌───────────────┼───────────────┐                   │
  │  │          AKS Cluster          │                   │
  │  │  (CNI Overlay / Pod CIDR      │                   │
  │  │   192.168.0.0/16)             │                   │
  │  └───────────────┬───────────────┘                   │
  │                  │                                   │
  │  ┌───────────────┼──────────┐                        │
  │  │ Private AppGW (WAF_v2)   │         ← Private      │
  │  │ Private IP: 10.2.1.10    │          Ingress       │
  │  └───────────────┬──────────┘                        │
  └──────────────────┼───────────────────────────────────┘
                     │ VNet Peering
  ┌─── Hub VNet (10.1.0.0/16) ───────────────────────────┐
  │                  │                                   │
  │  ┌───────────────┼──────────┐  ┌──────────────────┐  │
  │  │   Test VM (10.1.1.x)     │  │  Azure Firewall  │  │
  │  │   オンプレ想定            │  │  (Basic SKU)     │  │
  │  └──────────────────────────┘  │  AKS Egress用    │  │
  │                                └──────────────────┘  │
  └──────────────────────────────────────────────────────┘
```

---

## ディレクトリ構成

```
multi_access_multi_appgw/
├── terraform/                       # ★ 作業ディレクトリ
│   ├── versions.tf                  # azurerm ~> 4.14
│   ├── variables.tf
│   ├── terraform.tfvars
│   ├── rg.tf                        # Resource Group
│   ├── nw.tf                        # Hub VNet + Spoke VNet + Peering
│   ├── sg.tf                        # NSG (AKS / AppGW Private / AppGW Public / VM)
│   ├── firewall.tf                  # Azure Firewall Basic + Policy + Rules
│   ├── rt.tf                        # Route Table (AKS → Firewall)
│   ├── appgw_private.tf             # Private Ingress 用 AppGW (WAF_v2)
│   ├── appgw_public.tf              # Public Ingress 用 AppGW (WAF_v2)
│   ├── aks.tf                       # AKS (CNI Overlay / UDR Egress)
│   ├── identity.tf                  # AGIC MI x2 + Federated Credential x2
│   ├── role.tf                      # RBAC Role Assignments
│   ├── vm.tf                        # Test VM (Hub VNet)
│   └── outputs.tf
├── helm/
│   ├── agic-private/
│   │   └── agic-values.yaml         # Private Ingress 用 AGIC
│   ├── agic-public/
│   │   └── agic-values.yaml         # Public Ingress 用 AGIC
│   ├── app/
│   │   └── echoserver/
│   │       └── app.yaml             # echoserver Deployment + ClusterIP Service
│   └── ingress/
│       ├── ingress-private.yaml     # Private Ingress (host: private.internal)
│       └── ingress-public.yaml      # Public Ingress (host: public.example.com)
├── README.md
└── commands.md
```

---

## 前提条件

| ツール | バージョン |
|---|---|
| Terraform | >= 1.5.0 |
| Azure CLI (`az`) | 最新 |
| kubectl | 最新 |
| Helm | >= 3.x |

```bash
az login
az account set --subscription <SUBSCRIPTION_ID>
```

---

## ネットワーク構成

| リソース | CIDR / IP |
|---|---|
| Hub VNet | `10.1.0.0/16` |
| AzureFirewallSubnet | `10.1.0.0/26` |
| AzureFirewallManagementSubnet | `10.1.0.64/26` |
| vm-subnet | `10.1.1.0/24` |
| Spoke VNet | `10.2.0.0/16` |
| appgw-private-subnet | `10.2.1.0/24` |
| appgw-public-subnet | `10.2.2.0/24` |
| aks-subnet | `10.2.3.0/24` |
| Private Ingress AppGW IP | `10.2.1.10` |
| Pod CIDR (CNI Overlay) | `192.168.0.0/16` |
| Service CIDR | `10.100.0.0/16` |

---

## Ingress の Private / Public 分離方式

AGIC を 2 インスタンスデプロイし、`ingressClass` で処理対象を分離する。

| Ingress | ingressClass | AppGW | アクセス元 |
|---|---|---|---|
| Private Ingress | `azure/application-gateway-private` | multi-appgw-private (Private IP) | Hub VNet VM (オンプレ想定) |
| Public Ingress | `azure/application-gateway-public` | multi-appgw-public (Public IP) | インターネット (顧客想定) |

### WAF Policy の紐付け方式

本構成では AppGW が 2 つあるため、WAF Policy は各 AppGW の `firewall_policy_id` に直接紐付ける（Terraform の `appgw_private.tf` / `appgw_public.tf` で設定）。Ingress の `waf-policy-for-path` アノテーションは使用しない。

| 方式 | 紐付け先 | 設定箇所 |
|---|---|---|
| **本構成 (2 AppGW)** | AppGW リソースの `firewall_policy_id` | Terraform (`appgw_*.tf`) |
| 単一 AppGW 構成 | Ingress アノテーション `waf-policy-for-path` | Kubernetes Ingress YAML |

2 AppGW 構成では WAF Policy が AppGW 単位で完全に分離されるため、よりシンプルかつ確実な WAF 分離となる。

---

## コスト概算

| リソース | 概算コスト |
|---|---|
| Azure Firewall Basic | ~$0.10/hr |
| AppGW WAF_v2 x2 | ~$0.36/hr x2 = $0.72/hr |
| AKS (Standard_B2ms x1) | ~$0.08/hr |
| Public IP x4 | ~$0.02/hr |
| VM (Standard_B1s) | ~$0.01/hr |
| **合計** | **~$0.93/hr (~$670/月)** |

> **重要**: 使わない時は必ず `terraform destroy` すること。

---

## デプロイ手順

作業ディレクトリは `terraform/` を起点とする。

### 1. terraform.tfvars を設定

```bash
vi terraform/terraform.tfvars
```

```hcl
subscription_id   = "xxx"          # az account show --query id -o tsv
my_public_ip      = "x.x.x.x/32"  # curl ifconfig.me
vm_admin_username = "azureuser"
vm_admin_password = "xxx"
```

### 2. Terraform でインフラ構築

```bash
cd terraform
terraform init
terraform plan
terraform apply

# 依存関係グラフを出力（オプション）
terraform graph | dot -Tpng > dependency_graph.png
```

### 3. kubectl コンテキスト設定

```bash
$(terraform output -raw aks_get_credentials_cmd)
kubectl get nodes
```

### 4. AGIC を Helm でインストール (Private / Public 各1つ)

```bash
# Private Ingress 用 AGIC
helm install agic-private \
  oci://mcr.microsoft.com/azure-application-gateway/charts/ingress-azure \
  --version 1.9.1 \
  --namespace kube-system \
  --set appgw.subscriptionId=$(terraform output -raw subscription_id) \
  --set armAuth.identityClientID=$(terraform output -raw agic_private_identity_client_id) \
  -f ../helm/agic-private/agic-values.yaml

# Public Ingress 用 AGIC
helm install agic-public \
  oci://mcr.microsoft.com/azure-application-gateway/charts/ingress-azure \
  --version 1.9.1 \
  --namespace kube-system \
  --set appgw.subscriptionId=$(terraform output -raw subscription_id) \
  --set armAuth.identityClientID=$(terraform output -raw agic_public_identity_client_id) \
  -f ../helm/agic-public/agic-values.yaml
```

```bash
# AGIC Pod 確認 (2 Pod が Running であること)
kubectl get pod -n kube-system -l app=ingress-azure
```

### 5. アプリと Ingress をデプロイ

```bash
kubectl apply -f ../helm/app/echoserver/app.yaml
kubectl apply -f ../helm/ingress/ingress-private.yaml
kubectl apply -f ../helm/ingress/ingress-public.yaml
kubectl get ingress -w
# Private Ingress: ADDRESS = 10.2.1.10
# Public Ingress:  ADDRESS = AppGW の Public IP
```

### 6. 疎通確認

#### Private Ingress の確認 (VM → Private AppGW)

```bash
ssh azureuser@$(terraform output -raw test_vm_public_ip)

# VM 内で実行
curl -s -o /dev/null -w "%{http_code}\n" http://10.2.1.10/ -H "Host: private.internal"
# → 200
```

#### Public Ingress の確認 (ローカル PC → Public AppGW)

```bash
APPGW_PUBLIC_IP=$(terraform output -raw appgw_public_ip)
curl -s -o /dev/null -w "%{http_code}\n" http://${APPGW_PUBLIC_IP}/ -H "Host: public.example.com"
# → 200
```

---

## トラブルシューティング

### AppGW が Stopped 状態

```bash
# 状態確認
az network application-gateway show \
  --name multi-appgw-private -g multi-appgw-rg --query "operationalState" -o tsv
az network application-gateway show \
  --name multi-appgw-public -g multi-appgw-rg --query "operationalState" -o tsv

# 起動
az network application-gateway start --name multi-appgw-private -g multi-appgw-rg
az network application-gateway start --name multi-appgw-public -g multi-appgw-rg

# AGIC 再起動
kubectl rollout restart deployment -n kube-system -l app=ingress-azure
```

### AKS ノードが NotReady (Firewall ブロック)

Firewall ルールで AKS Egress がブロックされている可能性。`firewall.tf` のルールを確認し、必要なポート/FQDN を追加する。

### グローバル IP が変わって SSH 不可

```bash
# terraform.tfvars の my_public_ip を手動更新後:
terraform apply -target=azurerm_network_security_rule.vm_allow_ssh
```

### Workload Identity 確認

```bash
kubectl get sa -n kube-system agic-private-sa-ingress-azure -o yaml
kubectl get sa -n kube-system agic-public-sa-ingress-azure -o yaml
# azure.workload.identity/client-id が terraform output の値と一致すること
```

### AGIC ログ確認

```bash
kubectl logs -n kube-system -l app=ingress-azure,release=agic-private --tail=50
kubectl logs -n kube-system -l app=ingress-azure,release=agic-public --tail=50
```

---

## 既知の問題: 本構成は動作しない

**本構成 (AppGW x2 + AGIC x2) は AGIC の重複インストールに起因するエラーが発生し、動作しません。**

### 本構成で発生したエラー

同一 AKS クラスタに AGIC Helm chart を 2 つインストール (agic-private / agic-public) すると、以下の競合が発生する:

- IngressClass リソース `azure-application-gateway` の重複 (agic-public 側で `ingressClassResource.enabled: false` としても、CRD やリソース定義レベルで競合が起きうる)
- AGIC が管理する Kubernetes リソース (ConfigMap、RBAC 等) の競合
- 同一 namespace (kube-system) 内での AGIC コントローラ間の干渉

AGIC Helm chart は同一クラスタへの複数インスタンスデプロイを公式にはサポートしておらず、この構成ではエラーとなる。

### AGIC の設計制約

AGIC には以下の根本的な制約がある:

1. **AGIC と AppGW は 1:1 の関係**: `agic-values.yaml` の `appgw.name` に指定できる AppGW は 1 つだけ。1 つの AGIC が複数の AppGW を管理することはできない
2. **同一クラスタに AGIC の複数インスタンスは非サポート**: Helm chart を複数回インストールすると、IngressClass・ConfigMap・RBAC 等のリソースが競合する

これらの制約により、「AppGW を 2 つ使いたいが AGIC の重複エラーだけ回避したい」という要件は AGIC の設計上実現できない。

### 検討した構成パターンと結果

Private (オンプレ想定) / Public (顧客想定) の二系統アクセスを実現するために、以下の構成パターンを検討した。

| # | 構成パターン | AppGW | AGIC | Ingress | 実現可否 | 断念理由 / エラー内容 |
|---|---|---|---|---|---|---|
| 1 | **本構成** | 2 (Private + Public) | 2 (agic-private + agic-public) | 2 | **不可** | AGIC Helm chart の重複インストールで IngressClass・ConfigMap・RBAC が競合。AGIC Pod が正常起動しない、または一方の AGIC が他方の設定を上書きする |
| 2 | AppGW x2 + AGIC x1 | 2 (Private + Public) | 1 | 2 | **不可** | AGIC は AppGW と 1:1 マッピング。`appgw.name` に指定できる AppGW は 1 つだけであり、1 つの AGIC インスタンスが 2 つの AppGW を同時に管理する仕組みが存在しない |
| 3 | **AppGW x1 + AGIC x1 (推奨)** | 1 (Private + Public Frontend) | 1 | 2 | **可能** | AppGW WAF_v2 は Private Frontend IP と Public Frontend IP を同時に保持可能。Ingress アノテーション `use-private-ip` で振り分け |

**構成パターン 1 (本構成) の具体的なエラー:**
- 2 つ目の AGIC Helm install 時に IngressClass リソースの競合が発生
- `ingressClassResource.enabled: false` で IngressClass 作成を抑制しても、ConfigMap や ClusterRole 等の Kubernetes リソースが同名で衝突
- 両方の AGIC Pod が Running になっても、互いの AppGW 設定を上書きし合い正常動作しない

**構成パターン 2 が不可能な理由:**
```yaml
# agic-values.yaml — appgw.name は1つしか指定できない
appgw:
  name: "single-appgw-name"  # ← 2つの AppGW を指定する手段がない
```

### 推奨構成: 単一 AppGW + 単一 AGIC + Ingress x2

構成パターン 3 を推奨する。AppGW WAF_v2 は Private Frontend IP と Public Frontend IP を同時に持てるため、1 つの AppGW + 1 つの AGIC で Private/Public の二系統アクセスを実現できる。

```
                  Internet
                     │
  ┌─── Spoke VNet ───┼───────────────────────────────────────┐
  │           ┌──────┴──────┐                                │
  │           │   AppGW     │ (WAF_v2)                       │
  │           │ Public IP   │ ← Public Ingress               │
  │           │ Private IP  │ ← Private Ingress              │
  │           │ (10.2.1.10) │   (use-private-ip annotation)  │
  │           └──────┬──────┘                                │
  │                  │                                       │
  │  ┌───────────────┼──────────────┐                        │
  │  │          AKS Cluster         │                        │
  │  │   AGIC x1 (single instance)  │                        │
  │  └──────────────────────────────┘                        │
  └──────────────────────────────────────────────────────────┘
```

Ingress 例:

```yaml
# Private Ingress — Private Frontend IP (10.2.1.10) を使用
metadata:
  annotations:
    kubernetes.io/ingress.class: azure/application-gateway
    appgw.ingress.kubernetes.io/use-private-ip: "true"

# Public Ingress — Public Frontend IP を使用 (デフォルト)
metadata:
  annotations:
    kubernetes.io/ingress.class: azure/application-gateway
    # use-private-ip を指定しない → Public Frontend IP を使用
```

WAF Policy をパス単位で分離したい場合は `appgw.ingress.kubernetes.io/waf-policy-for-path` アノテーションを使用する。

> **参考**: 推奨構成の実装は同リポジトリの `../multi_access_multi_appgw_single_agic/` ディレクトリを参照。

---

## クリーンアップ

```bash
terraform destroy
```
