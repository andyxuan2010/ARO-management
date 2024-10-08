

CLUSTER="name_of_your_aro_cluster"		# Name of your ARO cluster
RESOURCEGROUP="rg-aro-cluster"  		# Name of Resource Group where you want to create your ARO Cluster


az aro list -o table

# az aro list-credentials --name $CLUSTER --resource-group $RESOURCEGROUP

kubeadminPassword=$(az aro list-credentials --name $CLUSTER --resource-group $RESOURCEGROUP --query=kubeadminPassword -o tsv)

kubeadminUsername=$(az aro list-credentials --name $CLUSTER --resource-group $RESOURCEGROUP --query=kubeadminUsername -o tsv)

AROAPISrvURL=$(az aro show -g $RESOURCEGROUP -n $CLUSTER --query apiserverProfile.url -o tsv)

oc login $AROAPISrvURL -u $kubeadminUsername -p $kubeadminPassword

AROConsoleURL=`az aro show -n $CLUSTER -g $RESOURCEGROUP  --query consoleProfile.url -o tsv` ; echo $AROConsoleURL

