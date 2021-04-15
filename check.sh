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
if [[ "${DEBUG:-false}" == "true" ]]; then
    set -o xtrace
fi

function teardown {
    helm uninstall core-network || true
    kubectl delete -f https://raw.githubusercontent.com/gw-tester/v1/master/k8s/etcd.yml --wait=false --ignore-not-found --wait
    kubectl delete pod http-server --ignore-not-found --wait
    kubectl delete pod external-client --ignore-not-found --wait
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

function get_ip_address_by_net {
    local app="$1"
    local net="$2"

    pod=$(kubectl get pods -l="app.kubernetes.io/name=$app" \
    -o jsonpath='{.items[0].metadata.name}')
    if [[ "$api_resources" == *"NetworkAttachmentDefinition"* ]]; then
        kubectl get pod "$pod" \
        -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/networks-status}' \
        | jq -r ".[] | select(.name==\"lte-$net\").ips[0]"
    elif [[ "$api_resources" == *"NetworkService"* ]]; then
        if [[ "$net" == "eth0" ]]; then
            net="nsm"
        fi
        kubectl exec "$pod" -c "$app" -- ip a | awk "/$net/{gsub(\"/.*\", \"\"); print \$2}" | tail -1
    elif [[ "$api_resources" == *"DanmNet"* ]]; then
        kubectl get danmeps.danm.k8s.io \
        -o jsonpath="{range .items[?(@.spec.Pod == \"$pod\")]}{.spec.Interface}{end}" \
        | jq -r ". | select(.Name|test(\"$net\")).Address" | awk -F '/' '{ print $1 }'
    fi
}

function get_ip_address_by_nic {
    local app="$1"
    local nic="$2"

    pod=$(kubectl get pods -l="app.kubernetes.io/name=$app" \
    -o jsonpath='{.items[0].metadata.name}')
    if [[ "$api_resources" == *"NetworkAttachmentDefinition"* ]]; then
        kubectl get pod "$pod" \
        -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/networks-status}' \
        | jq -r ".[] | select(.interface==\"$nic\").ips[0]"
    elif [[ "$api_resources" == *"NetworkService"* ]]; then
        nic="nsm"
        kubectl exec "$pod" -c "$app" -- ip a | awk "/$nic/{gsub(\"/.*\", \"\"); print \$2}" | tail -1
    elif [[ "$api_resources" == *"DanmNet"* ]]; then
        kubectl get danmeps.danm.k8s.io \
        -o jsonpath="{range .items[?(@.spec.Pod == \"$pod\")]}{.spec.Interface}{end}" \
        | jq -r ". | select(.Name|test(\"$nic\")).Address" | awk -F '/' '{ print $1 }'
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
    local pod=$1
    local expected=$2
    local container=${3:-$pod}

    if [[ "$(kubectl logs "$pod" -c "$container")" != *"$expected"* ]]; then
        error "$pod pod's logs don't contain '$expected'"
    fi
}

api_resources="$(kubectl api-resources)"
teardown
trap teardown EXIT

info "Running installation process..."
install_deps helm kubectl git

info "Creation of HTTP external server"

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
    ns.networkservicemesh.io/endpoints: |
      {
        "name": "lte-network",
        "networkServices": [
          {"link": "sgi", "labels": "app=http-server-sgi", "ipaddress": "10.0.1.0/24"}
        ]
      }
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
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: node-role.kubernetes.io/master
                operator: DoesNotExist
  containers:
    - image: httpd:2.4.46-alpine
      name: http-server
      securityContext:
        capabilities:
          add: ["NET_ADMIN"]
EOF

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
info "Waiting for all services"
kubectl wait --for=condition=ready pods --all --timeout=3m

info "Inject routes to existing http server"
eval "kubectl exec http-server -- ip r a 10.0.3.0/24 via $(get_ip_address_by_net pgw sgi)"

init_containers=""
if ! helm list -q | grep -q nsm; then
    init_containers=$(cat <<EOF
  initContainers:
    - name: configure
      image: electrocucaracha/curl:7.67.0-alpine3.11
      securityContext:
        capabilities:
          add: ["NET_ADMIN"]
      command: ["ip", "route", "add", "10.0.1.0/24", "via", "$(get_ip_address_by_net enb euu)"]
EOF
)
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
        curl -s --connect-timeout 5 $(get_ip_address_by_nic http-server eth0) | sed -e 's/<[^>]*>//g'
        sleep 30
    done
EOF
info "Waiting for external client"
kubectl wait --for=condition=ready pod external-client --timeout=3m
sleep 10

info "Running assertions"
enb_pod="$(kubectl get pods -l=app.kubernetes.io/name=enb -o jsonpath='{.items[0].metadata.name}')"
assert_contains "$enb_pod" "Successfully established tunnel for" enb
assert_contains http-server "resuming normal operations"
assert_contains http-server '"GET / HTTP/1.1" 200 45'
assert_contains external-client "It works!"
