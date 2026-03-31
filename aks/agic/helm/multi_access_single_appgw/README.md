# multi_access_single_appgw — 単一 AppGW で Private / Public Ingress を分離する構成検証

1 つの WAF_v2 AppGW に Private Frontend と Public Frontend を持たせ、Ingress ごとにリスナーを分離する構成。

- **Private Ingress**: Hub VNet の VM → VNet Peering → AppGW Private Frontend (10.2.1.10) → Pod
- **Public Ingress**: インターネット → AppGW Public Frontend (Public IP) → Pod
- **AKS Egress**: Azure Firewall (Basic SKU) 経由

---

## 単一 AppGW で Private / Public を分離する際の実装可否と懸念点

### 実装方式

1 つの AGIC が 1 つの AppGW を管理し、Ingress アノテーションでリスナーの Frontend を振り分ける。

| Ingress | アノテーション | Frontend | WAF Policy |
|---|---|---|---|
| Private Ingress | `use-private-ip: "true"` | Private Frontend (10.2.1.10) | Detection (内部通信) |
| Public Ingress | (なし — デフォルト Public) | Public Frontend (Public IP) | Prevention (外部公開) |

AGIC の Helm values で `appgw.usePrivateIP: false` を設定し、Private Ingress のみアノテーションで Private Frontend を明示する。

### 同一ポート・複数 Frontend IP の対応状況

