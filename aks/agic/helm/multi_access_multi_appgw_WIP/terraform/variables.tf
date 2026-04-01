variable "subscription_id" {
  description = "Azure Subscription ID"
  type        = string
}

variable "location" {
  description = "Azure Region"
  type        = string
  default     = "japaneast"
}

variable "my_public_ip" {
  description = "自分のグローバル IP (CIDR 形式: x.x.x.x/32) — SSH / Public AppGW テスト許可対象"
  type        = string
}

variable "vm_admin_username" {
  description = "Test VM の管理者ユーザー名"
  type        = string
  default     = "azureuser"
}

variable "vm_admin_password" {
  description = "Test VM の管理者パスワード"
  type        = string
  sensitive   = true
}
