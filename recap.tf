resource "azurerm_service_plan" "fe-asp" {
  name                = "fe-asp-prod"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  os_type             = "Linux"
  sku_name            = "B1"
  depends_on = [
    azurerm_subnet.fe-subnet
  ]
}



resource "azurerm_service_plan" "be-asp" {
  name                = "be-asp-prod"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  os_type             = "Linux"
  sku_name            = "B1"
  depends_on = [
    azurerm_subnet.be-subnet
  ]
}


#Frontend
# Create the web app, pass in the App Service Plan ID
resource "azurerm_linux_web_app" "fe-webapp" {
  name                  = "fitnessgeek"
  location              = azurerm_resource_group.rg.location
  resource_group_name   = azurerm_resource_group.rg.name
  service_plan_id       = azurerm_service_plan.fe-asp.id
  https_only            = true
  site_config { 
    minimum_tls_version = "1.2"
    always_on = true

    application_stack {
      node_version = "16-lts"
    }
  }
  
  app_settings = {

    "APPINSIGHTS_INSTRUMENTATIONKEY"                  = azurerm_application_insights.fg-appinsights.instrumentation_key
    "APPINSIGHTS_PROFILERFEATURE_VERSION"             = "1.0.0"
    "ApplicationInsightsAgent_EXTENSION_VERSION"      = "~2"
  }

  
  depends_on = [
    azurerm_service_plan.fe-asp,azurerm_application_insights.fg-appinsights
  ]
}

#Backend
#storage account for functionapp
resource "azurerm_storage_account" "fn-storageaccount" {
  name                     = "fgfunctionappsa2023"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_linux_function_app" "be-fnapp" {
  name                = "be-function-app"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  storage_account_name       = azurerm_storage_account.fn-storageaccount.name
  storage_account_access_key = azurerm_storage_account.fn-storageaccount.primary_access_key
  service_plan_id            = azurerm_service_plan.be-asp.id
  

  app_settings = {

    "APPINSIGHTS_INSTRUMENTATIONKEY"                  = azurerm_application_insights.fg-appinsights.instrumentation_key
    "APPINSIGHTS_PROFILERFEATURE_VERSION"             = "1.0.0"
    "ApplicationInsightsAgent_EXTENSION_VERSION"      = "~2"
    
  
  }

  site_config {

  ip_restriction {
          virtual_network_subnet_id = azurerm_subnet.fe-subnet.id
          priority = 100
          name = "Frontend access only"
           }
  application_stack {
      python_version = 3.8
    }
  }

  identity {
  type = "SystemAssigned"
   }

 depends_on = [
   azurerm_storage_account.fn-storageaccount
 ]
}

#vnet integration of backend functions
resource "azurerm_app_service_virtual_network_swift_connection" "be-vnet-integration" {
  app_service_id = azurerm_linux_function_app.be-fnapp.id
  subnet_id      = azurerm_subnet.be-subnet.id
  depends_on = [
    azurerm_linux_function_app.be-fnapp
  ]
}

#vnet integration of backend functions
resource "azurerm_app_service_virtual_network_swift_connection" "fe-vnet-integration" {
  app_service_id = azurerm_linux_web_app.fe-webapp.id
  subnet_id      = azurerm_subnet.fe-subnet.id

  depends_on = [
    azurerm_linux_web_app.fe-webapp
  ]
}



# location-rg = "uksouth"

#Create Random password 
resource "random_password" "randompassword" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

#Create Key Vault Secret
resource "azurerm_key_vault_secret" "sqladminpassword" {
  # checkov:skip=CKV_AZURE_41:Expiration not needed 
  name         = "sqladmin"
  value        = random_password.randompassword.result
  key_vault_id = azurerm_key_vault.fg-keyvault.id
  content_type = "text/plain"
  depends_on = [
    azurerm_key_vault.fg-keyvault,azurerm_key_vault_access_policy.kv_access_policy_01,azurerm_key_vault_access_policy.kv_access_policy_02,azurerm_key_vault_access_policy.kv_access_policy_03
  ]
}

#Azure sql database
resource "azurerm_mssql_server" "azuresql" {
  name                         = "fg-sqldb-prod"
  resource_group_name          = azurerm_resource_group.rg.name
  location                     = azurerm_resource_group.rg.location
  version                      = "12.0"
  administrator_login          = "4adminu$er"
  administrator_login_password = random_password.randompassword.result

  azuread_administrator {
    login_username = "AzureAD Admin"
    object_id      = "86f50fc0-0d0d-4c26-941d-17dd64ed03a6"
  }
}

#add subnet from the backend vnet
#adding a new comment in main branch
resource "azurerm_mssql_virtual_network_rule" "allow-be" {
  name      = "be-sql-vnet-rule"
  server_id = azurerm_mssql_server.azuresql.id
  subnet_id = azurerm_subnet.be-subnet.id
  depends_on = [
    azurerm_mssql_server.azuresql
  ]
}

resource "azurerm_mssql_database" "fg-database" {
  name           = "fg-db"
  server_id      = azurerm_mssql_server.azuresql.id
  collation      = "SQL_Latin1_General_CP1_CI_AS"
  max_size_gb    = 2
  read_scale     = false
  sku_name       = "S0"
  zone_redundant = false

  tags = {
    Application = "Fitnessgeek-demo"
    Env = "Prod"
  }
}

