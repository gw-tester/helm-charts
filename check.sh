#!/bin/bash
# SPDX-license-identifier: Apache-2.0
##############################################################################
# Copyright (c)
# All rights reserved. This program and the accompanying materials
# are made available under the terms of the Apache License, Version 2.0
# which accompanies this distribution, and is available at
# http://www.apache.org/licenses/LICENSE-2.0
##############################################################################

set -o pipefail
set -o errexit
set -o nounset

function teardown {
    if helm list -q | grep -q core-network; then
        helm delete core-network
    fi
    kubectl delete -f https://raw.githubusercontent.com/gw-tester/v1/master/k8s/etcd.yml --wait=false --ignore-not-found
    kubectl delete pod http-server --ignore-not-found
    kubectl delete pod external-client --ignore-not-found
}

function install_deps {
    pkgs=""
    for pkg in "$@"; do
        if ! command -v "$pkg" > /dev/null; then
            pkgs+=" $pkg"
        fi
    done
    if [ -n "$pkgs" ]; then
        # NOTE: Shorten link -> https://github.com/electrocucaracha/pkg-mgr_scripts
        curl -fsSL http://bit.ly/install_pkg | PKG=$pkgs bash
    fi
}

function get_ip_address {
    local app="$1"
    local net="$2"

    pod=$(kubectl get pods -l="app.kubernetes.io/name=$app" \
    -o jsonpath='{.items[0].metadata.name}')
    if kubectl api-resources | grep NetworkAttachmentDefinition > /dev/null ; then
        kubectl get pod "$pod" \
        -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/networks-status}' \
        | jq -r ".[] | select(.name==\"lte-$net\").ips[0]"
    else
        kubectl get danmeps.danm.k8s.io \
        -o jsonpath="{range .items[?(@.spec.Pod == \"$pod\")]}{.spec.Interface}{end}" \
        | jq -r ". | select(.Name|test(\"$net\")).Address" | awk -F '/' '{ print $1 }'
    fi
}

function info {
    _print_msg "INFO" "$1"
}

function error {
    _print_msg "ERROR" "$1"
    exit 1
}

function _print_msg {
    echo "$(date +%H:%M:%S) - $1: $2"
}

function assert_contains {
    local input=$1
    local expected=$2

    if ! echo "$input" | grep -q "$expected"; then
        error "Got $input expected $expected"
    fi
}

teardown
trap teardown EXIT

info "Running installation process..."
install_deps helm kubectl git

info "Creation of datastore"
# TODO: Replace ETDC for Redis datastore
kubectl apply -f https://raw.githubusercontent.com/gw-tester/v1/master/k8s/etcd.yml --wait=false
kubectl rollout status deployment/lte-etcd --timeout=3m

if [ ! -d /opt/gw-tester ]; then
    info "Getting of GW Tester source code"
    sudo git clone --depth 1 https://github.com/gw-tester/helm-charts /opt/gw-tester
    sudo chown -R "$USER:" /opt/gw-tester
fi

if ! helm list -q | grep -q core-network; then
    info "Installing GW Tester charts"
    helm install core-network /opt/gw-tester
fi
info "Waiting for P-GW services"
kubectl rollout status deployment/core-network-pgw --timeout=3m

init_containers=""
if ! helm list -q | grep -q nsm; then
    init_containers="
  initContainers:
    - name: configure
      image: httpd:2.4.46-alpine
      securityContext:
        capabilities:
          add: [\"NET_ADMIN\"]
      command: [\"ip\", \"route\", \"add\", \"10.0.3.0/24\", \"via\", \"$(get_ip_address pgw sgi)\"]"
fi

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: http-server
  annotations:
    v1.multus-cni.io/default-network: lte-sgi
    danm.k8s.io/interfaces: |
      [
        {"clusterNetwork":"lte-sgi"}
      ]
    ns.networkservicemesh.io: lte-network/sgi0?link=sgi
  labels:
    app.kubernetes.io/name: http-server
    network: pdn
spec:
  affinity:
    podAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchExpressions:
              - key: network
                operator: In
                values:
                  - pdn
          topologyKey: "kubernetes.io/hostname"
$init_containers
  containers:
    - image: httpd:2.4.46-alpine
      name: http-server
EOF
info "Waiting for all services"
kubectl wait --for=condition=ready pods --all --timeout=3m

init_containers=""
if ! helm list -q | grep -q nsm; then
    init_containers="
  initContainers:
    - name: configure
      image: electrocucaracha/curl:7.67.0-alpine3.11
      securityContext:
        capabilities:
          add: [\"NET_ADMIN\"]
      command: [\"ip\", \"route\", \"add\", \"10.0.1.0/24\", \"via\", \"$(get_ip_address enb euu)\"]"
fi


if kubectl api-resources | grep NetworkAttachmentDefinition; then
    HTTP_SERVER_SGI_IP=$(kubectl get pod/http-server \
    -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/networks-status}' \
    | jq -r '.[] | select(.name=="lte-sgi").ips[0]')
elif helm list -q | grep -q nsm; then
    HTTP_SERVER_SGI_IP=$(kubectl exec http-server -- ifconfig sgi0 | awk '/inet addr/{print substr($2,6)}')
else
    HTTP_SERVER_SGI_IP=$(kubectl get danmeps.danm.k8s.io \
    -o jsonpath='{range .items[?(@.spec.Pod == "http-server")]}{.spec.Interface.Address}{end}' \
    | awk -F '/' '{ print $1 }')
fi

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: external-client
  annotations:
    v1.multus-cni.io/default-network: lte-euu
    danm.k8s.io/interfaces: |
      [
        {"clusterNetwork":"lte-euu"}
      ]
    ns.networkservicemesh.io: lte-network/euu1?link=euu
  labels:
    app.kubernetes.io/name: external-client
spec:
  affinity:
    podAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchExpressions:
              - key: network
                operator: In
                values:
                  - e-utran
          topologyKey: "kubernetes.io/hostname"
$init_containers
  containers:
    - image: electrocucaracha/curl:7.67.0-alpine3.11
      name: external-client
      command:
        - "sh"
      args:
        - "/opt/external-client/script/init.sh"
      volumeMounts:
        - name: init-script
          mountPath: /opt/external-client/script
  volumes:
    - name: init-script
      configMap:
        name: external-client-init-script
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: external-client-init-script
  labels:
    app.kubernetes.io/name: external-client
data:
  init.sh: |
    while true; do
        curl -s --connect-timeout 5 ${HTTP_SERVER_SGI_IP} | sed -e 's/<[^>]*>//g'
        sleep 30
    done
EOF
info "Waiting for external client"
kubectl wait --for=condition=ready pod external-client --timeout=3m
sleep 10

info "Running assertions"
assert_contains "$(kubectl logs $(kubectl get pods -l=app.kubernetes.io/name=enb -o jsonpath='{.items[0].metadata.name}'))" "Successfully established tunnel for"
assert_contains "$(kubectl logs http-server)" "resuming normal operations"
assert_contains "$(kubectl logs http-server)" '"GET / HTTP/1.1" 200 45'
assert_contains "$(kubectl logs external-client)" "It works!"
