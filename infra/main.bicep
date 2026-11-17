// Infrastruktur hello-api-go untuk satu environment (dev/prod) dalam satu resource group.
// Dijalankan oleh pipeline: az deployment group create --template-file infra/main.bicep
targetScope = 'resourceGroup'

@description('Nama environment: dev atau prod')
@allowed(['dev', 'prod'])
param environmentName string = 'dev'

@description('Lokasi resource, default mengikuti resource group')
param location string = resourceGroup().location

@description('Nama aplikasi, dipakai sebagai prefix nama resource')
param appName string = 'hello-api-go'

@description('Image container yang dideploy. Default image quickstart Microsoft untuk deploy pertama sebelum image sendiri ada di ACR.')
param containerImage string = 'mcr.microsoft.com/k8se/quickstart:latest'

@description('Port yang didengarkan container')
param targetPort int = 3000

var suffix = uniqueString(resourceGroup().id)
var tags = {
  app: appName
  environment: environmentName
  managedBy: 'bicep'
}

// Log Analytics: tujuan log container (stdout/stderr) dan metrik environment.
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: 'log-${appName}-${environmentName}'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// Azure Container Registry: tempat image dari pipeline. Admin user dimatikan,
// akses tarik image lewat managed identity (AcrPull), push lewat identitas GitHub.
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: 'acr${replace(appName, '-', '')}${suffix}'
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
  }
}

// Identitas container app untuk menarik image dari ACR tanpa password.
resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${appName}-${environmentName}'
  location: location
  tags: tags
}

var acrPullRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')

resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, identity.id, acrPullRoleId)
  scope: acr
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: acrPullRoleId
  }
}

// Container Apps environment (padanan namespace/cluster di Adhara).
resource containerEnv 'Microsoft.App/managedEnvironments@2023-05-01' = {
  name: 'cae-${appName}-${environmentName}'
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
  }
}

// Container app: ingress publik HTTPS, probe ke /health, scale 0..1 untuk dev.
resource containerApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: '${appName}-${environmentName}'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: containerEnv.id
    configuration: {
      ingress: {
        external: true
        targetPort: targetPort
        transport: 'auto'
        allowInsecure: false
      }
      registries: [
        {
          server: acr.properties.loginServer
          identity: identity.id
        }
      ]
    }
    template: {
      containers: [
        {
          name: appName
          image: containerImage
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          env: [
            { name: 'APP_ENV', value: environmentName }
            { name: 'PORT', value: string(targetPort) }
          ]
          probes: [
            {
              type: 'Readiness'
              httpGet: {
                path: '/health'
                port: targetPort
              }
              initialDelaySeconds: 3
              periodSeconds: 10
            }
            {
              type: 'Liveness'
              httpGet: {
                path: '/health'
                port: targetPort
              }
              initialDelaySeconds: 10
              periodSeconds: 30
            }
          ]
        }
      ]
      scale: {
        minReplicas: environmentName == 'prod' ? 1 : 0
        maxReplicas: environmentName == 'prod' ? 3 : 1
        rules: [
          {
            name: 'http'
            http: {
              metadata: {
                concurrentRequests: '50'
              }
            }
          }
        ]
      }
    }
  }
  dependsOn: [
    acrPull
  ]
}

output acrLoginServer string = acr.properties.loginServer
output acrName string = acr.name
output containerAppName string = containerApp.name
output appUrl string = 'https://${containerApp.properties.configuration.ingress.fqdn}'
output logAnalyticsWorkspaceId string = logAnalytics.id
