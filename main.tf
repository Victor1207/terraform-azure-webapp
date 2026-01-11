provider "azurerm" {
  features {}
  subscription_id = "8fb4ccc7-a8e3-4433-ae8f-29204aa114a9"
}

resource "azurerm_resource_group" "rg" {
  name     = "rg-terraform-demo"
  location = "Norway East"

  tags = {
    Environment = "Dev"
  }
}

# -------------------------------
# App Service Plan
# -------------------------------
resource "azurerm_service_plan" "asp" {
  name                = "asp-terraform-demo"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku_name            = "B1"
  os_type             = "Windows"

  tags = {
    Environment = "Dev"
  }
}

# -------------------------------
# Web App (Windows)
# -------------------------------
resource "azurerm_windows_web_app" "webapp" {
  name                = "webapp-terraform-demo"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  service_plan_id     = azurerm_service_plan.asp.id

  site_config {
    always_on = true
  }

  app_settings = {
    "WEBSITE_RUN_FROM_PACKAGE"           = "1"
    "APPINSIGHTS_INSTRUMENTATIONKEY"     = azurerm_application_insights.appinsights.instrumentation_key
    "APPLICATIONINSIGHTS_CONNECTION_STRING" = azurerm_application_insights.appinsights.connection_string
  }

  tags = {
    Environment = "Dev"
  }
}

# -------------------------------
# Log Analytics Workspace
# -------------------------------
resource "azurerm_log_analytics_workspace" "law" {
  name                = "law-terraform-demo"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30

  tags = {
    Environment = "Dev"
  }
}

# -------------------------------
# Application Insights
# -------------------------------
resource "azurerm_application_insights" "appinsights" {
  name                = "appi-terraform-demo"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  application_type    = "web"

  tags = {
    Environment = "Dev"
  }
}

# -------------------------------
# Azure Monitor Metric Alert: Example CPU Alert
# -------------------------------
resource "azurerm_monitor_metric_alert" "cpu_alert" {
  name                = "cpu-alert"
  resource_group_name = azurerm_resource_group.rg.name
  scopes              = [azurerm_service_plan.asp.id]   # <-- monitor App Service Plan
  description         = "Alert if CPU usage > 80% for 5 minutes"
  severity            = 3
  frequency           = "PT1M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.Web/serverfarms"
    metric_name      = "CpuPercentage"   # valid on App Service Plan
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 80
  }

  tags = {
    Environment = "Dev"
  }
}
resource "azurerm_monitor_autoscale_setting" "autoscale" {
  name                = "autoscale-webapp-demo"
  resource_group_name = azurerm_resource_group.rg.name
  target_resource_id  = azurerm_service_plan.asp.id
  location            = azurerm_resource_group.rg.location
  enabled             = true

  profile {
    name = "autoscale-cpu"

    capacity {
      minimum = "1"
      maximum = "3"
      default = "1"
    }

    # Scale up rule
    rule {
      metric_trigger {
        metric_name        = "CpuPercentage"
        metric_resource_id = azurerm_service_plan.asp.id
        time_grain         = "PT1M"
        time_window        = "PT5M"
        time_aggregation   = "Average"   # REQUIRED
        statistic          = "Average"   # REQUIRED in some provider versions
        operator           = "GreaterThan"
        threshold          = 70
      }

      scale_action {
        direction = "Increase"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT5M"
      }
    }

    # Scale down rule
    rule {
      metric_trigger {
        metric_name        = "CpuPercentage"
        metric_resource_id = azurerm_service_plan.asp.id
        time_grain         = "PT1M"
        time_window        = "PT5M"
        time_aggregation   = "Average"   # REQUIRED
        statistic          = "Average"   # REQUIRED in some provider versions
        operator           = "LessThan"
        threshold          = 30
      }

      scale_action {
        direction = "Decrease"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT5M"
      }
    }
  }

  tags = {
    Environment = "Dev"
  }
}

resource "azurerm_application_insights_web_test" "availability_test" {
  name                    = "webapp-availability-test"
  location                = azurerm_resource_group.rg.location
  resource_group_name     = azurerm_resource_group.rg.name
  application_insights_id = azurerm_application_insights.appinsights.id
  kind                    = "ping"
  frequency               = 300
  timeout                 = 30

  geo_locations = [
    "emea-gb-db3-azr",
    "emea-fr-pra-edge",
    "emea-se-sto-edge",
  ]

  configuration = <<XML
<WebTest Name="webapp-availability-test" Enabled="True" Timeout="30" Frequency="300" xmlns="http://microsoft.com/schemas/VisualStudio/TeamTest/2010">
  <Items>
    <Request Method="GET" Url="https://webapp-terraform-demo.azurewebsites.net/" />
  </Items>
</WebTest>
XML

  tags = {
    Environment = "Dev"
  }
}

resource "azurerm_monitor_action_group" "alerts" {
  name                = "ag-webapp-alerts"
  resource_group_name = azurerm_resource_group.rg.name
  short_name          = "webalert"

  email_receiver {
    name          = "admin"
    email_address = "v.m.olasehinde@student.vu.nl"
  }

  tags = {
    Environment = "Dev"
  }
}

# -------------------------------
# Availability Alert (KQL)
# -------------------------------
resource "azurerm_monitor_scheduled_query_rules_alert" "availability_alert" {
  name                = "webapp-availability-alert"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  data_source_id = azurerm_application_insights.appinsights.id
  description    = "Alert when availability test fails"
  enabled        = true
  severity       = 2

  query = <<KQL
availabilityResults
| where timestamp > ago(8760m)
| where success == false
| summarize AggregatedValue = count()
KQL

  frequency   = 5
  time_window = 5

  trigger {
    operator  = "GreaterThan"
    threshold = 0
  }

  action {
    action_group = [
      azurerm_monitor_action_group.alerts.id
    ]
  }

  tags = {
    Environment = "Dev"
  }
}
