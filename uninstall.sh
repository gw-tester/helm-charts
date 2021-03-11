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
set -o xtrace

if helm list -q | grep -q core-network; then
    helm delete core-network
fi
kubectl delete -f https://raw.githubusercontent.com/gw-tester/v1/master/k8s/etcd.yml --wait=false --ignore-not-found
