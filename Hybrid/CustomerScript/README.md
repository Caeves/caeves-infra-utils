# Azure AD App Registration for CAEVES Hybrid Environment

Before deploying the CAEVES Hybrid Environment from Azure Marketplace, you must register an Azure AD application in your own tenant. The deployment wizard will ask you for the Tenant ID, Client ID, and Client Secret produced by this step.

## Prerequisites

- Access to [Azure Cloud Shell](https://shell.azure.com) (or a local shell with the Azure CLI installed and `az login` completed) signed in to the tenant where you will deploy the Hybrid Environment.
- Your account must hold the **Application Administrator** Azure AD role (or higher, e.g. Cloud Application Administrator or Global Administrator) in that tenant.

## Steps

1. Open [Azure Cloud Shell](https://shell.azure.com) and select **Bash**.
2. Review the script before running it, since it runs with Application Administrator privileges: [github.com/Caeves/caeves-infra-utils/blob/24e37036049d5f078c0df52736aac1766591b54d/Register-CaevesHybridApp.sh](https://github.com/Caeves/caeves-infra-utils/blob/24e37036049d5f078c0df52736aac1766591b54d/Register-CaevesHybridApp.sh)
3. Download and run the pinned version of the script (not `main`, so what you reviewed is exactly what you run):
   ```bash
   curl -O https://raw.githubusercontent.com/Caeves/caeves-infra-utils/24e37036049d5f078c0df52736aac1766591b54d/Register-CaevesHybridApp.sh
   bash Register-CaevesHybridApp.sh
   ```
   Optionally pass a custom display name for the app registration:
   ```bash
   bash Register-CaevesHybridApp.sh "CAEVES-Hybrid-Contoso-Prod"
   ```
4. Copy the **Tenant ID**, **Client ID**, and **Client Secret** printed at the end of the script.
5. Continue to the CAEVES Hybrid Environment deployment wizard in Azure Marketplace and paste these three values into the **Azure App Registration** step.

## Important

- The client secret is displayed **only once**. If you lose it, re-run the script (it will add a new secret without invalidating the app registration) and use the newly printed value.
- The secret expires **2 years** from the day it is created. Plan to rotate it (re-run this script and update the deployment) before then.
- This script only creates the app registration, its service principal, and a client secret. It does not grant any Azure roles or Microsoft Graph permissions.
