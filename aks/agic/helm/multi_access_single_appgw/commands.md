# 正常性確認コマンド集

コマンドの作業ディレクトリは `terraform/` を起点とする。

---

## 確認の流れ

```
① Terraform output              → リソース情報取得
② AKS ノード確認                → クラスター正常性
③ Pod 確認                      → AGIC + アプリの起動状態
④ AGIC ログ確認                 → AppGW への設定書き込み状態
⑤ Ingress 確認                  → Private / Public 各 Ingress に ADDRESS が付いたか
⑥ AppGW 確認                    → 起動状態 / リスナー / バックエンド正常性
⑦ WAF Policy 確認               → Private / Public 各 Ingress に正しい WAF が適用されているか
⑧ Firewall 確認                 → AKS Egress 正常性
⑨ Private Ingress 疎通 (VM)     → オンプレ想定のエンドツーエンド確認
⑩ Public Ingress 疎通 (ローカル) → 顧客想定のエンドツーエンド確認
```

---

## ① Terraform output

```bash
terraform output

terraform output -raw subscription_id
terraform output -raw agic_identity_client_id
terraform output -raw appgw_public_ip
terraform output -raw test_vm_public_ip
terraform output -raw firewall_private_ip
terraform output waf_policy_private_id
terraform output waf_policy_public_id
```

---

## ② AKS ノード確認

```bash
$(terraform output -raw aks_get_credentials_cmd)
kubectl get nodes
```

**確認観点:** `Ready` であること。`NotReady` の場合は Firewall ルールを確認。

---

## ③ Pod 確認

```bash
kubectl get po -A
kubectl get pod -n kube-system -l app=ingress-azure
```

**確認観点:**
- `agic-ingress-azure-*` が `Running 1/1` (1 Pod)
- `echoserver-*` が `Running 1/1`

---

## ④ AGIC ログ確認

```bash
kubectl logs -n kube-system -l app=ingress-azure --tail=50

# 問題発生時
kubectl logs -n kube-system -l app=ingress-azure --tail=200
```

**注意すべきログパターン:**

| ログパターン | 意味 | 対処 |
|---|---|---|
| `Overlay extension config is ready` | CNI Overlay Route 設定完了 | 正常 |
| `BEGIN AppGateway deployment` | AppGW への設定書き込み開始 | 完了まで待つ |
| `is in stopped state` | AppGW 停止中 | `az ... start` 後に AGIC restart |
| `AADSTS700213` | Federated Credential subject 不一致 | release name と subject を確認 |
| `AADSTS70011` | identityClientID 設定誤り | `--set armAuth.identityClientID` 確認 |

---

## ⑤ Ingress 確認

```bash
kubectl get ingress

# Private Ingress: ADDRESS = 10.2.1.10
# Public Ingress:  ADDRESS = AppGW の Public IP
# 同一 AppGW だが Frontend IP が異なる

kubectl get ingress -w
```

---

## ⑥ AppGW 確認

### 起動状態

```bash
az network application-gateway show \
  --name single-appgw -g single-appgw-rg \
  --query "operationalState" -o tsv
```

### リスナー一覧 (Private / Public 両方のリスナーが存在すること)

```bash
az network application-gateway show \
  -g single-appgw-rg -n single-appgw \
  -o json | python3 -c "
import json, sys
d = json.load(sys.stdin)
for l in d.get('httpListeners', []):
    fip = l.get('frontendIpConfiguration', {}).get('id', 'N/A')
    print(l['name'], '->', fip.split('/')[-1] if fip != 'N/A' else 'N/A')
"
```

**確認観点:** `appgw-private-frontend` と `appgw-public-frontend` 両方のリスナーが存在すること。

### バックエンド正常性

```bash
az network application-gateway show-backend-health \
  -g single-appgw-rg -n single-appgw \
  --query "backendAddressPools[].backendHttpSettingsCollection[].servers[].{address:address, health:health}" \
  -o table
```

---

## ⑦ WAF Policy 確認

