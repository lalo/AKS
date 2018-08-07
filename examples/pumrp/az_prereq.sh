#!/bin/bash

set -e

VERSION=6

AZURE_SUBSCRIPTION_ID=8ecadfc9-d1a3-4ea4-b844-0d9f87e4d7c8
LOCATION=westus2
RESOURCE_GROUP_NAME="edusParts$VERSION"
CLUSTER_NAME="edusPartsCluster$VERSION"
CONTAINER_REGISTRY_NAME="edusPartsRegistry$VERSION"
DB_NAME="edus-docdb-test$VERSION"
SERVICE_PRINCIPAL_NAME=acrpu-kube-principal

echo ........ Logging into Azure
#az login
#az account set --subscription $AZURE_SUBSCRIPTION_ID
echo ........

echo ........ Creating resource group
az group create -l $LOCATION -n $RESOURCE_GROUP_NAME
echo ........

echo ........ Creating AKS cluster
az aks create --resource-group $RESOURCE_GROUP_NAME --name $CLUSTER_NAME --enable-rbac
echo ........

echo ........ Getting KubeConfig
scriptDir="$( cd "$(dirname "$0")" ; pwd -P )"
kubeConfigPath="$scriptDir/config"

az aks get-credentials --resource-group $RESOURCE_GROUP_NAME --name $CLUSTER_NAME --file $kubeConfigPath

export KUBECONFIG=$kubeConfigPath
echo ........

echo ........ Installing Helm on cluster
kubectl apply -f helm-service-account.yaml
helm init --service-account tiller --wait
echo ........

echo ........ MongoDB
# Set variables for the new account, database, and collection

# Create a MongoDB API Cosmos DB account
az cosmosdb create \
	--name $DB_NAME \
	--kind MongoDB \
	--resource-group $RESOURCE_GROUP_NAME \
	--max-interval 10 \
	--max-staleness-prefix 200

az cosmosdb database create \
	--name $DB_NAME \
	--db-name pumrp \
	--resource-group $RESOURCE_GROUP_NAME

# Get the connection string for MongoDB apps
mongo_conn_temp=$(az cosmosdb list-connection-strings \
	--name $DB_NAME \
    --query 'connectionStrings[0].connectionString' \
    --resource-group $RESOURCE_GROUP_NAME -o table | tail -1)

mongo_conn=${mongo_conn_temp/?ssl=true/pumrp?ssl=true}
#mongo_conn=$mongo_conn_temp


echo ........ Mongo: $mongo_conn
echo ........

echo ........ Creating CR
az acr create --resource-group $RESOURCE_GROUP_NAME --name $CONTAINER_REGISTRY_NAME --sku Basic
az acr login --name $CONTAINER_REGISTRY_NAME
acrLoginServer=$(az acr list --resource-group $RESOURCE_GROUP_NAME --query "[].{acrLoginServer:loginServer}" --output table | tail -1)
echo ........
echo $acrLoginServer
echo ........

echo ........ Setting secret for image registry
# https://docs.microsoft.com/en-us/azure/container-registry/container-registry-auth-aks

# que correo poner?
DOCKER_EMAIL=edus@microsoft.com

# Populate the ACR login server and resource id.
ACR_LOGIN_SERVER=$(az acr show --name $CONTAINER_REGISTRY_NAME --query loginServer --output tsv)
ACR_REGISTRY_ID=$(az acr show --name $CONTAINER_REGISTRY_NAME --query id --output tsv)

# Create a 'Reader' role assignment with a scope of the ACR resource.
! az ad sp delete --id http://$SERVICE_PRINCIPAL_NAME
SP_PASSWD=$(az ad sp create-for-rbac --name $SERVICE_PRINCIPAL_NAME --role Reader --scopes $ACR_REGISTRY_ID --query password --output tsv)

