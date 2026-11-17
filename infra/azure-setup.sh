#!/usr/bin/env bash
# Sekali jalan di Azure Cloud Shell (https://shell.azure.com, pilih Bash).
# Membuat resource Container Apps untuk environment development dan identitas
# OIDC agar GitHub Actions bisa deploy tanpa menyimpan password.
#
# Pakai: bash azure-setup.sh <github-owner> <github-repo>
set -euo pipefail

GITHUB_OWNER="${1:?github owner, contoh: dionisbalan27}"
GITHUB_REPO="${2:?github repo, contoh: hello-api-go}"

LOCATION="${LOCATION:-southeastasia}"
RG="rg-hello-api-go-dev"
ENV_NAME="cae-hello-api-go-dev"
APP_NAME="hello-api-go-dev"
IDENTITY_APP_NAME="github-${GITHUB_REPO}-deploy"
IMAGE="ghcr.io/${GITHUB_OWNER,,}/hello-api-go:development"

az extension add --name containerapp --upgrade --only-show-errors
az provider register --namespace Microsoft.App --wait
az provider register --namespace Microsoft.OperationalInsights --wait

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)

echo "==> resource group $RG di $LOCATION"
az group create --name "$RG" --location "$LOCATION" --output none

echo "==> container apps environment $ENV_NAME"
az containerapp env create --name "$ENV_NAME" --resource-group "$RG" --location "$LOCATION" --output none

echo "==> container app $APP_NAME (image awal: $IMAGE, harus public di GHCR)"
az containerapp create \
  --name "$APP_NAME" \
  --resource-group "$RG" \
  --environment "$ENV_NAME" \
  --image "$IMAGE" \
  --target-port 3000 \
  --ingress external \
  --min-replicas 0 \
  --max-replicas 1 \
  --cpu 0.25 --memory 0.5Gi \
  --env-vars APP_ENV=development PORT=3000 \
  --output none

echo "==> identitas OIDC untuk GitHub Actions"
CLIENT_ID=$(az ad app list --display-name "$IDENTITY_APP_NAME" --query "[0].appId" -o tsv)
if [ -z "$CLIENT_ID" ]; then
  CLIENT_ID=$(az ad app create --display-name "$IDENTITY_APP_NAME" --query appId -o tsv)
fi
OBJECT_ID=$(az ad app show --id "$CLIENT_ID" --query id -o tsv)
az ad sp create --id "$CLIENT_ID" --output none 2>/dev/null || true

az role assignment create \
  --assignee "$CLIENT_ID" \
  --role Contributor \
  --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG" \
  --output none

for SUBJECT in "repo:${GITHUB_OWNER}/${GITHUB_REPO}:ref:refs/heads/ci/development" "repo:${GITHUB_OWNER}/${GITHUB_REPO}:environment:development"; do
  NAME=$(echo "$SUBJECT" | tr ':/' '--')
  az ad app federated-credential create --id "$OBJECT_ID" --parameters "{
    \"name\": \"$NAME\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"$SUBJECT\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }" --output none 2>/dev/null || echo "   federated credential $NAME sudah ada"
done

FQDN=$(az containerapp show --name "$APP_NAME" --resource-group "$RG" --query properties.configuration.ingress.fqdn -o tsv)

cat <<EOF

Selesai. Isi secret ini di GitHub repo ${GITHUB_OWNER}/${GITHUB_REPO}
(Settings > Secrets and variables > Actions > New repository secret):

  AZURE_CLIENT_ID        = $CLIENT_ID
  AZURE_TENANT_ID        = $TENANT_ID
  AZURE_SUBSCRIPTION_ID  = $SUBSCRIPTION_ID

URL aplikasi: https://$FQDN
EOF