```bash
# AppGW に関連付けられた WAF Policy (グローバル)
az network application-gateway show \
  -g single-appgw-rg -n single-appgw \
  --query "firewallPolicy.id" -o tsv

# 各 WAF Policy のモード確認
az network application-gateway waf-policy show \
  -g single-appgw-rg -n single-appgw-waf-policy-private \
  --query "policySettings.mode" -o tsv
# → Detection

az network application-gateway waf-policy show \
  -g single-appgw-rg -n single-appgw-waf-policy-public \
  --query "policySettings.mode" -o tsv
# → Prevention

# Ingress annotation で正しい WAF Policy ID が設定されているか
kubectl get ingress echoserver-private-ingress -o jsonpath='{.metadata.annotations.appgw\.ingress\.kubernetes\.io/waf-policy-for-path}'
kubectl get ingress echoserver-public-ingress -o jsonpath='{.metadata.annotations.appgw\.ingress\.kubernetes\.io/waf-policy-for-path}'
```

---

## ⑧ Firewall 確認

```bash
az network firewall show \
  -g single-appgw-rg -n single-appgw-fw \
  --query "provisioningState" -o tsv

az network firewall show \
  -g single-appgw-rg -n single-appgw-fw \
  --query "ipConfigurations[0].privateIpAddress" -o tsv

az network route-table route list \
  -g single-appgw-rg --route-table-name single-appgw-aks-rt \
  -o table
```

---

## ⑨ Private Ingress 疎通確認 (VM → AppGW Private Frontend)

```bash
ssh azureuser@$(terraform output -raw test_vm_public_ip)
```

VM 内で実行:

```bash
APPGW_PRIVATE_IP="10.2.1.10"

nc -vz ${APPGW_PRIVATE_IP} 80

curl -s -o /dev/null -w "%{http_code}\n" \
  http://${APPGW_PRIVATE_IP}/ -H "Host: private.internal"
# → 200

curl -v http://${APPGW_PRIVATE_IP}/ -H "Host: private.internal"
```

---

## ⑩ Public Ingress 疎通確認 (ローカル PC → AppGW Public Frontend)

```bash
APPGW_PUBLIC_IP=$(terraform output -raw appgw_public_ip)

curl -s -o /dev/null -w "%{http_code}\n" \
  http://${APPGW_PUBLIC_IP}/ -H "Host: public.example.com"
# → 200

curl -v http://${APPGW_PUBLIC_IP}/ -H "Host: public.example.com"
```

---

## トラブルシューティング

### AppGW 起動

```bash
az network application-gateway start --name single-appgw -g single-appgw-rg
kubectl rollout restart deployment -n kube-system -l app=ingress-azure
kubectl get pod -n kube-system -l app=ingress-azure -w
```

### Workload Identity 確認

```bash
kubectl get sa -n kube-system agic-sa-ingress-azure -o yaml
```

### グローバル IP 更新

```bash
# terraform.tfvars の my_public_ip を手動更新後:
terraform apply -target=azurerm_network_security_rule.vm_allow_ssh
```

---

## 重要事項

| 項目 | 内容 |
|---|---|
| 単一 AppGW | Private / Public が 1 つの AppGW を共有。障害・スケーリングが連動する点に注意。 |
| usePrivateIP | Helm values は `false` (デフォルト Public)。Private Ingress は `use-private-ip: "true"` アノテーションで制御。 |
| WAF 分離 | `waf-policy-for-path` アノテーションで Ingress ごとに異なる WAF Policy を適用。`terraform output -raw waf_policy_*_id` で Resource ID を取得し `sed` で注入すること。 |
| 同一ポート問題 | GitHub #948 は AGIC v1.5.0 以降で解消済み。v1.9.1 では問題なし。 |
| コスト | 2 AppGW 構成比で WAF_v2 1 台分 (~$0.36/hr) を削減。 |

# Links
- [AGIC #948: 同じポート上の複数の IP (例: 80/443) が同居できない問題](https://github.com/Azure/application-gateway-kubernetes-ingress/issues/948)
