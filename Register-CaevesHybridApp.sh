#!/usr/bin/env bash
#
# Register-CaevesHybridApp.sh
#
# Registers an Azure AD application in YOUR tenant and creates a client secret
# (valid for 2 years) so the CAEVES Hybrid Environment deployment can
# authenticate as this application. Run this in Azure Cloud Shell (or any
# shell with the Azure CLI installed and "az login" already done) BEFORE
# filling out the CAEVES Hybrid Environment Marketplace deployment wizard.
#
# Prerequisites:
#   - You must be signed in to the Azure CLI ("az login") against the tenant
#     where the Hybrid Environment will be deployed.
#   - Your account needs the "Application Administrator" (or higher, e.g.
#     "Cloud Application Administrator" / Global Administrator) Azure AD
#     role in that tenant to create app registrations and credentials.
#
# What this script does:
#   1. Creates an Azure AD app registration.
#   2. Creates a service principal for that app registration.
#   3. Creates a client secret on the app registration with a 2-year expiry.
#   4. Prints the Tenant ID, Client ID, and Client Secret for you to copy
#      into the CAEVES Hybrid Environment deployment wizard.
#
# This script does NOT assign any Azure RBAC roles or Microsoft Graph API
# permissions to the application - it only creates the identity and secret.

set -euo pipefail

APP_DISPLAY_NAME="${1:-CAEVES-Hybrid-Envt-App}"

echo "Checking Azure CLI login..."
TENANT_ID="$(az account show --query tenantId -o tsv)"
echo "Using tenant: ${TENANT_ID}"

echo "Creating app registration '${APP_DISPLAY_NAME}'..."
CLIENT_ID="$(az ad app create --display-name "${APP_DISPLAY_NAME}" --query appId -o tsv)"
echo "Created app registration with Client ID: ${CLIENT_ID}"

echo "Creating service principal for the app registration..."
az ad sp create --id "${CLIENT_ID}" >/dev/null

echo "Creating client secret (expires in 2 years)..."
SECRET_END_DATE="$(date -u -d '+2 years' +%Y-%m-%dT%H:%M:%SZ)"
CLIENT_SECRET="$(az ad app credential reset \
  --id "${CLIENT_ID}" \
  --append \
  --end-date "${SECRET_END_DATE}" \
  --query password -o tsv)"

echo ""
echo "=================================================================="
echo " Registration complete. Copy these values into the CAEVES Hybrid"
echo " Environment deployment wizard. The Client Secret is shown only"
echo " once - it cannot be retrieved again after you close this shell."
echo "=================================================================="
echo " Tenant ID:      ${TENANT_ID}"
echo " Client ID:       ${CLIENT_ID}"
echo " Client Secret:   ${CLIENT_SECRET}"
echo "=================================================================="
