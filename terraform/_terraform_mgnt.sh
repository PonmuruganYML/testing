#!/bin/bash

while getopts c:l:p:r:s:t:w: flag; do
    case "$flag" in
    c) COMMAND="$OPTARG" ;;           # deploy or autodelete
    l) LOCATION="$OPTARG" ;;          # local or remote
    p) AWS_PROFILE="$OPTARG" ;;       # Optional - operator platform
    r) AWS_REGION="$OPTARG" ;;        # Optional - region
    s) SERVICE_NAME="$OPTARG" ;;      # Optional - service name
    t) TARGET_MODULE="$OPTARG" ;;     # Optional - target module
    w) TF_WORKSPACE_NAME="$OPTARG" ;; # Optional - workspace name
    esac
done

TERRAFORM_TOKEN=""

echo command: $COMMAND
echo workspace: $TF_WORKSPACE_NAME
echo location: $LOCATION
echo target_module: $TARGET_MODULE
echo service: $SERVICE_NAME

if [ "$LOCATION" = "local" ]; then
    if [ -z "$TF_WORKSPACE_NAME" ]; then
        TF_WORKSPACE_NAME=$AWS_PROFILE-$SERVICE_NAME
    fi
fi

if [ -n "$TF_VAR_service_name" ]; then
    SERVICE_NAME="$TF_VAR_service_name"
fi

if [ -z "$COMMAND" ] || [ -z "$SERVICE_NAME" ] || [ -z "$LOCATION" ] || [ -z "$TF_WORKSPACE_NAME" ]; then
    echo "Invalid arguments passed: command: $COMMAND service: $SERVICE_NAME location: $LOCATION workspace: $TF_WORKSPACE_NAME"
    exit -1
fi

if [ "$LOCATION" = "local" ]; then
    if [ -z "$AWS_REGION" ] || [ -z "$AWS_PROFILE" ]; then
        echo "Invalid arguments passed: region: $AWS_REGION profile: $AWS_PROFILE"
        exit -1
    fi
    echo aws_region: $AWS_REGION
    echo aws_profile: $AWS_PROFILE
fi

function initEnv() {
    if [ "$LOCATION" = "local" ]; then
        export AWS_REGION=$AWS_REGION
        export AWS_PROFILE=$AWS_PROFILE
        export AWS_SDK_LOAD_CONFIG=1
    fi
}

function HelpInfo() {
    # Display Help
    echo "HELP INFORMATION"
    echo
    echo "Syntax: _terraform_mgmt.sh initiate|plan|deploy|delete|sync} <platform> <service_name> {local|remote} "
    echo "options:"
    echo "-c command to execute {init | plan | deploy | delete | autodelete | sync | delmodule}"
    echo "-p target platform to run the action on,e.g. -p rajdev-1"
    echo "-s service name"
    echo "-l running location {local | remote}"
    echo "-t optional module to delete. Used wuth delmodule."
    echo
    echo "make sure you have $HOME/.terraformrc copied to $HOME/.terraformrc-backup"
    echo "make sure you have $HOME/.terraformrc token extracted to $HOME/.terraformrc-token"
    echo
    echo
    echo
}

function setLocal() {
    if [ "$LOCATION" = "local" ]; then
        echo "*** Entering setLocal ***"
        TF_VAR_service_version="local"
        TF_BACKEND_ORGANIZATION=yml
        GIT_COMMIT=$(git rev-parse HEAD)
        GIT_TAG=$(git tag --points-at $USE_GIT_COMMIT)
        BUILD_TIMESTAMP=$(date '+%s')

        initEnv
        export TF_VAR_env=$(aws ssm get-parameter --name "/yc-operator-platform-service-v1/env" --query "Parameter.Value" --region $AWS_REGION --output text)
        export TF_VAR_operator=$(aws ssm get-parameter --name "/yc-operator-platform-service-v1/operator" --query "Parameter.Value" --region $AWS_REGION --output text)
        export TF_VAR_operator_platform=$(aws ssm get-parameter --name "/yc-operator-platform-service-v1/operator_platform" --query "Parameter.Value" --region $AWS_REGION --output text)
        export TF_VAR_operator_platform_domain=$(aws ssm get-parameter --name "/yc-operator-platform-service-v1/operator_platform_domain" --query "Parameter.Value" --region $AWS_REGION --output text)
        export TF_VAR_region_primary=$(aws ssm get-parameter --name "/yc-operator-platform-service-v1/region_primary" --query "Parameter.Value" --region $AWS_REGION --output text)
        export TF_VAR_region_secondary=$(aws ssm get-parameter --name "/yc-operator-platform-service-v1/region_secondary" --query "Parameter.Value" --region $AWS_REGION --output text)
        export TF_VAR_artifact_bucket=$(aws ssm get-parameter --name "/yc-operator-platform-service-v1/artifact_store" --query "Parameter.Value" --region $AWS_REGION --output text)
        export TF_VAR_artifact_bucket_region=$AWS_REGION
    fi
}

