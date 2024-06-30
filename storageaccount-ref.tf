# Create a storage account
resource "azurerm_storage_account" "fitnessgeek-storage" {
  name                     = "terraformbackend${random_integer.suffix.result}"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  lifecycle {
    ignore_changes = [
      primary_access_key
    ]
  }
}

# Create a storage container
resource "azurerm_storage_container" "fn-storageaccount" {
  name                  = "fgfunctionappsa2023"
  storage_account_name  = azurerm_storage_account.fitnessgeek-storage.name
  container_access_type = "private"
}

# Generate a random suffix for the storage account name to ensure uniqueness
resource "random_integer" "suffix" {
  min = 10000
  max = 99999
}

# Output storage account name and container name
output "storage_account_name" {
  value = azurerm_storage_account.fn-storageaccount.name
}

output "container_name" {
  value = azurerm_storage_container.fgfunctionappsa2023.name
}

# Backend configuration using locals
locals {
  resource_group_name  = azurerm_resource_group.rg.name
  storage_account_name = azurerm_storage_account.fitnessgeek-storage.name
  container_name       = azurerm_storage_container.container.name
  key                  = "prod/terraform.tfstate"
}

terraform {
  backend "azurerm" {
    resource_group_name   = local.resource_group_name
    storage_account_name  = local.storage_account_name
    container_name        = local.container_name
    key                   = local.key
  }
}
