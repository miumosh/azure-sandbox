# 正常性確認コマンド集

コマンドの作業ディレクトリは `terraform/` を起点とする。

---

## 確認の流れ

```
① Terraform output            → リソース情報取得
② AKS ノード確認              → クラスター正常性
③ Pod 確認                    → AGIC x2 + アプリの起動状態
④ AGIC ログ確認               → 各 AppGW への設定書き込み状態
⑤ IngressClass 確認           → 2 つの IngressClass が存在するか
⑥ Ingress 確認                → Private / Public Ingress に ADDRESS が付いたか
⑦ AppGW 確認                  → 起動状態 / バックエンド正常性
⑧ Firewall 確認               → AKS Egress が通過できているか
⑨ Private Ingress 疎通 (VM)   → オンプレ想定のエンドツーエンド確認
⑩ Public Ingress 疎通 (ローカル) → 顧客想定のエンドツーエンド確認
```

---

## ① Terraform output

```bash
terraform output

# 個別取得
terraform output -raw subscription_id
terraform output -raw agic_private_identity_client_id
terraform output -raw agic_public_identity_client_id
terraform output -raw appgw_public_ip
terraform output -raw test_vm_public_ip
terraform output -raw firewall_private_ip
```

---

## ② AKS ノード確認

```bash
$(terraform output -raw aks_get_credentials_cmd)
kubectl get nodes
```

**確認観点:** `Ready` であること。`NotReady` の場合は Firewall ルールで AKS Egress がブロックされている可能性あり。

---

## ③ Pod 確認

```bash
kubectl get po -A

# AGIC Pod (各 Namespace に 1 つずつ存在すること)
kubectl get pod -n agic-private -l app=ingress-azure
kubectl get pod -n agic-public -l app=ingress-azure

# アプリ Pod (各 Namespace に 2 つずつ存在すること)
kubectl get pod -n app-private -l app=echoserver
kubectl get pod -n app-public -l app=echoserver
```

**確認観点:**
- `agic-private` NS: `agic-private-ingress-azure-*` が `Running 1/1`
- `agic-public` NS: `agic-public-ingress-azure-*` が `Running 1/1`
- `app-private` NS: `echoserver-*` が `Running 1/1` x2
- `app-public` NS: `echoserver-*` が `Running 1/1` x2

---

## ④ AGIC ログ確認

```bash
# Private Ingress 用 AGIC
kubectl logs -n agic-private -l app=ingress-azure --tail=50

# Public Ingress 用 AGIC
kubectl logs -n agic-public -l app=ingress-azure --tail=50
```

**注意すべきログパターン:**

| ログパターン | 意味 | 対処 |
|---|---|---|
| `Overlay extension config is ready` | CNI Overlay Route 設定完了 | 正常 |
| `BEGIN AppGateway deployment` | AppGW への設定書き込み開始 | 完了まで待つ |
| `is in stopped state` | AppGW 停止中 | `az ... start` 後に AGIC restart |
| `AADSTS700213` | Federated Credential subject 不一致 | release name / Namespace と subject を確認 |
| `AADSTS70011` | identityClientID 設定誤り | `--set armAuth.identityClientID` 確認 |

---

## ⑤ IngressClass 確認

```bash
kubectl get ingressclass
```

**確認観点:** 以下の 2 つが存在すること:
- `azure-application-gateway-private` (controller: `azure/application-gateway-private`)
- `azure-application-gateway-public` (controller: `azure/application-gateway-public`)

---

## ⑥ Ingress 確認

```bash
kubectl get ingress -n app-private
kubectl get ingress -n app-public

# Private Ingress: ADDRESS = 10.2.1.10
# Public Ingress:  ADDRESS = AppGW の Public IP

kubectl get ingress -A -w
```

---

## ⑦ AppGW 確認

### 起動状態

```bash
# Private Ingress 用 AppGW
az network application-gateway show \
  --name multi-appgw-private -g multi-appgw-rg \
  --query "operationalState" -o tsv

# Public Ingress 用 AppGW
az network application-gateway show \
  --name multi-appgw-public -g multi-appgw-rg \
  --query "operationalState" -o tsv
```

### バックエンド正常性

