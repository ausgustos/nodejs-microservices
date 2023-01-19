#!/usr/bin/env bash
##############################################################################
# Usage: ./infra.sh <command> <project_name> [environment_name] [location]
# Manages the Azure infrastructure for this project.
##############################################################################
# v0.9.6 | dependencies: Azure CLI, jq, perl
##############################################################################

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
if [[ -f ".settings" ]]; then
  source .settings
fi

time=$(date +%s)
subcommand="${1:-}"
project_name="${2:-$project_name}"
environment="${environment:-prod}"
environment="${3:-$environment}"
location="${location:-eastus}"
location="${4:-$location}"
resource_group_name=rg-${project_name}-${environment}

showUsage() {
  script_name="$(basename "$0")"
  echo "Usage: ./$script_name <command> <project_name> [environment_name] [location]"
  echo "Manages the Azure infrastructure for this project."
  echo
  echo "Commands:"
  echo "  update   Creates or updates the infrastructure for this project."
  echo "  delete   Deletes the infrastructure for this project."
  echo "  cancel   Cancels the last infrastructure deployment."
  echo "  env      Retrieve settings for the target environment."
  echo
}

toUpperSnakeCase() {
  echo "${1}" |
    perl -pe 's/([a-z\d])([A-Z]+)/$1_$2/g' |
    perl -pe 's/[ _-]+/_/g' |
    perl -ne 'print uc'
}

createSettings() {
  env_file=".${environment}.env"

  echo "# Generated settings for environment '${environment}'" > "${env_file}"
  echo "# Do not edit this file manually!" >> "${env_file}"
  echo >> "${env_file}"
  echo "$1" | jq -c '. | to_entries[] | [.key, .value.value, .value.type]' |

  # For each output, export the value to the env file and convert the key to
  # lower snake case.
  while IFS=$'\n' read -r output; do
    ouput_name=$(toUpperSnakeCase "$(echo "$output" | jq -r '.[0]')")
    output_value=$(echo "$output" | jq -r '.[1] | @sh')
    if [ "$(echo "$output" | jq -r '.[2]')" == "Array" ]; then
      echo "${ouput_name}=(${output_value})" >> "${env_file}"
    else
      echo "${ouput_name}=${output_value}" >> "${env_file}"
    fi
  done
  echo "Settings for environment '${environment}' saved to '${env_file}'."
}

updateInfrastructure() {
  echo "Preparing environment '${environment}' of project '${project_name}'..."
  az group create \
    --name "${resource_group_name}" \
    --location "${location}" \
    --tags project="${project_name}" environment="${environment}" managedBy=blue \
    --output none
  echo "Resource group '${resource_group_name}' ready."
  outputs=$( \
    az deployment group create \
      --resource-group "${resource_group_name}" \
      --template-file infra/main.bicep \
      --name "deployment-${project_name}-${environment}-${location}" \
      --parameters projectName="${project_name}" \
          environment="${environment}" \
          location="${location}" \
      --query properties.outputs \
      --mode Complete \
      --verbose
  )
  createSettings "${outputs}"
  retrieveSecrets
  # echo "${outputs}" > outputs.json
  echo "Environment '${environment}' of project '${project_name}' ready."
}

deleteInfrastructure() {
  echo "Deleting environment '${environment}' of project '${project_name}'..."
  az group delete --yes --name "rg-${project_name}-${environment}"
  echo "Environment '${environment}' of project '${project_name}' deleted."
}

cancelInfrastructureDeployment() {
  echo "Cancelling preparation of environment '${environment}' of project '${project_name}'..."
  az deployment group cancel \
    --resource-group "${resource_group_name}" \
    --name "deployment-${project_name}-${environment}-${location}" \
    --verbose
  echo "Preparation of '${environment}' of project '${project_name}' cancelled."
}

retrieveEnvironmentSettings() {
  echo "Retrieving settings for environment '${environment}' of project '${project_name}'..."
  outputs=$( \
    az deployment group show \
      --resource-group "${resource_group_name}" \
      --name "deployment-${project_name}-${environment}-${location}" \
      --query properties.outputs \
  )
  createSettings "${outputs}"
}

