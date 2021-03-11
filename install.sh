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

pkgs=""
for pkg in helm kubectl git; do
    if ! command -v "$pkg" > /dev/null; then
        pkgs+=" $pkg"
    fi
done
if [ -n "$pkgs" ]; then
    # NOTE: Shorten link -> https://github.com/electrocucaracha/pkg-mgr_scripts
    curl -fsSL http://bit.ly/install_pkg | PKG=$pkgs bash
fi

# TODO: Replace ETDC for Redis datastore
kubectl apply -f https://raw.githubusercontent.com/gw-tester/v1/master/k8s/etcd.yml --wait=false
kubectl rollout status deployment/lte-etcd --timeout=3m

if [ ! -d /opt/gw-tester ]; then
    sudo git clone --depth 1 https://github.com/gw-tester/helm-charts /opt/gw-tester
    sudo chown -R "$USER:" /opt/gw-tester
fi

if ! helm list -q | grep -q core-network; then
    helm install core-network /opt/gw-tester
fi

for deployment in $(kubectl get deployments --no-headers -o custom-columns=name:.metadata.name | grep core-network); do
    kubectl rollout status "deployment/$deployment" --timeout=5m
done