function createWorkspace() {
    echo "*** Entering createWorkspace ***"
    initEnv
    printf  organization = "yml" workspaces { name="ponmurugan-terraform-workspace" } >backend.tfvars
    # printf "organization = \"$TF_BACKEND_ORGANIZATION\"\nworkspaces { name = \"$TF_WORKSPACE_NAME\" }" >backend.tfvars
    if [ "$LOCATION" = "remote" ]; then
        printf "credentials "app.terraform.io" {\n  token = \"$TF_BACKEND_CREDS\"\n}" >$HOME/.terraformrc
        TERRAFORM_TOKEN=$(aws ssm get-parameter --name "/terraform/cloud/token" --query "Parameter.Value" --output text --with-decryption)
    else
        TERRAFORM_TOKEN=$(cat $HOME/.terraformrc-token)
    fi
}

function createVariables() {
    echo "*** Entering createVariables ***"
    if [ "$LOCATION" = "local" ]; then
        printf "{
    \"env\": \"$TF_VAR_env\",
    \"operator\": \"$TF_VAR_operator\",
    \"operator_platform\": \"$TF_VAR_operator_platform\",
    \"operator_platform_domain\": \"$TF_VAR_operator_platform_domain\",
    \"region_primary\": \"$TF_VAR_region_primary\",
    \"region_secondary\": \"$TF_VAR_region_secondary\",
    \"service_name\": \"$SERVICE_NAME\",
    \"service_version\": \"$TF_VAR_service_version\",
    \"artifact_bucket\": \"$TF_VAR_artifact_bucket\",
    \"artifact_bucket_region\": \"$TF_VAR_artifact_bucket_region\"
}" >service.tfvars.json
    fi
}

function initiate() {
    echo "*** Entering initiate ***"
    initEnv
    rm -rfR .terraform
    if [ "$LOCATION" = "remote" ]; then
        terraform init -no-color -input=false --backend-config="backend.tfvars"
    else
        terraform init -no-color --backend-config="backend.tfvars" -var-file service.tfvars.json
    fi
}

