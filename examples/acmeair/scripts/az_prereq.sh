#!/bin/bash

set -e

VERSION=11

AZURE_SUBSCRIPTION_ID=8ecadfc9-d1a3-4ea4-b844-0d9f87e4d7c8
LOCATION=canadaeast
RESOURCE_GROUP_NAME="edusAcmeAir$VERSION"
CLUSTER_NAME="edusAcmeCluster$VERSION"

CONTAINER_REGISTRY_NAME="edusAcmeAirRegistry$VERSION"

echo ........ Logging into Azure
#az login
#az account set --subscription $AZURE_SUBSCRIPTION_ID
echo ........

echo ........ Creating resource group
az group create -l $LOCATION -n $RESOURCE_GROUP_NAME
echo ........

echo ........ Creating resource group
az acr create --resource-group $RESOURCE_GROUP_NAME --name $CONTAINER_REGISTRY_NAME --sku Basic
az acr login --name $CONTAINER_REGISTRY_NAME
acrLoginServer=$(az acr list --resource-group $RESOURCE_GROUP_NAME --query "[].{acrLoginServer:loginServer}" --output table | tail -1)
echo ........
echo $acrLoginServer

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

echo ........ Installing nginx-ingress on cluster
helm install stable/nginx-ingress --namespace kube-system

# kubectl get service -l app=nginx-ingress --namespace kube-system

echo ........

declare -a arr=("acmeair-authservice-java" "acmeair-bookingservice-java" "acmeair-customerservice-java" "acmeair-flightservice-java" "acmeair-mainservice-java")

echo ........ Cloning blueperf repos
for i in "${arr[@]}"
do
  pushd ..
  git clone https://github.com/blueperf/${i}
  popd
done
echo ........

echo ........ Building/Pushing images
for i in "${arr[@]}"
do
  pushd ../${i}
  mvn clean package
  docker build -t "$acrLoginServer/default/${i}" .
  docker push "$acrLoginServer/default/${i}"
  popd
done
echo ........


echo ........ Setting secret for image registry
# https://docs.microsoft.com/en-us/azure/container-registry/container-registry-auth-aks

# que correo poner?
DOCKER_EMAIL=edus@microsoft.com
SERVICE_PRINCIPAL_NAME=acr-kube-principal

# Populate the ACR login server and resource id.
ACR_LOGIN_SERVER=$(az acr show --name $CONTAINER_REGISTRY_NAME --query loginServer --output tsv)
ACR_REGISTRY_ID=$(az acr show --name $CONTAINER_REGISTRY_NAME --query id --output tsv)

# Create a 'Reader' role assignment with a scope of the ACR resource.
! az ad sp delete --id http://$SERVICE_PRINCIPAL_NAME
SP_PASSWD=$(az ad sp create-for-rbac --name $SERVICE_PRINCIPAL_NAME --role Reader --scopes $ACR_REGISTRY_ID --query password --output tsv)

# Get the service principal client id.
CLIENT_ID=$(az ad sp show --id http://$SERVICE_PRINCIPAL_NAME --query appId --output tsv)

kubectl create secret docker-registry acr-auth --docker-server $acrLoginServer --docker-username $CLIENT_ID --docker-password $SP_PASSWD --docker-email $DOCKER_EMAIL

echo ........ patching
kubectl patch serviceaccount default -p '{"imagePullSecrets": [{"name": "acr-auth"}]}'

echo ........

echo ........ Helm deploy apps
for i in "${arr[@]}"
do
  pushd ../${i}/chart/
  helm install ${i} --set image.repository=$acrLoginServer/default/${i}
  popd
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
  ip="$(kubectl get svc --namespace kube-system | awk '{if ($1 ~ /nginx-ingress-controller/) {if ($4 ~ /[0-9]/) {print $4} else {print "<pending>"}} }')"
  if [ $ip != "<pending>" ]; then
    break
  fi
  echo ........ Still waiting for ip to be assigned
  n=$[$n+1]
  sleep 30
done
echo ........

echo http://$ip/acmeair


