param prefix string
param location string = resourceGroup().location
param tags object = {}

// set runtime version specifically to Python 3.10. Update over time. You may get a build error if the packages require a more recent python version than what you specify.
param linuxFxVersion string = 'PYTHON|3.10'

var webAppName = '${prefix}-web-${uniqueString(resourceGroup().id)}'
var hostingPlanName = '${prefix}-plan-${uniqueString(resourceGroup().id)}'
var openAIAccountName = '${prefix}-oai-${uniqueString(resourceGroup().id)}'

// create an Azure Managed Redis instance with RediSearch configured
resource redisEnterprise 'Microsoft.Cache/redisEnterprise@2024-09-01-preview' = {
  name: '${prefix}-redis-${uniqueString(resourceGroup().id)}'
  location: location
  tags: tags
  sku: {
    name: 'Balanced_B5'
  }
  identity: {
    type: 'None'
  }
  properties: {
    minimumTlsVersion: '1.2'
    highAvailability: 'Enabled'
  }
}

resource redisdatabase 'Microsoft.Cache/redisEnterprise/databases@2024-09-01-preview' = {
  name: 'default'
  parent: redisEnterprise
  properties: {
    clientProtocol: 'Encrypted'
    port: 10000
    clusteringPolicy: 'EnterpriseCluster'
    evictionPolicy: 'NoEviction'
    modules: [
      {
        name: 'RediSearch'
      }
      {
        name: 'RedisJSON'
      }
    ]
    persistence: {
      aofEnabled: false
      rdbEnabled: false
    }
    deferUpgrade: 'NotDeferred'
    accessKeysAuthentication: 'Enabled'
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
  name: 'demo-gpt-4o'
  sku: {
    name: 'Standard'
    capacity: 100
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-4o'
    }
    currentCapacity: 100
  }
}

resource appServicePlan 'Microsoft.Web/serverfarms@2022-03-01' = {
  name: hostingPlanName
  location: location
  sku: {
    name: 'B2'
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
      // set up environment variables for your Redis and OpenAI connections
      //REDIS_ENDPOINT: redisEnterprise.properties.hostName
      REDIS_ENDPOINT: '${redisEnterprise.properties.hostName}:${redisdatabase.properties.port}' // AMR uses port 10000. We need to specify this because many libraries default to port 6379.
      REDIS_PASSWORD: redisdatabase.listKeys().primaryKey
      AZURE_OPENAI_ENDPOINT: openAIAccount.properties.endpoint
      AZURE_OPENAI_API_KEY: openAIAccount.listKeys().key1
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