# Get the service principal client id.
CLIENT_ID=$(az ad sp show --id http://$SERVICE_PRINCIPAL_NAME --query appId --output tsv)

! kubectl delete secret acr-auth
kubectl create secret docker-registry acr-auth --docker-server $acrLoginServer --docker-username $CLIENT_ID --docker-password $SP_PASSWD --docker-email $DOCKER_EMAIL

echo ........ patching
kubectl patch serviceaccount default -p '{"imagePullSecrets": [{"name": "acr-auth"}]}'

echo ........

echo ........ cloning

#git clone https://github.com/Microsoft/PartsUnlimitedMRPmicro.git
echo ........

echo ........ building and pushing zipkin image
pushd PartsUnlimitedMRPmicro

docker run --rm -v $scriptDir/PartsUnlimitedMRPmicro/ZipkinServer:/project -w /project --name gradle gradle:3.4.1-jdk8-alpine gradle build

docker build -f ./ZipkinServer/Dockerfile --build-arg port=9411 -t ${acrLoginServer}/zipkin:v1.0 .

docker push ${acrLoginServer}/zipkin:v1.0
popd
echo ........

echo ........ building and pushing apigateway image
pushd PartsUnlimitedMRPmicro

docker run --rm -v $scriptDir/PartsUnlimitedMRPmicro/RestAPIGateway:/project -w /project --name gradle gradle:3.4.1-jdk8-alpine gradle build -x test

docker build -f ./RestAPIGateway/Dockerfile --build-arg port=9020 -t ${acrLoginServer}/apigateway:v1.0 .

docker push ${acrLoginServer}/apigateway:v1.0
popd
echo ........

echo ........ building and pushing dealerservice image
pushd PartsUnlimitedMRPmicro

docker build -f DealerService/Dockerfile -t ${acrLoginServer}/pumrp-dealer:v1.0 .

docker push ${acrLoginServer}/pumrp-dealer:v1.0
popd
echo ........


echo ........ deploying stuff

pushd PartsUnlimitedMRPmicro

echo ........ deploying promotheus
helm install ./deploy/helm/individual/prometheus --name=prometheus

echo ........ deploying grafana
helm install --name grafana stable/grafana --set server.service.type=LoadBalancer

echo ........ deploying cassandra
helm install ./deploy/helm/cassandra --name=cassandradbs

echo ........ deploying zipkin
helm install ./deploy/helm/individual/zipkinserver --name=zipkin --set image.tag=v1.0,image.repository=${acrLoginServer}/zipkin,service.imagePullSecrets=acr-auth

echo ........ deploying apigateway
helm install ./deploy/helm/individual/apigateway --name=api --set image.tag=v1.0,image.repository=${acrLoginServer}/apigateway,service.imagePullSecrets=acr-auth

echo ........ deploying microservices
helm install ./deploy/helm/individual/dealerservice --name=dealer --set image.repository=${dockerACR} --set image.tag=v1.0,image.repository=${acrLoginServer},service.imagePullSecrets=acr-auth

dockerACR="index.docker.io/microsoft"

helm install ./deploy/helm/individual/partsunlimitedmrp --name=client --set image.repository=${dockerACR}

helm install ./deploy/helm/individual/orderservice --name=order --set image.repository=${dockerACR}

helm install ./deploy/helm/individual/catalogservice --name=catalog --set image.repository=${dockerACR}

helm install ./deploy/helm/individual/shipmentservice --name=shipment --set image.repository=${dockerACR}

helm install ./deploy/helm/individual/quoteservice --name=quote --set image.repository=${dockerACR}

popd

echo ........

echo ........ Set mongo_conn env var and patch deployments
! kubectl delete configmap special-config
kubectl create configmap special-config --from-literal=mongo_connection=${mongo_conn} --from-literal=mongo_database=pumrp --from-literal=mongo_conn=${mongo_conn}

declare -a arr=("order-orderservice" "catalog-catalogservice" "shipment-shipmentservice" "quote-quoteservice" "dealer-dealerservice")

for i in "${arr[@]}"
do
kubectl patch deployment ${i} --type json -p '[{"op": "add", "path": "/spec/template/spec/containers/0/envFrom", "value": [{"configMapRef": {"name": "special-config"}}] }]'
done
echo ........

echo ........ Waiting for ready
# wait logic until all pods are running
n=0
until [ $n -ge 20 ]
do
  kubectl get pods | tail -n +2 | awk '{ if ($3!="Running") exit 1}' && break
  echo ........ Still waiting for app deployment to be ready
  n=$[$n+1]
  sleep 30
done
echo ........

# wait logic until external ip is assigned
n=0
until [ $n -ge 20 ]
do
  ip="$(kubectl get svc | awk '{if ($1 ~ /client-partsunlimitedmrp/) {if ($4 ~ /[0-9]/) {print $4} else {print "<pending>"}} }')"
  if [ $ip != "<pending>" ]; then
    break
  fi
  echo ........ Still waiting for ip to be assigned
  n=$[$n+1]
  sleep 30
done
echo ........

echo http://$ip/mrp_client/

exit 1

