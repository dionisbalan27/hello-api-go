#!/usr/bin/env bash
# Sekali jalan di Azure Cloud Shell (https://shell.azure.com, Bash) sebagai Owner subscription.
# Hanya membuat hal yang tidak bisa dibuat pipeline sendiri: resource group dan
# identitas GitHub Actions (OIDC). Semua resource lain dibuat pipeline lewat Bicep.
#
# Pakai: bash bootstrap.sh <github-owner> <github-repo> [environment]
set -euo pipefail

GITHUB_OWNER="${1:?github owner, contoh: dionisbalan27}"
GITHUB_REPO="${2:?github repo, contoh: hello-api-go}"
ENVIRONMENT="${3:-dev}"
LOCATION="${LOCATION:-southeastasia}"

APP_NAME="hello-api-go"
RG="rg-${APP_NAME}-${ENVIRONMENT}"
IDENTITY_APP_NAME="github-${GITHUB_REPO}-${ENVIRONMENT}"

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)

az provider register --namespace Microsoft.App --wait
az provider register --namespace Microsoft.ContainerRegistry --wait
az provider register --namespace Microsoft.OperationalInsights --wait

echo "==> resource group $RG ($LOCATION)"
az group create --name "$RG" --location "$LOCATION" --tags app=$APP_NAME environment=$ENVIRONMENT --output none

echo "==> app registration $IDENTITY_APP_NAME untuk GitHub Actions"
CLIENT_ID=$(az ad app list --display-name "$IDENTITY_APP_NAME" --query "[0].appId" -o tsv)
if [ -z "$CLIENT_ID" ]; then
  CLIENT_ID=$(az ad app create --display-name "$IDENTITY_APP_NAME" --query appId -o tsv)
fi
OBJECT_ID=$(az ad app show --id "$CLIENT_ID" --query id -o tsv)
az ad sp create --id "$CLIENT_ID" --output none 2>/dev/null || true
SP_OBJECT_ID=$(az ad sp show --id "$CLIENT_ID" --query id -o tsv)

# Contributor untuk membuat resource, User Access Administrator agar Bicep boleh
# memberi role AcrPull ke managed identity. Keduanya hanya di resource group ini.
for ROLE in "Contributor" "User Access Administrator"; do
  az role assignment create \
    --assignee-object-id "$SP_OBJECT_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "$ROLE" \
    --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG" \
    --output none
done

# Token OIDC GitHub dipercaya hanya untuk branch ci/development dan environment GitHub "development".
# Subject claim GitHub kini menyertakan ID pemilik dan ID repo (owner@id/repo@id); keduanya diambil
# dari API publik GitHub. Format lama tanpa ID tetap didaftarkan untuk kompatibilitas.
OWNER_ID=$(curl -fsS "https://api.github.com/users/${GITHUB_OWNER}" | sed -n 's/^  "id": \([0-9]*\),/\1/p' | head -1)
REPO_ID=$(curl -fsS "https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}" | sed -n 's/^  "id": \([0-9]*\),/\1/p' | head -1)
REPO_CLAIMS="${GITHUB_OWNER}/${GITHUB_REPO}"
if [ -n "$OWNER_ID" ] && [ -n "$REPO_ID" ]; then
  REPO_CLAIMS="${GITHUB_OWNER}@${OWNER_ID}/${GITHUB_REPO}@${REPO_ID} ${REPO_CLAIMS}"
else
  echo "   peringatan: ID GitHub tidak terbaca, hanya subject tanpa ID yang didaftarkan"
fi
SUBJECTS=""
for CLAIM in $REPO_CLAIMS; do
  SUBJECTS="$SUBJECTS repo:${CLAIM}:ref:refs/heads/ci/development repo:${CLAIM}:environment:development"
done
for SUBJECT in $SUBJECTS; do
  NAME=$(echo "$SUBJECT" | tr ':/@' '---')
  az ad app federated-credential create --id "$OBJECT_ID" --parameters "{
    \"name\": \"$NAME\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"$SUBJECT\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }" --output none 2>/dev/null || echo "   federated credential $NAME sudah ada"
done

cat <<EOF

Selesai. Isi secret ini di GitHub repo ${GITHUB_OWNER}/${GITHUB_REPO}
(Settings > Secrets and variables > Actions):

  AZURE_CLIENT_ID        = $CLIENT_ID
  AZURE_TENANT_ID        = $TENANT_ID
  AZURE_SUBSCRIPTION_ID  = $SUBSCRIPTION_ID

Lalu buat environment GitHub bernama "development" dan push ke branch ci/development.
Resource group: $RG
EOF