[azure/application-gateway-kubernetes-ingress#948](https://github.com/Azure/application-gateway-kubernetes-ingress/issues/948) で報告されていた「同一ポート (80/443) で複数 Frontend IP にリスナーを作成できない」問題は AGIC v1.5.0 以降で解消済み。現在の v1.9.1 では問題なく動作する。

### WAF Policy の分離

本構成では AppGW が 1 つのため、Ingress の `appgw.ingress.kubernetes.io/waf-policy-for-path` アノテーションで Ingress ごとに異なる WAF Policy を適用する。

- 技術的にはリスナーレベルではなくルーティングルール (Request Routing Rule) 単位での適用。ただし 1 Ingress = 1 リスナー = 1 ルーティングルールのため、実質的にリスナー単位の WAF 分離と同等の効果。
- アノテーションに WAF Policy の完全な Resource ID が必要。Terraform output (`waf_policy_private_id` / `waf_policy_public_id`) から取得して `sed` で YAML に注入する (デプロイ手順 Step 5 参照)。
- AGIC が WAF Policy をルーティングルールに関連付けるため、AGIC の MI に WAF Policy への Contributor 権限が**必須** (`role.tf` で設定)。

| 方式 | 紐付け先 | 設定箇所 |
|---|---|---|
| 2 AppGW 構成 | AppGW リソースの `firewall_policy_id` | Terraform (`appgw_*.tf`) |
| **本構成 (単一 AppGW)** | Ingress アノテーション `waf-policy-for-path` | Kubernetes Ingress YAML |

### 懸念点

| 観点 | 内容 | 影響度 |
|---|---|---|
| **単一障害点** | AppGW 1 つのため、障害・メンテナンス時に Private / Public 両方のアクセスが停止する | 高 |
| **スケーリング共有** | Private / Public トラフィックが同一インスタンスを共有。片方の負荷増がもう片方に影響。autoscale は AppGW 全体に適用され Frontend 単位では制御不可 | 中 |
| **AGIC 障害** | 単一 AGIC の障害で両系統の設定更新が停止する (既存設定は維持) | 中 |
| **メンテナンス** | AppGW の構成変更が両系統に影響する可能性。Terraform の `lifecycle.ignore_changes` で AGIC 管理部分を保護しているが、SKU 変更等は両方に影響 | 中 |
| **WAF Policy の制約** | アノテーション未設定の Ingress にはグローバル WAF Policy が適用される。新しい Ingress を追加する際はアノテーションの付け忘れに注意 | 低 |
| **ログの混在** | AppGW のアクセスログ / WAF ログに Private / Public 両方のトラフィックが混在する。分析時に Frontend IP でフィルタが必要 | 低 |

### 2 AppGW 構成との比較

| 項目 | 単一 AppGW (本構成) | 2 AppGW 構成 |
|---|---|---|
| コスト | WAF_v2 x1 (~$0.36/hr) | WAF_v2 x2 (~$0.72/hr) |
| 年間差額 | — | +~$3,100 |
| 可用性 | 単一障害点 | 独立して障害分離可能 |
| スケーリング | 共有 | 独立 |
| 運用複雑度 | シンプル (AGIC 1 つ) | 中程度 (AGIC 2 つ、ingressClass 分離) |
| WAF 分離 | ルーティングルール単位 | AppGW 単位 (完全分離) |
| メンテナンス | 両方に影響 | 独立メンテナンス可能 |

**判断指針**: コスト重視・トラフィック小規模なら単一 AppGW、可用性・独立運用が必要なら 2 AppGW。

---

## アーキテクチャ

```
            Internet
               │
  ┌─── Spoke VNet (10.2.0.0/16) ────────────────────────┐
  │     ┌──────┴─────────────────────┐                  │
  │     │     AppGW (WAF_v2)         │                  │
  │     │  Public FE ← Public Ingress│                  │
  │     │  Private FE (10.2.1.10)    │                  │
  │     │     ↑ Private Ingress      │                  │
  │     └──────┬─────────────────────┘                  │
  │            │                                        │
  │     ┌──────┴──────────────┐                         │
  │     │    AKS Cluster      │                         │
  │     │  CNI Overlay        │                         │
  │     │  Pod: 192.168.x.x   │                         │
  │     └──────┬──────────────┘                         │
  └────────────┼────────────────────────────────────────┘
               │ VNet Peering
  ┌─── Hub VNet (10.1.0.0/16) ──────────────────────────┐
  │            │                                        │
  │  ┌─────────┴─────────┐  ┌────────────────────────┐  │
  │  │  Test VM          │  │  Azure Firewall        │  │
  │  │  (10.1.1.x)       │  │  (Basic SKU)           │  │
  │  │  → Private Ingress│  │  AKS Egress用          │  │
  │  └───────────────────┘  └────────────────────────┘  │
  └─────────────────────────────────────────────────────┘
```

---

## ディレクトリ構成

```
multi_access_single_appgw/
├── terraform/
│   ├── versions.tf                  # azurerm ~> 4.14
│   ├── variables.tf
│   ├── terraform.tfvars.sample
│   ├── rg.tf
│   ├── nw.tf                        # Hub VNet + Spoke VNet + Peering
│   ├── sg.tf                        # NSG (AKS / AppGW / VM)
│   ├── firewall.tf                  # Azure Firewall Basic
│   ├── rt.tf                        # Route Table (AKS → Firewall)
│   ├── appgw.tf                     # AppGW (WAF_v2) + WAF Policy x2
│   ├── aks.tf                       # AKS (CNI Overlay / UDR Egress)
│   ├── identity.tf                  # AGIC MI + Federated Credential
│   ├── role.tf                      # RBAC
│   ├── vm.tf                        # Test VM (Hub VNet)
│   └── outputs.tf
├── helm/
│   ├── agic/
│   │   └── agic-values.yaml         # AGIC — usePrivateIP: false
│   ├── app/
│   │   └── echoserver/
│   │       └── app.yaml
│   └── ingress/
│       ├── ingress-private.yaml     # Private Ingress (use-private-ip + WAF annotation)
│       └── ingress-public.yaml      # Public Ingress (WAF annotation)
├── .gitignore
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
| appgw-subnet | `10.2.1.0/24` |
| aks-subnet | `10.2.2.0/24` |
| AppGW Private Frontend IP | `10.2.1.10` |
| Pod CIDR (CNI Overlay) | `192.168.0.0/16` |
| Service CIDR | `10.100.0.0/16` |

---

## コスト概算

| リソース | 概算コスト |
|---|---|
| Azure Firewall Basic | ~$0.10/hr |
| AppGW WAF_v2 x1 | ~$0.36/hr |
| AKS (Standard_B2ms x1) | ~$0.08/hr |
| Public IP x3 | ~$0.015/hr |
| VM (Standard_B1s) | ~$0.01/hr |
| **合計** | **~$0.57/hr (~$410/月)** |

> 2 AppGW 構成 (~$670/月) と比較して ~$260/月のコスト削減。使わない時は `terraform destroy` すること。

---

## デプロイ手順

作業ディレクトリは `terraform/` を起点とする。

### 1. terraform.tfvars を設定

```bash
cp terraform/terraform.tfvars.sample terraform/terraform.tfvars
vi terraform/terraform.tfvars
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

### 4. AGIC を Helm でインストール (1つ)

```bash
helm install agic \
  oci://mcr.microsoft.com/azure-application-gateway/charts/ingress-azure \
  --version 1.9.1 \
  --namespace kube-system \
  --set appgw.subscriptionId=$(terraform output -raw subscription_id) \
  --set armAuth.identityClientID=$(terraform output -raw agic_identity_client_id) \
  -f ../helm/agic/agic-values.yaml
```

```bash
kubectl get pod -n kube-system -l app=ingress-azure
```

### 5. アプリと Ingress をデプロイ

Ingress YAML の WAF Policy ID プレースホルダーを `terraform output` から注入して apply する。

```bash
# アプリ
kubectl apply -f ../helm/app/echoserver/app.yaml

# Ingress (WAF Policy ID を terraform output から注入して apply)
sed "s|WAF_POLICY_PRIVATE_ID|$(terraform output -raw waf_policy_private_id)|g" \
  ../helm/ingress/ingress-private.yaml | kubectl apply -f -

sed "s|WAF_POLICY_PUBLIC_ID|$(terraform output -raw waf_policy_public_id)|g" \
  ../helm/ingress/ingress-public.yaml | kubectl apply -f -

# ADDRESS 確認
kubectl get ingress -w
# Private Ingress: ADDRESS = 10.2.1.10
# Public Ingress:  ADDRESS = AppGW の Public IP
```

### 6. 疎通確認

#### Private Ingress (VM → AppGW Private Frontend)

```bash
ssh azureuser@$(terraform output -raw test_vm_public_ip)

# VM 内で実行
curl -s -o /dev/null -w "%{http_code}\n" http://10.2.1.10/ -H "Host: private.internal"
# → 200
```

#### Public Ingress (ローカル PC → AppGW Public Frontend)

```bash
APPGW_PUBLIC_IP=$(terraform output -raw appgw_public_ip)
curl -s -o /dev/null -w "%{http_code}\n" http://${APPGW_PUBLIC_IP}/ -H "Host: public.example.com"
# → 200
```

---

## トラブルシューティング

### AppGW が Stopped 状態

```bash
az network application-gateway show \
  --name single-appgw -g single-appgw-rg --query "operationalState" -o tsv

az network application-gateway start --name single-appgw -g single-appgw-rg

kubectl rollout restart deployment -n kube-system -l app=ingress-azure
```

### AKS ノードが NotReady

Firewall ルールで AKS Egress がブロックされている可能性。`firewall.tf` のルールを確認。

### Workload Identity 確認

```bash
kubectl get sa -n kube-system agic-sa-ingress-azure -o yaml
# azure.workload.identity/client-id が terraform output の値と一致すること
```

### AGIC ログ確認

```bash
kubectl logs -n kube-system -l app=ingress-azure --tail=50
```

### グローバル IP 更新

```bash
# terraform.tfvars の my_public_ip を手動更新後:
terraform apply -target=azurerm_network_security_rule.vm_allow_ssh
```

### WAF Policy が適用されていない

```bash
# Ingress の annotation を確認
kubectl get ingress echoserver-private-ingress -o yaml | grep waf-policy
kubectl get ingress echoserver-public-ingress -o yaml | grep waf-policy

# Resource ID が正しいか確認
terraform output waf_policy_private_id
terraform output waf_policy_public_id
```

---

## クリーンアップ

```bash
terraform destroy
```
