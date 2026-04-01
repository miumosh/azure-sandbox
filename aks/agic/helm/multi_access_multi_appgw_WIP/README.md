# multi_access_multi_appgw — AppGW x2 + AGIC x2 構成 (Helm)

Ingress 経由の Private 接続 (オンプレ想定) と Public 接続 (顧客想定) を、それぞれ専用の WAF_v2 AppGW + AGIC で受けて AKS の同一アプリにルーティングする構成。

- **Private Ingress**: Hub VNet の VM → VNet Peering → Private AppGW (10.2.1.10) → Pod
- **Public Ingress**: インターネット → Public AppGW (Public IP) → Pod
- **AKS Egress**: デフォルト LB を使わず Azure Firewall (Basic SKU) 経由

> **参考ドキュメント:**
> - [AGIC Overview — Helm と AKS アドオンの違い](https://learn.microsoft.com/ja-jp/azure/application-gateway/ingress-controller-overview)
> - [AGIC 複数 Namespace サポート](https://learn.microsoft.com/ja-jp/azure/application-gateway/ingress-controller-multiple-namespace-support)

---

## NG 構成 (`multi_access_multi_appgw_NG/`) からの修正点

同じ AppGW x2 + AGIC x2 構成を `multi_access_multi_appgw_NG/` で試みたが動作しなかった。本構成はその問題を修正したもの。

### NG 構成の失敗原因

AGIC Helm chart v1.9.1 のテンプレート分析の結果、リソース名の状況は以下の通り:

| リソース | スコープ | 名前パターン | 複数インスタンス |
|---|---|---|---|
| ServiceAccount | Namespaced | `{release名}-sa-ingress-azure` | release名で自動分離 |
| ConfigMap | Namespaced | `{release名}-cm-ingress-azure` | release名で自動分離 |
| Deployment | Namespaced | `{release名}-ingress-azure` | release名で自動分離 |
| ClusterRole | **Cluster** | `{release名}-ingress-azure` | release名で自動分離 |
| ClusterRoleBinding | **Cluster** | `{release名}-ingress-azure` | release名で自動分離 |
| **IngressClass** | **Cluster** | **`azure-application-gateway` (デフォルト)** | **要設定変更** |

**真の失敗原因は 3 点:**

1. **IngressClass リソース名がデフォルト (`azure-application-gateway`) のまま衝突** — 唯一デフォルトがハードコードされたクラスタスコープリソース。ただし `kubernetes.ingressClassResource.name` と `controllerValue` で変更可能
2. **`watchNamespace: ""` で全 Namespace を監視** — 両 AGIC が全 Ingress を処理し、互いの AppGW 設定を上書き
3. **Overlay Extension Config (`agic-overlay-extension-config`) の競合 (CNI Overlay 利用時のみ)** — CNI Overlay 環境でのみ AGIC が起動時に作成する CRD リソース。Azure CNI (非 Overlay) や Kubenet では作成されないため本問題は発生しない。名前が AGIC ソースコード ([`pkg/cni/overlay.go`](https://github.com/Azure/application-gateway-kubernetes-ingress/blob/master/pkg/cni/overlay.go)) に Go const としてハードコードされており変更不可。**Namespace スコープ**のリソースだが、NG 構成では両 AGIC を同一 Namespace (`kube-system`) にデプロイしたため競合が発生。AGIC を別 Namespace にデプロイすることで回避可能

> 注: ClusterRole/ClusterRoleBinding は NG 構成でも release名 (`agic-private` / `agic-public`) で分離されていた。

### Overlay Extension Config 問題の詳細

#### NG 構成で発生した具体的なエラー (CNI Overlay 利用時のみ)

本問題は AKS が CNI Overlay (`network_plugin_mode = "overlay"`) を使用している場合にのみ発生する。Azure CNI (非 Overlay) や Kubenet では overlay extension config 自体が作成されないため、本問題は起きない。

両 AGIC を同一 Namespace (`kube-system`) にデプロイした際、以下の競合が発生した:

```
# agic-private: overlay extension config の作成を試みるが、タイムアウト
I0330 14:30:20.407148  overlay.go:142] Creating overlay extension config with subnet CIDR 10.2.1.0/24
I0330 14:30:20.427984  overlay.go:171] Waiting for overlay extension config to be ready
  ... (30秒間リトライ)
W0330 14:30:50.418456  controller.go:128] failed to reconcile overlay CNI:
  failed to reconcile overlay resources: timed out waiting for overlay extension config to be ready

# agic-public: 同じリソースを上書きし、自身のサブネット (10.2.2.0/24) で成功
# → agic-private の AppGW サブネット (10.2.1.0/24) のルーティングが設定されない

# 結果: agic-private の AppGW バックエンドヘルスが Unhealthy
Address        Health     HealthProbeLog
192.168.0.14   Unhealthy  Time taken by the backend to respond ... more than the time-out threshold
192.168.0.231  Unhealthy  Time taken by the backend to respond ... more than the time-out threshold
```

原因は `overlayextensionconfigs.acn.azure.com` CRD の `agic-overlay-extension-config` リソースが同一 Namespace 内で 1 つしか存在できないこと。勝った方の AGIC のサブネットのみ overlay ルーティングが設定され、負けた方の AppGW → Pod IP 通信がタイムアウトする。

#### リソース名のハードコードと Namespace スコープ

`OverlayExtensionConfigName` は AGIC ソースコード ([`pkg/cni/overlay.go`](https://github.com/Azure/application-gateway-kubernetes-ingress/blob/master/pkg/cni/overlay.go)) に Go の `const` として定義されており、**変数注入による名前変更は不可能**:

```go
const (
    OverlayExtensionConfigName = "agic-overlay-extension-config"

    OverlayConfigReconcileTimeout = 30 * time.Second

    OverlayConfigReconcilePollInterval = 2 * time.Second
)
```

環境変数・Helm values・Ingress アノテーション等で上書きする仕組みは提供されていない。

**ただし、このリソースは Namespace スコープである。** ソースコード上で `Namespace: r.namespace` (AGIC がデプロイされた Namespace) が指定されている:

```go
ObjectMeta: meta_v1.ObjectMeta{
    Name:      OverlayExtensionConfigName,  // "agic-overlay-extension-config" (固定)
    Namespace: r.namespace,                  // AGIC のデプロイ先 Namespace
}
```

NG 構成では両 AGIC を `kube-system` にデプロイしていたため、同一 Namespace 内で同名リソースが競合した。本構成では AGIC を別 Namespace (`agic-private` / `agic-public`) にデプロイするため、各 Namespace に独立した overlay extension config が作成され競合しない:

| 構成 | AGIC Namespace | 作成されるリソース | 競合 |
|---|---|---|---|
| NG | 両方 `kube-system` | `kube-system/agic-overlay-extension-config` x2 | **する** |
| 本構成 | `agic-private` / `agic-public` | `agic-private/agic-overlay-extension-config` + `agic-public/agic-overlay-extension-config` | **しない** |

> **参考:**
> - AGIC ソースコード: [`pkg/cni/overlay.go`](https://github.com/Azure/application-gateway-kubernetes-ingress/blob/master/pkg/cni/overlay.go) — `OverlayExtensionConfigName` 定数定義
> - 関連 Issue: [#1524](https://github.com/Azure/application-gateway-kubernetes-ingress/issues/1524)
> - 関連 PR: [#1650](https://github.com/Azure/application-gateway-kubernetes-ingress/pull/1650)

### NG との差分

| 項目 | NG (失敗) | 本構成 (修正) |
|---|---|---|
| AGIC デプロイ先 | 両方 `kube-system` | `agic-private` / `agic-public` |
| `watchNamespace` | `""` (全 NS) | `"app-private"` / `"app-public"` |
| `ingressClassResource.enabled` | private=true, public=false | 両方 true |
| `ingressClassResource.name` | デフォルト (`azure-application-gateway`) | `azure-application-gateway-private` / `-public` |
| `ingressClassResource.controllerValue` | デフォルト | `azure/application-gateway-private` / `-public` |
| Federated Credential subject | `system:serviceaccount:kube-system:...` | `system:serviceaccount:agic-private:...` / `agic-public:...` |
| アプリ Namespace | `default` | `app-private` / `app-public` |
| Ingress Namespace | `default` | `app-private` / `app-public` |

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
  │  │                               │                   │
  │  │  NS: agic-private             │                   │
  │  │    └ AGIC Pod (→ Private AppGW)                   │
  │  │  NS: agic-public              │                   │
  │  │    └ AGIC Pod (→ Public AppGW)│                   │
  │  │  NS: app-private              │                   │
  │  │    └ echoserver + Ingress     │                   │
  │  │  NS: app-public               │                   │
  │  │    └ echoserver + Ingress     │                   │
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

## Namespace 戦略

| Namespace | 用途 | 配置リソース |
|---|---|---|
| `agic-private` | AGIC Private のデプロイ先 | AGIC Pod, ServiceAccount, ConfigMap |
| `agic-public` | AGIC Public のデプロイ先 | AGIC Pod, ServiceAccount, ConfigMap |
| `app-private` | Private Ingress 経由のアプリ | echoserver Deployment/Service, Ingress |
| `app-public` | Public Ingress 経由のアプリ | echoserver Deployment/Service, Ingress |

各 AGIC は `watchNamespace` で自分の担当 Namespace のみ監視する:
- `agic-private` → `app-private` の Ingress のみ処理
- `agic-public` → `app-public` の Ingress のみ処理

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
│   ├── identity.tf                  # AGIC MI x2 + Federated Credential x2 (★ NG から修正)
│   ├── role.tf                      # RBAC Role Assignments
│   ├── vm.tf                        # Test VM (Hub VNet)
│   └── outputs.tf
├── helm/
│   ├── agic-private/
│   │   └── agic-values.yaml         # Private Ingress 用 AGIC (★ 修正版)
│   ├── agic-public/
│   │   └── agic-values.yaml         # Public Ingress 用 AGIC (★ 修正版)
│   ├── app/
│   │   └── echoserver/
│   │       └── app.yaml             # echoserver Deployment + ClusterIP Service
│   └── ingress/
│       ├── ingress-private.yaml     # Private Ingress (NS: app-private)
│       └── ingress-public.yaml      # Public Ingress (NS: app-public)
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

AGIC を 2 インスタンスデプロイし、`ingressClassResource.name` + `watchNamespace` で処理対象を完全分離する。

| AGIC | Namespace | IngressClass リソース名 | watchNamespace | AppGW |
|---|---|---|---|---|
| agic-private | `agic-private` | `azure-application-gateway-private` | `app-private` | multi-appgw-private |
| agic-public | `agic-public` | `azure-application-gateway-public` | `app-public` | multi-appgw-public |

### WAF Policy の紐付け方式

本構成では AppGW が 2 つあるため、WAF Policy は各 AppGW の `firewall_policy_id` に直接紐付ける（Terraform の `appgw_private.tf` / `appgw_public.tf` で設定）。

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
```

### 3. kubectl コンテキスト設定

```bash
$(terraform output -raw aks_get_credentials_cmd)
kubectl get nodes
```

### 4. アプリ用 Namespace を作成

```bash
kubectl create namespace app-private
kubectl create namespace app-public
```

### 5. AGIC を Helm でインストール (各 Namespace に 1 つずつ)

```bash
# Private Ingress 用 AGIC (agic-private Namespace にデプロイ)
helm install agic-private \
  oci://mcr.microsoft.com/azure-application-gateway/charts/ingress-azure \
  --version 1.9.1 \
  --namespace agic-private \
  --create-namespace \
  --set appgw.subscriptionId=$(terraform output -raw subscription_id) \
  --set armAuth.identityClientID=$(terraform output -raw agic_private_identity_client_id) \
  -f ../helm/agic-private/agic-values.yaml

# Public Ingress 用 AGIC (agic-public Namespace にデプロイ)
helm install agic-public \
  oci://mcr.microsoft.com/azure-application-gateway/charts/ingress-azure \
  --version 1.9.1 \
  --namespace agic-public \
  --create-namespace \
  --set appgw.subscriptionId=$(terraform output -raw subscription_id) \
  --set armAuth.identityClientID=$(terraform output -raw agic_public_identity_client_id) \
  -f ../helm/agic-public/agic-values.yaml
```

```bash
# AGIC Pod 確認 (各 Namespace に 1 Pod が Running であること)
kubectl get pod -n agic-private -l app=ingress-azure
kubectl get pod -n agic-public -l app=ingress-azure

# IngressClass 確認 (2 つ存在すること)
kubectl get ingressclass
```

### 6. アプリと Ingress をデプロイ

```bash
# アプリを各 Namespace にデプロイ
kubectl apply -n app-private -f ../helm/app/echoserver/app.yaml
kubectl apply -n app-public -f ../helm/app/echoserver/app.yaml

# Ingress をデプロイ (Namespace は YAML に記載済み)
kubectl apply -f ../helm/ingress/ingress-private.yaml
kubectl apply -f ../helm/ingress/ingress-public.yaml

kubectl get ingress -A -w
# app-private: ADDRESS = 10.2.1.10
# app-public:  ADDRESS = AppGW の Public IP
```

### 7. 疎通確認

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

## クリーンアップ

```bash
terraform destroy
```
