param prefix string
param location string = resourceGroup().location
param tags object = {}

// set runtime version specifically to Python 3.9. Update over time.
param linuxFxVersion string = 'PYTHON|3.9'

var webAppName = '${prefix}-web-${uniqueString(resourceGroup().id)}'
var hostingPlanName = '${prefix}-plan-${uniqueString(resourceGroup().id)}'
var openAIAccountName = '${prefix}-oai-${uniqueString(resourceGroup().id)}'

// create an Azure Managed Redis instance with RediSearch configured
resource redisEnterprise 'Microsoft.Cache/redisEnterprise@2024-09-01-preview' = {
  name: '${prefix}-redis-${uniqueString(resourceGroup().id)}'
  location: location
  tags: tags
  properties: {
    highAvailability: 'Enabled'
  }
  sku: {
    name: 'Balanced_B0'
  }
}

resource redisdatabase 'Microsoft.Cache/redisEnterprise/databases@2024-09-01-preview' = {
  name: 'default'
  parent: redisEnterprise
  properties: {
    accessKeysAuthentication: 'Enabled'
    evictionPolicy: 'NoEviction'
    clusteringPolicy: 'EnterpriseCluster'
    modules: [
      {
        name: 'RediSearch'
      }
      {
        name: 'RedisJSON'
      }
    ]
    port: 10000
  }
}

resource openAIAccount 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: openAIAccountName
  location: location
  sku: {
    name: 'S0'
  }
  kind: 'OpenAI'
  properties: {
    publicNetworkAccess: 'Enabled'
  }
}

resource gpt4o 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: openAIAccount
  name: 'my-gpt-4o'
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-4o'
    }
  }
}

resource appServicePlan 'Microsoft.Web/serverfarms@2022-03-01' = {
  name: hostingPlanName
  location: location
  sku: {
    name: 'F1'
  }
  kind: 'linux'
  properties: {
    reserved: true
  }
}

resource web 'Microsoft.Web/sites@2022-03-01' = {
  name: webAppName
  location: location
  tags: union(tags, { 'azd-service-name': 'web' })
  kind: 'app,linux'
  properties: {
    serverFarmId: appServicePlan.id
    siteConfig: {
      appSettings: [
        {
          // endpoint to the Redis instance. This is pulled automatically from the Redis resource that was just provisioned.
          name: 'REDIS_ENDPOINT'
          value: redisEnterprise.properties.hostName
        }
        {
          // password for the Redis instance that was just created
          name: 'REDIS_PASSWORD'
          value: redisdatabase.properties.accessKeysAuthentication.key1
        }
        {
          // endpoint for the Azure OpenAI account that was just created
          name: 'AZURE_OPENAI_ENDPOINT'
          value: openAIAccount.properties.endpoint
        }
        {
          // password for the Azure OpenAI account that was just created
          name: 'AZURE_OPENAI_API_KEY'
          value: openAIAccount.listKeys().key1
        }
      ]
      linuxFxVersion: linuxFxVersion
      ftpsState: 'Disabled'
      appCommandLine: 'startup.sh'
    }
    httpsOnly: true
  }
  identity: {
    type: 'SystemAssigned'
  }

  resource appSettings 'config' = {
    name: 'appsettings'
    properties: {
      SCM_DO_BUILD_DURING_DEPLOYMENT: 'true'
      ENABLE_ORYX_BUILD: 'true'
    }
  }

  resource logs 'config' = {
    name: 'logs'
    properties: {
      applicationLogs: {
        fileSystem: {
          level: 'Verbose'
        }
      }
      detailedErrorMessages: {
        enabled: true
      }
      failedRequestsTracing: {
        enabled: true
      }
      httpLogs: {
        fileSystem: {
          enabled: true
          retentionInDays: 1
          retentionInMb: 35
        }
      }
    }
  }
}

output WEB_URI string = 'https://${web.properties.defaultHostName}'
