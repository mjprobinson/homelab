#! /usr/bin/bash
set -e

#========================#
#      Variables         #
#========================#

## Machine Set Up
# Node IPs
PROD_1=192.168.1.100
PROD_2=192.168.1.101
PROD_3=192.168.1.102

ALL_MACHINES=($PROD_1 $PROD_2 $PROD_3)
ALL_SSH_KEYS=("$HOME/.ssh/prod-kubelab" "$HOME/.ssh/prod-kubelab" "$HOME/.ssh/prod-kubelab")

# User on nodes
USER=ubuntu

# Network Interface
INTERFACE=ens18

## K3s Set Up
K3SVERSION="v1.35.1+k3s1"

## Kube-VIP Set Up
# Version
KVVERSION="v1.0.4"

# Virtual IP
VIP=192.168.1.111

# LoadBalancer IP Range
LBRANGE="192.168.1.120-192.168.1.145"

#========================#
#      Install Deps      #
#========================#
 
# Install k3sup to local machine if not already present
if ! command -v k3sup version &> /dev/null
then
    echo -e " \033[31;5mk3sup not found, installing\033[0m"
    curl -sLS https://get.k3sup.dev | sh
    sudo install k3sup /usr/local/bin/
    rm k3sup
else
    echo -e " \033[32;5mk3sup already installed\033[0m"
fi

# Install Kubectl if not already present
if ! command -v kubectl version &> /dev/null
then
    echo -e " \033[31;5mKubectl not found, installing\033[0m"
    curl -LO https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    rm kubectl
else
    echo -e " \033[32;5mKubectl already installed\033[0m"
fi

#========================#
#      Init Cluster      #
#========================#

node_1=${ALL_MACHINES[0]}
ssh_1=${ALL_SSH_KEYS[0]}

mkdir -p ~/.kube
k3sup install \
    --ip $node_1 \
    --user $USER \
    --tls-san $VIP \
    --cluster \
    --k3s-version $K3SVERSION \
    --k3s-extra-args "--disable servicelb --disable traefik --flannel-iface=$INTERFACE --node-ip=$node_1" \
    --merge \
    --sudo \
    --local-path $HOME/.kube/config \
    --ssh-key $ssh_1 \
    --context k3s-ha
echo -e " \033[32;5mFirst Node bootstrapped successfully!\033[0m"

#========================#
#    Kube-VIP Install    #
#========================#

kubectl apply -f https://kube-vip.io/manifests/rbac.yaml
ssh -i $ssh_1 $USER@$node_1 << EOF
sudo mkdir -p /var/lib/rancher/k3s/server/manifests/
sudo ctr image pull ghcr.io/kube-vip/kube-vip:$KVVERSION
sudo ctr run --rm --net-host ghcr.io/kube-vip/kube-vip:$KVVERSION vip /kube-vip manifest daemonset \
    --interface $INTERFACE \
    --address $VIP \
    --inCluster \
    --taint \
    --controlplane \
    --services \
    --arp \
    --leaderElection | sudo tee /var/lib/rancher/k3s/server/manifests/kube-vip.yaml
EOF
echo -e " \033[32;5mKube-VIP Installed\033[0m"

#========================#
#     Cluster Finish     #
#========================#

for i in "${!ALL_MACHINES[@]}"; do
    if [ "$i" -eq 0 ]; then
        continue
    fi
    node=${ALL_MACHINES[$i]}
    ssh=${ALL_SSH_KEYS[$i]}
    k3sup join \
        --ip $node \
        --user $USER \
        --sudo \
        --k3s-version $K3SVERSION \
        --server \
        --server-ip $node_1 \
        --server-user $USER \
        --ssh-key $ssh \
        --k3s-extra-args "--disable servicelb --disable traefik --flannel-iface=$interface --node-ip=$node"
done
echo -e " \033[32;5mNodes joined successfully!\033[0m"

#========================#
#  Kube-VIP LB Install   #
#========================#

kubectl apply -f https://raw.githubusercontent.com/kube-vip/kube-vip-cloud-provider/main/manifest/kube-vip-cloud-controller.yaml
kubectl create configmap -n kube-system kubevip --from-literal range-global=$LBRANGE

echo -e " \033[32;5mDone! \033[0m"