resource "azurerm_key_vault_secret" "sqldb_cnxn" {
  name = "fgsqldbconstring"
  value = "Driver={ODBC Driver 18 for SQL Server};Server=tcp:fg-sqldb-prod.database.windows.net,1433;Database=fg-db;Uid=4adminu$er;Pwd=${random_password.randompassword.result};Encrypt=yes;TrustServerCertificate=no;Connection Timeout=30;"
  key_vault_id = azurerm_key_vault.fg-keyvault.id
  depends_on = [
    azurerm_mssql_database.fg-database,azurerm_key_vault_access_policy.kv_access_policy_01,azurerm_key_vault_access_policy.kv_access_policy_02,azurerm_key_vault_access_policy.kv_access_policy_03
  ]
}

data "azurerm_client_config" "current" {}



resource "azurerm_key_vault" "fg-keyvault" {
  name                        = "fgkeyvault2024"
  location                    = azurerm_resource_group.rg.location
  resource_group_name         = azurerm_resource_group.rg.name
  enabled_for_disk_encryption = true
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  soft_delete_retention_days  = 7
  purge_protection_enabled    = false
  sku_name                    = "standard"


}

resource "azurerm_key_vault_access_policy" "kv_access_policy_01" {
  #This policy adds databaseadmin group with below permissions
  key_vault_id       = azurerm_key_vault.fg-keyvault.id
  tenant_id          = data.azurerm_client_config.current.tenant_id
  object_id          = "86f50fc0-0d0d-4c26-941d-17dd64ed03a6"
  key_permissions    = ["Get", "List"]
  secret_permissions = ["Get", "Backup", "Delete", "List", "Purge", "Recover", "Restore", "Set"]

  depends_on = [azurerm_key_vault.fg-keyvault]
}

resource "azurerm_key_vault_access_policy" "kv_access_policy_02" {
  #This policy adds databaseadmin group with below permissions
  key_vault_id       = azurerm_key_vault.fg-keyvault.id
  tenant_id          = data.azurerm_client_config.current.tenant_id
  object_id          = "da96d180-3c89-4f4d-b1c3-2c67dec3218c"
  key_permissions    = ["Get", "List"]
  secret_permissions = ["Get", "Backup", "Delete", "List", "Purge", "Recover", "Restore", "Set"]

  depends_on = [azurerm_key_vault.fg-keyvault]
}


resource "azurerm_key_vault_access_policy" "kv_access_policy_03" {
  #This policy adds databaseadmin group with below permissions
  key_vault_id       = azurerm_key_vault.fg-keyvault.id
  tenant_id          = data.azurerm_client_config.current.tenant_id
  object_id          = "ef581861-a1a9-4d40-9fcb-cd6f6b97bf4b"
  key_permissions    = ["Get", "List"]
  secret_permissions = ["Get", "Backup", "Delete", "List", "Purge", "Recover", "Restore", "Set"]

  depends_on = [azurerm_key_vault.fg-keyvault]
}

resource "azurerm_log_analytics_workspace" "fg-loganalytics" {
  name                = "fg-la-workspace"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_application_insights" "fg-appinsights" {
  name                = "fg-appinsights"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  workspace_id        = azurerm_log_analytics_workspace.fg-loganalytics.id
  application_type    = "web"
  depends_on = [
    azurerm_log_analytics_workspace.fg-loganalytics
  ]
}

output "instrumentation_key" {
  value = azurerm_application_insights.fg-appinsights.instrumentation_key
  sensitive = true
}

output "app_id" {
  value = azurerm_application_insights.fg-appinsights.id
  sensitive = true
}

# Configure the Azure provider
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0.2"
    }
  }

  required_version = ">= 1.1.0"
  backend "azurerm" {}

}

provider "azurerm" {
  features {}
}



resource "azurerm_resource_group" "rg" {
  name     = "Fitnessgeek-rg"
  location = var.location-rg
  tags = {
    "Application" = "DemoApp"
  }
}


output "frontend_url" {
  
  value = "${azurerm_linux_web_app.fe-webapp.name}.azurewebsites.net"
}

output "backedn_url" {
  
  value = "${azurerm_linux_function_app.be-fnapp.name}.azurewebsites.net"
}


resource "azurerm_storage_account" "fitnessgeek-storage" {
  name                     = "fgstorageaccount1989"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "GRS"

  tags = {
    environment = "staging"
  }
}

variable "location-rg" {
  description = "This is variable for location"  
  
}

# Create a virtual network
resource "azurerm_virtual_network" "vnet" {
  name                = "fitnessgeek-vnet-test"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}


#get output variables
output "resource_group_id" {
  value = azurerm_resource_group.rg.id
}

#Create subnets
resource "azurerm_subnet" "fe-subnet" {
  name                 = "fe-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.0.0/26"]
  service_endpoints = ["Microsoft.Web"]

  delegation {
    name = "delegation"

    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action","Microsoft.Network/virtualNetworks/subnets/join/action", "Microsoft.Network/virtualNetworks/subnets/prepareNetworkPolicies/action"]
    }


  }

  lifecycle {
    ignore_changes = [
      delegation,
    ]
  }
}

#Create subnets
resource "azurerm_subnet" "be-subnet" {
  name                 = "be-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.0.64/26"]
  service_endpoints = ["Microsoft.Sql"]

  delegation {
    name = "delegation"

    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action","Microsoft.Network/virtualNetworks/subnets/join/action", "Microsoft.Network/virtualNetworks/subnets/prepareNetworkPolicies/action"]
    }


  }

  lifecycle {
    ignore_changes = [
      delegation,
    ]
  }
}


