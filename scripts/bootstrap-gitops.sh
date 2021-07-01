#!/bin/sh

set -ueo pipefail

function die {
  echo 2>/dev/stderr "$@"
  exit 1
}

function usage {
  die "Usage: $0 -k <gitub-private-key-file> [-n <namespace] [-p <start-path>]"
}

start_path=live/argo
namespace=flux-system
github_key_file=

while getopts p:n:k: OPTNAME ; do
  case $OPTNAME in
    p) start_path="$OPTARG" ;;
    n) namespace="$OPTARG" ;;
    k) github_key_file="$OPTARG" ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))

if test -z "$github_key_file" ; then
 die "GitHub private key file must be specified via -k"
fi

if test -z "$GITHUB_TOKEN" ; then
  die "GITHUB_TOKEN environment variable must be set to a token with these scopes:\npublic_repo, read:gpg_key, repo:status, repo_deployment"
fi


if ! kubectl get namespace "$namespace" >/dev/null 2>&1 ; then
  kubectl create namespace "$namespace"
fi
github_key=$(cat "$github_key_file" | base64)
host_key=$(ssh-keyscan -p 1975 storage.losev.com 2>/dev/null | base64)
cat <<EOT | kubectl apply -f -
  apiVersion: v1
  kind: Secret
  metadata:
    namespace: $namespace
    name: flux-deploy-user-creds
  data:
    identity: "$github_key"
    known_hosts: "$host_key"
  stringData:
    identity.pub: $(ssh-keygen -y -f "$github_key_file")
    username: git
    password: $GITHUB_TOKEN
EOT
kustomize build "$start_path" | kubectl apply -f -