retrieveSecrets() {
  secrets_sep="### Secrets ###"
  source ".${environment}.env"

  echo "Retrieving secrets for environment '${environment}' of project '${project_name}'..."

  env_file=".${environment}.env"
  echo -e "\n${secrets_sep}\n" >> "${env_file}"

  # Get registry credentials
  if [[ -n "${REGISTRY_NAME:-}" ]]; then
    REGISTRY_USERNAME=$( \
      az acr credential show \
        --name "${REGISTRY_NAME}" \
        --query "username" \
        --output tsv \
      )
    echo "REGISTRY_USERNAME='${REGISTRY_USERNAME}'" >> "${env_file}"

    REGISTRY_PASSWORD=$( \
      az acr credential show \
        --name "${REGISTRY_NAME}" \
        --query "passwords[0].value" \
        --output tsv \
      )
    echo "REGISTRY_PASSWORD='${REGISTRY_PASSWORD}'" >> "${env_file}"
  fi

  # Get storage account connection string
  if [[ -n "${STORAGE_ACCOUNT_NAME:-}" ]]; then
    STORAGE_ACCOUNT_CONNECTION_STRING=$( \
      az storage account show-connection-string \
        --name "${STORAGE_ACCOUNT_NAME}" \
        --query "connectionString" \
        --output tsv \
      )
    echo "STORAGE_ACCOUNT_CONNECTION_STRING='${STORAGE_ACCOUNT_CONNECTION_STRING}'" >> "${env_file}"
  fi

  # Get app insights instrumentation key and connection string
  if [[ -n "${APP_INSIGHTS_NAME:-}" ]]; then
    APP_INSIGHTS_INSTRUMENTATION_KEY=$( \
      az resource show \
        --resource-group "${resource_group_name}" \
        --resource-type "Microsoft.Insights/components" \
        --name "${APP_INSIGHTS_NAME}" \
        --query properties.InstrumentationKey \
        --output tsv \
      )
    echo "APP_INSIGHTS_INSTRUMENTATION_KEY='${APP_INSIGHTS_INSTRUMENTATION_KEY}'" >> "${env_file}"

    APP_INSIGHTS_CONNECTION_STRING=$( \
      az resource show \
        --resource-group "${resource_group_name}" \
        --resource-type "Microsoft.Insights/components" \
        --name "${APP_INSIGHTS_NAME}" \
        --query properties.ConnectionString \
        --output tsv \
      )
    echo "APP_INSIGHTS_CONNECTION_STRING='${APP_INSIGHTS_CONNECTION_STRING}'" >> "${env_file}"
  fi

  # Get cosmos db connection strings
  if [[ -n "${DATABASE_NAME:-}" ]]; then
    DATABASE_CONNECTION_STRING=$( \
      az cosmosdb keys list --type connection-strings \
        --name "${DATABASE_NAME}" \
        --resource-group "${resource_group_name}" \
        --query "connectionStrings[0].connectionString" \
        --output tsv \
      )
    echo "DATABASE_CONNECTION_STRING='${DATABASE_CONNECTION_STRING}'" >> "${env_file}"
  fi

  # TODO: retrieve other secrets (swa tokens, etc.)

  echo "Secrets for environment '${environment}' saved to '${env_file}'."
}

if [[ -z "$project_name" ]]; then
  showUsage
  echo "Error: project name is required."
  exit 1
fi

case "$subcommand" in
  update)
    updateInfrastructure
    ;;
  delete)
    deleteInfrastructure
    ;;
  cancel)
    cancelInfrastructureDeployment
    ;;
  env)
    retrieveEnvironmentSettings
    retrieveSecrets
    ;;
  *)
    showUsage
    echo "Error: unknown command '$subcommand'."
    exit 1
    ;;
esac
echo "Done in $(($(date +%s) - time))s"