function terraformLocal() {
    echo "*** Entering terraformLocal ***"
    initEnv
    if [ -n "$TERRAFORM_TOKEN" ]; then
        echo "Setting Terraform cloud workspace to local execution... a workaround for them enabling remote by default."
        RESPONSE=$(curl --request PATCH --header 'Content-Type: application/vnd.api+json' --header "Authorization: Bearer $TERRAFORM_TOKEN" --data '{"data":{"attributes":{"operations":false}}}' --url https://app.terraform.io/api/v2/organizations/$TF_BACKEND_ORGANIZATION/workspaces/$TF_WORKSPACE_NAME)
        echo "RESPONSE: " $RESPONSE
    fi
}

function terraformDeleteWorkspace() {
    echo "*** Entering terraformDeleteWorkspace ***"
    initEnv
    if [ -n "$TERRAFORM_TOKEN" ]; then
        echo "Deleting terraform workspace $TF_WORKSPACE_NAME"
        RESPONSE=$(curl --request DELETE --header 'Content-Type: application/vnd.api+json' --header "Authorization: Bearer $TERRAFORM_TOKEN" --url https://app.terraform.io/api/v2/organizations/$TF_BACKEND_ORGANIZATION/workspaces/$TF_WORKSPACE_NAME)
        echo "RESPONSE: " $RESPONSE
    fi
}

function plan() {
    echo "*** Entering plan ***"
    initEnv
    terraform validate

    if [ "$LOCATION" = "remote" ]; then
        terraform plan -no-color -out=terraform.plan
    else
        terraform plan -var-file service.tfvars.json -out=terraform.plan
    fi
}

function deploy() {
    echo "*** Entering deploy ***"
    initEnv
    terraform apply -input=false -auto-approve -no-color terraform.plan
    terraform output -json >output.json
}

function destroyAll() {
    read -r -p "Are you sure? [y/N] " response
    if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        echo "*** previewing all destroyed resources ***"
        initEnv

        if [ "$LOCATION" = "remote" ]; then
            terraform plan -destroy
        else
            terraform plan -destroy -var-file service.tfvars.json
        fi

        read -r -p "Are you finally sure to delete all resources? [y/N] " response2
        if [[ "$response2" =~ ^([yY][eE][sS]|[yY])$ ]]; then
            echo "*** Destroying ALL Resources ***"
            initEnv
            if [ "$LOCATION" = "remote" ]; then
                terraform destroy
            else
                terraform destroy -var-file service.tfvars.json
            fi
        else
            echo "*** that was even dumber...***"
        fi
    else
        echo "*** that was dumb then...***"
    fi
}

function destroyAllAuto() {
    echo "*** Entering destroyAllAuto ***"
    initEnv
    if [ "$LOCATION" = "remote" ]; then
        terraform plan -destroy -no-color -out=destroy.plan
        terraform apply -input=false -auto-approve -no-color destroy.plan
        terraform output -json >output.json
        echo '*** Destroy completed ***'
    else
        terraform destroy -var-file service.tfvars.json
    fi
}

function destroyModule() {
    read -r -p "Are you sure? [y/N] to delete $TARGET_MODULE module? " response
    if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        echo "*** destroying $TARGET_MODULE module ***"
        initEnv

        if [ "$LOCATION" = "remote" ]; then
            terraform destroy -target module.$TARGET_MODULE
        else
            terraform destroy -target module.$TARGET_MODULE -var-file service.tfvars.json
        fi
    else
        echo "that was dumb then. "
    fi
}

function syncResources() {
    echo "*** Entering syncResources ***"
    initEnv

    if [ "$LOCATION" = "remote" ]; then
        terraform refresh -no-color
    else
        terraform refresh -var-file service.tfvars.json
    fi
}

function syncInlinePolicies() {
    echo "Syncing inline policies for all users. Invoking lambda function yc-usermgmt-service-v1-${TF_VAR_env}-sync"
    initEnv

    if [ "$LOCATION" = "remote" ]; then
      aws --version
      aws lambda invoke --cli-read-timeout 300 --function-name "yc-usermgmt-service-v1-${TF_VAR_env}-sync"  --payload '{ "source": "code-build" }' response.json
    else
        echo "Not implemented for local"
    fi

    echo "Finished syncing linine polcies for all users"
}

if [ "$LOCATION" = "local" ]; then
    echo '*** WARNING *** Setting running local configurations'
    setLocal
fi

case $COMMAND in
init)
    echo 'initiating...'
    createWorkspace
    initiate
    echo 'TODO: terraformLocal'

    echo '* initiated * '
    exit
    ;;
plan)
    echo 'planning...'
    createWorkspace
    createVariables
    initiate
    terraformLocal
    plan
    echo '** planned **'
    exit
    ;;
deploy)
    createWorkspace
    createVariables
    initiate
    terraformLocal
    plan
    deploy
    exit
    ;;
delete)
    echo 'deleting...'
    createWorkspace
    initiate
    createVariables
    destroyAll
    exit
    ;;
delmodule)
    echo 'deleting...'
    createWorkspace
    createVariables
    initiate
    destroyModule
    exit
    ;;
autodelete)
    createWorkspace
    createVariables
    initiate
    terraformLocal
    syncResources
    destroyAllAuto
    terraformDeleteWorkspace
    exit
    ;;
sync)
    echo 'syncing..'
    createVariables
    syncResources
    plan
    echo 'synced'
    exit
    ;;
deleteWorkspace)
    createWorkspace
    terraformDeleteWorkspace
    exit
    ;;
syncInlinePolicies)
    syncInlinePolicies
    exit
    ;;
help)
    HelpInfo
    exit
    ;;
*)
    echo $"*** Usage: $0 {init|plan|deploy|delete|sync|delmodule|syncInlinePolicies} <platform> <service_name> {local|remote} ***"
    echo $"*** Usage: $0 eg. initiate dharmadev helloworld local ***"
    exit 1
    ;;
esac

exit
