terraform {
  required_version = ">= 1.3.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.7.0, < 4.0.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

module "regions" {
  source  = "Azure/regions/azurerm"
  version = "=0.8.1"
}

# This ensures we have unique CAF compliant names for our resources.
module "naming" {
  source  = "Azure/naming/azurerm"
  version = ">= 0.3.0"
  suffix  = ["avd-monitoring"]
}

resource "azurerm_resource_group" "this" {
  location = var.location
  name     = module.naming.resource_group.name_unique
}

resource "azurerm_user_assigned_identity" "this" {
  location            = azurerm_resource_group.this.location
  name                = "uai-avd-dcr"
  resource_group_name = azurerm_resource_group.this.name
}

resource "azurerm_virtual_network" "this_vnet" {
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.this.location
  name                = module.naming.virtual_network.name_unique
  resource_group_name = azurerm_resource_group.this.name
}

resource "azurerm_subnet" "this_subnet_1" {
  address_prefixes     = ["10.0.1.0/24"]
  name                 = "${module.naming.subnet.name_unique}-1"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this_vnet.name
}

resource "azurerm_network_interface" "this" {
  count               = var.vm_count
  name                = "${var.avd_vm_name}-${count.index}-nic"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.this_subnet_1.id
    private_ip_address_allocation = "Dynamic"
  }
}

# Generate VM local password
resource "random_password" "vmpass" {
  length  = 20
  special = true
}

resource "azurerm_virtual_machine" "this" {
  count                 = var.vm_count
  location              = azurerm_resource_group.this.location
  name                  = "${module.naming.virtual_machine.name_unique}-${count.index}"
  network_interface_ids = [element(azurerm_network_interface.this.*.id, count.index)]
  resource_group_name   = azurerm_resource_group.this.name
  vm_size               = "Standard_D4s_v4"

  storage_os_disk {
    create_option     = "FromImage"
    name              = "${var.avd_vm_name}-${count.index}-osdisk"
    caching           = "ReadWrite"
    managed_disk_type = "Premium_LRS"
  }
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.this.id]
  }
  os_profile {
    admin_username = "adminuser"
    computer_name  = "${var.avd_vm_name}-${count.index}"
    admin_password = random_password.vmpass.result
  }
  os_profile_windows_config {
    provision_vm_agent = true
  }
  storage_image_reference {
    offer     = "windows-11"
    publisher = "microsoftwindowsdesktop"
    sku       = "win11-23h2-avd"
    version   = "latest"
  }
}

# Virtual Machine Extension for AMA agent
resource "azurerm_virtual_machine_extension" "ama" {
  count                     = var.vm_count
  name                      = "AzureMonitorWindowsAgent-${count.index}"
  publisher                 = "Microsoft.Azure.Monitor"
  type                      = "AzureMonitorWindowsAgent"
  type_handler_version      = "1.22"
  virtual_machine_id        = element(azurerm_virtual_machine.this.*.id, count.index)
  automatic_upgrade_enabled = true
}

module "azurerm_log_analytics_workspace" {
  source              = "Azure/log-analytics-workspace/azurerm"
  version             = "0.1.0"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  name                = module.naming.log_analytics_workspace.name_unique
  sku                 = "PerGB2018"
  retention_in_days   = 30
  
}

# This is the module that creates the data collection rule
module "dcr" {
  source                                                      = "../../"
  enable_telemetry                                            = var.enable_telemetry
  monitor_data_collection_rule_resource_group_name            = azurerm_resource_group.this.name
  name                                                        = "avddcr1"
  monitor_data_collection_rule_kind                           = "Windows"
  monitor_data_collection_rule_location                       = azurerm_resource_group.this.location
  monitor_data_collection_rule_name                           = "microsoft-avdi-eastus"
  monitor_data_collection_rule_association_target_resource_id = azurerm_virtual_machine.this.id
  monitor_data_collection_rule_data_flow = [
    {
      destinations = [azurerm_log_analytics_workspace.this.name]
      streams      = ["Microsoft-Perf", "Microsoft-Event"]
    }
  ]

  monitor_data_collection_rule_destinations = {
    log_analytics = {
      name                  = azurerm_log_analytics_workspace.this.name
      workspace_resource_id = azurerm_log_analytics_workspace.this.id
    }
  }

  monitor_data_collection_rule_data_sources = {
    performance_counter = [
      {
        counter_specifiers            = ["\\LogicalDisk(C:)\\Avg. Disk Queue Length", "\\LogicalDisk(C:)\\Current Disk Queue Length", "\\Memory\\Available Mbytes", "\\Memory\\Page Faults/sec", "\\Memory\\Pages/sec", "\\Memory\\% Committed Bytes In Use", "\\PhysicalDisk(*)\\Avg. Disk Queue Length", "\\PhysicalDisk(*)\\Avg. Disk sec/Read", "\\PhysicalDisk(*)\\Avg. Disk sec/Transfer", "\\PhysicalDisk(*)\\Avg. Disk sec/Write", "\\Processor Information(_Total)\\% Processor Time", "\\User Input Delay per Process(*)\\Max Input Delay", "\\User Input Delay per Session(*)\\Max Input Delay", "\\RemoteFX Network(*)\\Current TCP RTT", "\\RemoteFX Network(*)\\Current UDP Bandwidth"]
        name                          = "perfCounterDataSource10"
        sampling_frequency_in_seconds = 30
        streams                       = ["Microsoft-Perf"]
      },
      {
        counter_specifiers            = ["\\LogicalDisk(C:)\\% Free Space", "\\LogicalDisk(C:)\\Avg. Disk sec/Transfer", "\\Terminal Services(*)\\Active Sessions", "\\Terminal Services(*)\\Inactive Sessions", "\\Terminal Services(*)\\Total Sessions"]
        name                          = "perfCounterDataSource30"
        sampling_frequency_in_seconds = 60
        streams                       = ["Microsoft-Perf"]
      }
    ],
    windows_event_log = [
      {
        name           = "eventLogsDataSource"
        streams        = ["Microsoft-Event"]
        x_path_queries = ["Microsoft-Windows-TerminalServices-RemoteConnectionManager/Admin!*[System[(Level=2 or Level=3 or Level=4 or Level=0)]]", "Microsoft-Windows-TerminalServices-LocalSessionManager/Operational!*[System[(Level=2 or Level=3 or Level=4 or Level=0)]]", "System!*", "Microsoft-FSLogix-Apps/Operational!*[System[(Level=2 or Level=3 or Level=4 or Level=0)]]", "Application!*[System[(Level=2 or Level=3)]]", "Microsoft-FSLogix-Apps/Admin!*[System[(Level=2 or Level=3 or Level=4 or Level=0)]]"]
      }
    ]
  }
  target_resource_id = azurerm_virtual_machine.this.id
}
