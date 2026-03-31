# AKS + AGIC CNI Overlay 疎通検証

NodePort / ClusterIP の両 Service type に対して AGIC (Application Gateway Ingress Controller) 経由のルーティングを検証する最小構成環境。

- **NodePort**: AppGW → Node IP:NodePort → kube-proxy DNAT → Pod
- **ClusterIP**: AppGW → Pod IP 直接 (Route Table 経由) → Pod  ※ AGIC v1.9.1+ 必須

---

## ディレクトリ構成

```
overlay-test/
├── scripts/
│   └── update_my_ip.sh          # グローバル IP を取得して terraform.tfvars を更新
├── terraform/                   # ★ 作業ディレクトリ (Step 3 以降)
│   ├── versions.tf              # azurerm ~> 4.3
│   ├── variables.tf
│   ├── terraform.tfvars         # 変数の実値（subscription_id / パスワード等）
│   ├── rg.tf                    # Resource Group
│   ├── nw.tf                    # VNet + Subnets
│   ├── sg.tf                    # NSG + NSG Rules
│   ├── appgw.tf                 # Application Gateway
│   ├── aks.tf                   # AKS Cluster
│   ├── identity.tf              # User-Assigned MI + Federated Credential
│   ├── role.tf                  # RBAC Role Assignments
│   ├── vm.tf                    # Test VM
│   └── outputs.tf
├── helm/
│   ├── agic/
│   │   └── agic-values.yaml     # AGIC Helm values
│   ├── app/
│   │   ├── nodeport-test/
│   │   │   └── app.yaml         # ConfigMap + Deployment + NodePort Service
│   │   └── clusterip-test/
│   │       └── app.yaml         # ConfigMap + Deployment + ClusterIP Service
│   └── ingress/
│       ├── ingress-nodeport.yaml
│       └── ingress-clusterip.yaml
└── test/
    └── test.sh                  # VM 上で実行する疎通確認スクリプト
```

---

## 前提条件

| ツール | バージョン |
|---|---|
| Terraform | >= 1.5.0 |
| Azure CLI (`az`) | 最新 |
| kubectl | 最新 |
| Helm | >= 3.x |

Azure CLI でログイン済みであること:

```bash
az login
az account set --subscription <SUBSCRIPTION_ID>
```

---

## デプロイ手順

> **作業ディレクトリの方針**
> - Step 1 は `overlay-test/` で実行
> - Step 2 以降で `cd terraform` し、**以降はすべて `terraform/` を起点に実行する**

### 1. Terraform の変数を設定

```bash
# ./terraform/terraform.tfvars の以下3点を状況に合わせて更新
subscription_id = "xxx"    # az account show --query id -o tsv
my_public_ip    = "xxx/32" # curl ifconfig.me
vm_admin_username = "xxx"
vm_admin_password = "xxx"

```

### 2. Terraform でインフラ構築

```bash
cd terraform   # ← 以降すべてここを起点にする

terraform init
terraform plan
terraform apply

# 依存関係グラフを出力（オプション）
terraform graph | dot -Tpng > dependency_graph.png
```

### 3. kubectl コンテキストを設定

```bash
# terraform/ で実行
$(terraform output -raw aks_get_credentials_cmd)
kubectl get nodes
```

### 4. AGIC を Helm でインストール

`armAuth.identityClientID` と `appgw.subscriptionId` は `--set` で `terraform output` から直接渡す。

```bash
# terraform/ で実行
helm install agic \
  oci://mcr.microsoft.com/azure-application-gateway/charts/ingress-azure \
  --version 1.9.1 \
  --namespace kube-system \
  --set appgw.subscriptionId=$(terraform output -raw subscription_id) \
  --set armAuth.identityClientID=$(terraform output -raw agic_identity_client_id) \
  -f ../helm/agic/agic-values.yaml
```

AGIC Pod の起動確認:

```bash
kubectl get pod -n kube-system -l app=ingress-azure
kubectl logs -n kube-system -l app=ingress-azure --tail=50
```

### 5. アプリと Ingress をデプロイ

```bash
# terraform/ で実行
# アプリ (Deployment + Service)
kubectl apply -f ../helm/app/nodeport-test/app.yaml
kubectl apply -f ../helm/app/clusterip-test/app.yaml

# Ingress (AGIC が AppGW を自動設定)
kubectl apply -f ../helm/ingress/ingress-nodeport.yaml
kubectl apply -f ../helm/ingress/ingress-clusterip.yaml

kubectl get ingress
```

### 6. 疎通確認 (Test VM から実行)

```bash
# terraform/ で実行
ssh azureuser@$(terraform output -raw test_vm_public_ip)
```

VM 内で実行:

```bash
APPGW_PRIVATE_IP="10.0.1.10"

# NodePort 疎通確認
curl -s -o /dev/null -w "%{http_code}\n" http://${APPGW_PRIVATE_IP}/ -H "Host: nodeport-setting.internal"
# → 200 が返れば OK

# ClusterIP 疎通確認
curl -s -o /dev/null -w "%{http_code}\n" http://${APPGW_PRIVATE_IP}/ -H "Host: clusterip-setting.internal"
# → 200 が返れば OK
```


---

## トラブルシューティング

### AppGW が stopped 状態になり AGIC が設定を書き込めない

`terraform apply` で AppGW が再作成されると stopped 状態で起動することがある。
AGIC ログに以下が出ていたら stopped 状態が原因:

```
Application Gateway agic-green-appgw is in stopped state
Ignore mutating App Gateway as it is not mutable
```

**対処:**

```bash
# AppGW を起動
az network application-gateway start \
  --name agic-green-appgw \
  --resource-group agic-green-rg

# 状態確認 (Running になるまで待つ)
az network application-gateway show \
  --name agic-green-appgw \
  --resource-group agic-green-rg \
  --query "operationalState" -o tsv

# AGIC を再起動して AppGW 設定を再書き込みさせる
kubectl rollout restart deployment agic-ingress-azure -n kube-system
kubectl rollout status deployment agic-ingress-azure -n kube-system

# Ingress に ADDRESS (10.0.1.10) が付くまで待つ
kubectl get ingress -w
```

---

## ネットワーク構成

| リソース | CIDR / IP |
|---|---|
| VNet | `10.0.0.0/16` |
| appgw-subnet | `10.0.1.0/24` |
| AppGW Private IP | `10.0.1.10` |
| aks-subnet | `10.0.2.0/24` |
| vm-subnet | `10.0.3.0/24` |
| Pod CIDR (CNI Overlay) | `192.168.0.0/16` |
| Service CIDR | `10.100.0.0/16` |

---

## クリーンアップ

```bash
# terraform/ で実行
terraform destroy
```
