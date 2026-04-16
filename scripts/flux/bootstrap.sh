#!/usr/bin/env sh

KUBE_CONTEXT_NAME=${1:-"kind-local-dind-cluster"}
GITHUB_USERNAME=${2:-"enesanbar"}
GITHUB_REPO=${3:-"gitops-flux"}
GITHUB_REPO_BRANCH=${4:-"main"}
GITHUB_REPO_PATH=${5:-"clusters/dev-cluster"}

set -x
kubectl config use-context $KUBE_CONTEXT_NAME

# Install your own mkcert CA for development purposes
mkcert -install
kubectl -n cert-manager create secret tls mkcert-ca-key-pair \
--key "$(mkcert -CAROOT)"/rootCA-key.pem \
--cert "$(mkcert -CAROOT)"/rootCA.pem \
--dry-run=client -oyaml > ./clusters/dev-cluster/components/infrastructure/cert-issuer/mkcert-ca-secret.yaml

# Install the flux components in the cluster
flux bootstrap github \
--owner=$GITHUB_USERNAME \
--repository=$GITHUB_REPO \
--branch=$GITHUB_REPO_BRANCH \
--path=$GITHUB_REPO_PATH \

set +x
