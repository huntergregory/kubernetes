################## CONSTANTS ##################
numClusters=20
maxFailedClusters=5
myResourceGroup="TODO" # FIXME update
npmYaml="windows-npm.yaml" # FIXME update
e2eFile="./e2e-no-cleanup-and-sleep-3-min.test"

myLocation="eastus"
myWindowsUserName="azureuser"
myWindowsPassword="Feichjeu3*Eem3"
myK8sVersion="1.23.3" # AKS supports WS2022 when k8s version >= 1.23
myWindowsNodePool="win22" # Length <= 6

# conformance toSkip constant
nomatch1="should enforce policy based on PodSelector or NamespaceSelector"
nomatch2="should enforce policy based on NamespaceSelector with MatchExpressions using default ns label"
nomatch3="should enforce policy based on PodSelector and NamespaceSelector"
nomatch4="should enforce policy based on Multiple PodSelectors and NamespaceSelectors"
cidrExcept1="should ensure an IP overlapping both IPBlock.CIDR and IPBlock.Except is allowed"
cidrExcept2="should enforce except clause while egress access to server in CIDR block"
namedPorts="named port"
wrongK8sVersion="Netpol API"
toSkip="\[LinuxOnly\]|$nomatch1|$nomatch2|$nomatch3|$nomatch4|$cidrExcept1|$cidrExcept2|$namedPorts|$wrongK8sVersion|SCTP"

################## SCRIPT ##################
echo "will create resource group $myResourceGroup in $myLocation"
echo "e2e file: $e2eFile"
echo "will run FULL conformance tests on $numClusters clusters (one at a time), allowing at most $maxFailedClusters failures. Failed clusters won't be deleted."
# sleep to allow time to cancel if these constants are wrong
sleep 15

# fail script if a command fails
set -e

# Update aks-preview to the latest version
az extension add --name aks-preview
az extension update --name aks-preview

# Enable Microsoft.ContainerService/AKSWindows2022Preview
az feature register --namespace Microsoft.ContainerService --name AKSWindows2022Preview
az provider register -n Microsoft.ContainerService

echo "creating resource group..."
az group create --name $myResourceGroup --location $myLocation

workingCount=0
declare -a failures
for i in $(seq 1 $numClusters); do
    myAKSCluster="$myResourceGroup-cluster-$i"
    configFile=$myAKSCluster-config
    logFile=$myAKSCluster.log

    echo "Creating cluster $myAKSCluster at $(date)..."
    az aks create \
        --resource-group $myResourceGroup \
        --name $myAKSCluster \
        --generate-ssh-keys \
        --windows-admin-username $myWindowsUserName \
        --windows-admin-password $myWindowsPassword \
        --kubernetes-version $myK8sVersion \
        --network-plugin azure \
        --vm-set-type VirtualMachineScaleSets \
        --node-count 1

    echo "adding windows nodepool for cluster $i at $(date)..."
    az aks nodepool add \
        --resource-group $myResourceGroup \
        --cluster-name $myAKSCluster \
        --name $myWindowsNodePool \
        --os-type Windows \
        --os-sku Windows2022 \
        --node-count 3 \
        --max-pods 200

    az aks nodepool update --node-taints CriticalAddonsOnly=true:NoSchedule -n nodepool1 -g $myResourceGroup --cluster-name $myAKSCluster

    az aks get-credentials -g $myResourceGroup -n $myAKSCluster -f $configFile --overwrite-existing

    kubectl --kubeconfig=$configFile apply -f $npmYaml

    npmWaitCount=0
    while : ; do
        sleep 10
        npmWaitCount=$((npmWaitCount+1))
        echo "have waited $((npmWaitCount*10)) seconds for NPM pods to come up"
        runningCount=`kubectl --kubeconfig=$configFile get pods -n kube-system | grep npm-win | grep Running | wc -l`
        if [[ $runningCount == 3 ]]; then
            echo "NPM is up at $(date)"
            break
        fi
    done

    FQDN=`az aks show --query fqdn -o tsv -n $myAKSCluster -g $myResourceGroup`
    echo "FQDN: $FQDN"

    # run conformance in the foreground
    echo "running conformance for cluster $i starting at $(date)"
    KUBERNETES_SERVICE_HOST=$FQDN KUBERNETES_SERVICE_PORT=443 $e2eFile --allowed-not-ready-nodes=1 --node-os-distro=windows --provider=local --kubeconfig=$configFile --ginkgo.skip="$toSkip" --ginkgo.focus="NetworkPolicy" --delete-namespace=false --delete-namespace-on-failure=false | tee $logFile
 
    echo "FINISHED running conformance for cluster $i at $(date)"

    # check if test failed
    set +e # allow grep to fail without failing the script
    grep -q '"failures":' $logFile
    exitCode=$?
    set -e # make script fail again if a commands fails
    if [[ $exitCode == 0 ]]; then
        echo "FAILED cluster $i"
        failures+=($myAKSCluster)
    else
        echo "deleting $myAKSCluster in the background since it succeeded"
        az aks delete --resource-group $myResourceGroup --name $myAKSCluster --yes --no-wait
        rm $configFile
    fi

    echo
    echo "CURRENT COUNTS:"
    echo "Clusters created: $i"
    echo "Failed conformance tests: ${#failures[@]}"
    echo "Clusters with failed conformance: ${failures[@]}"
    echo

    if [[ ${#failures[@]} == $maxFailedClusters ]]; then
        echo "Exiting since max number of failed clusters reached"
        exit 1
    fi
done

echo
echo "FINISHED SCRIPT"
echo "CURRENT COUNTS:"
echo "Clusters created: $numClusters"
echo "Failed conformance tests: ${#failures[@]}"
echo "Clusters with failed conformance: ${failures[@]}"
echo

echo "TODO: delete resource group: az group delete --name $myResourceGroup --yes"
echo "TODO: delete clusters: aks delete --resource-group $myResoureceGroup --no-wait --yes --name <name>"