```bash
# Private Ingress 用
az network application-gateway show-backend-health \
  -g multi-appgw-rg -n multi-appgw-private \
  --query "backendAddressPools[].backendHttpSettingsCollection[].servers[].{address:address, health:health}" \
  -o table

# Public Ingress 用
az network application-gateway show-backend-health \
  -g multi-appgw-rg -n multi-appgw-public \
  --query "backendAddressPools[].backendHttpSettingsCollection[].servers[].{address:address, health:health}" \
  -o table
```

---

## ⑧ Firewall 確認

```bash
# プロビジョニング状態
az network firewall show \
  -g multi-appgw-rg -n multi-appgw-fw \
  --query "provisioningState" -o tsv

# Private IP (UDR next hop と一致するか)
az network firewall show \
  -g multi-appgw-rg -n multi-appgw-fw \
  --query "ipConfigurations[0].privateIpAddress" -o tsv

# Route Table の経路確認
az network route-table route list \
  -g multi-appgw-rg --route-table-name multi-appgw-aks-rt \
  -o table
```

---

## ⑨ Private Ingress 疎通確認 (VM → Private AppGW)

```bash
ssh azureuser@$(terraform output -raw test_vm_public_ip)
```

VM 内で実行:

```bash
APPGW_PRIVATE_IP="10.2.1.10"

# TCP 確認
nc -vz ${APPGW_PRIVATE_IP} 80

# HTTP 確認
curl -s -o /dev/null -w "%{http_code}\n" \
  http://${APPGW_PRIVATE_IP}/ -H "Host: private.internal"
# → 200

# 詳細確認
curl -v http://${APPGW_PRIVATE_IP}/ -H "Host: private.internal"
```

---

## ⑩ Public Ingress 疎通確認 (ローカル PC → Public AppGW)

```bash
APPGW_PUBLIC_IP=$(terraform output -raw appgw_public_ip)

# HTTP 確認
curl -s -o /dev/null -w "%{http_code}\n" \
  http://${APPGW_PUBLIC_IP}/ -H "Host: public.example.com"
# → 200

# 詳細確認
curl -v http://${APPGW_PUBLIC_IP}/ -H "Host: public.example.com"
```

---

## トラブルシューティング

### AppGW 起動

```bash
az network application-gateway start --name multi-appgw-private -g multi-appgw-rg
az network application-gateway start --name multi-appgw-public -g multi-appgw-rg

# AGIC 再起動
kubectl rollout restart deployment -n agic-private -l app=ingress-azure
kubectl rollout restart deployment -n agic-public -l app=ingress-azure
kubectl get pod -n agic-private -l app=ingress-azure -w
kubectl get pod -n agic-public -l app=ingress-azure -w
```

### Workload Identity 確認

```bash
kubectl get sa -n agic-private agic-private-sa-ingress-azure -o yaml
kubectl get sa -n agic-public agic-public-sa-ingress-azure -o yaml
```

**確認観点:**
- `azure.workload.identity/client-id` が `terraform output -raw agic_*_identity_client_id` と一致
- `azure.workload.identity/use: "true"` ラベルが存在

### グローバル IP 更新

```bash
# terraform.tfvars の my_public_ip を手動更新後:
terraform apply -target=azurerm_network_security_rule.vm_allow_ssh
```

---

## 重要事項

| 項目 | 内容 |
|---|---|
| WAF_v2 + Public IP | WAF_v2 は Public IP が必須。Private Ingress 用 AppGW でも Public IP を作成するが実際のルーティングには使用しない。 |
| AGIC 2 インスタンス | `ingressClassResource.name` + `watchNamespace` + Namespace 分離で競合を回避。Federated Credential の subject は各 AGIC の Namespace に合わせること。 |
| AKS Egress | `outbound_type: userDefinedRouting` + Route Table (0.0.0.0/0 → Firewall)。Firewall Rules が不足すると AKS ノードが NotReady になる。 |
| Azure Firewall Basic | Standard の 1/10 以下のコスト (~$0.10/hr)。IDPS / TLS inspection 不可。検証用途には十分。 |
| VNet Peering | Hub ↔ Spoke 双方向。`allow_forwarded_traffic = true` が必要 (Firewall 経由トラフィックのため)。 |
| コスト | WAF_v2 x2 が最も高い (~$0.72/hr)。使わない時は `terraform destroy` すること。 |
