#!/bin/bash

# This script bootstraps Flux and Helm Operator in the current cluster, given
# the URL of the repository and the root Flux directory there.
#
# Example:
#
# bootstrup-flux.sh -r ssh://flux@storage.losev.com:1975/volume1/git/kustomize-test -d live/development/main-kustomize

namespace=fluxcd

git_repo=
flux_root_dir=
git_poll_interval=1m

die() {
  echo "$@" >/dev/stderr
  exit 1
}

usage() {
  die "Usage: $0 -r <git-repo> -d <flux-root-dir> [-n <namespace>] [-i <git-poll-interval]"
}

require_binary() {
  if ! which "$1" >/dev/null ; then
    die "$1 needs to be istalled."
  fi
}

while getopts n:r:d:i: OPTNAME ; do
  case $OPTNAME in
    n) namespace="$OPTARG" ;;
    r) git_repo="$OPTARG" ;;
    d) flux_root_dir="$OPTARG" ;;
    i) git_poll_interval="$OPTARG" ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))

if test -z "$git_repo" ; then
  die "Git repository is not specified."
  usage
fi
 
if test -z "$flux_root_dir" ; then
  die "Flux root directory is not specified."
  usage
fi

require_binary helm
require_binary kubectl
require_binary fluxctl

repo_host_port="$(echo "$git_repo" | sed -e 's/^\(ssh:\/\/\)\{0,1\}\([a-z][a-z0-9-]*@\)\{0,1\}\([^\/]*\).*/\3/')"
repo_host="${repo_host_port%:*}"
if test "$repo_host_port" = "$repo_host" ; then
  repo_port=
else
  repo_port="${repo_host_port#*:}"
fi

if test -n "$repo_port" ; then
  keyscan_params=(-p "$repo_port" "$repo_host")
else
  keyscan_params=("$repo_host")
fi

known_hosts="$(ssh-keyscan "${keyscan_params[@]}")"
if test "$repo_host" != github.com ; then
  known_hosts="$known_hosts"$'\n'"$(ssh-keyscan github.com)"
fi
echo "$known_hosts"

if ! kubectl get namespace "$namespace" &>/dev/null ; then
  kubectl create namespace "$namespace"
fi

helm repo add fluxcd https://charts.fluxcd.io
helm repo update

helm upgrade -i flux fluxcd/flux \
  --namespace="$namespace" \
  --set=helm.versions=v3 \
  --set=git.user="$namespace" \
  --set=git.email=vlad@losev.com \
  --set=git.setAuthor=true \
  --set=git.pollInterval="$git_poll_interval" \
  --set=syncGarbageCollection.enabled=true \
  --set=manifestGeneration=true \
  --set=git.path="$flux_root_dir" \
  --set=git.url="$git_repo" \
  --set=ssh.known_hosts="$known_hosts"

helm upgrade -i helm-operator fluxcd/helm-operator \
  --namespace="$namespace" \
  --set=git.pollInterval="$git_poll_interval" \
  --set=chartsSyncInterval="$git_poll_interval" \
  --set=helm.versions=v3 \
  --set=git.ssh.secretName=flux-git-deploy \
  --set=git.ssh.known_hosts="$known_hosts"


flux_pod_running() {
  POD_COUNT="$(kubectl -n "$namespace" get pods -l app=flux -o json\
    | jq '
        .items 
        | map(
            select(
              .status.phase == "Running"
              and (.status.containerStatuses | all(.ready))))
        | length')"
  test "$POD_COUNT" -gt 0
}

echo -n "Waiting for Flux pod to start..."
while ! flux_pod_running ; do
  sleep 5
  echo -n .
done
echo

echo "Configure the git repository to trust this public key:"
fluxctl --k8s-fwd-ns=fluxcd identity
