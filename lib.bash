#!/bin/bash

# Expected variables:
#   $kubedee_dir The directory to store kubedee's internal data
#   $kubedee_version The kubedee version, used for the cache

kubedee::log_info() {
  local message="${1:-""}"
  echo -e "\033[1;37m${message}\033[0m"
}

kubedee::log_success() {
  local message="${1:-""}"
  echo -e "\033[1;32m${message}\033[0m"
}

kubedee::log_warn() {
  local message="${1:-""}"
  echo -e "\033[1;33m${message}\033[0m" >&2
}

kubedee::log_error() {
  local message="${1:-""}"
  echo -e "\033[1;31m${message}\033[0m" >&2
}

kubedee::exit_error() {
  local message="${1:-""}"
  local code="${2:-1}"
  kubedee::log_error "${message}"
  exit "${code}"
}

# shellcheck disable=SC2154
[[ -z "${kubedee_dir}" ]] && {
  kubedee::log_error "Internal error: \$kubedee_dir not set"
  return 1
}
# shellcheck disable=SC2154
[[ -z "${kubedee_version}" ]] && {
  kubedee::log_error "Internal error: \$kubedee_version not set"
  return 1
}
# shellcheck disable=SC2154
[[ -z "${dir}" ]] && {
  kubedee::log_error "Internal error: \$dir not set"
  return 1
}

case "${kubedee_version}" in
*-dirty)
  readonly kubedee_cache_dir="${kubedee_dir}/cache/dirty"
  readonly kubedee_image_worker="kubedee-image-worker-dirty"
  ;;
*)
  readonly kubedee_cache_dir="${kubedee_dir}/cache/${kubedee_version}"
  readonly kubedee_image_worker="kubedee-image-worker-${kubedee_version}"
  ;;
esac
readonly kubedee_container_image="ubuntu:16.04"
readonly kubedee_etcd_version="v3.2.12"
readonly kubedee_crio_version="v1.9.0"
readonly kubedee_runc_version="v1.0.0-rc4"
readonly kubedee_cni_plugins_version="v0.6.0"

readonly lxd_status_code_running=103

# Args:
#   $1 The unvalidated cluster name
#
# Return validated name or exit with error
kubedee::validate_name() {
  local orig_name="${1:-}"
  # We must be fairly strict about names, since they are used
  # for container's hostname as well as the network interface.
  # http://elixir.free-electrons.com/linux/v4.13/source/net/core/dev.c#L1023
  if ! echo "${orig_name}" | grep -qE '^[[:alnum:]_-.]{1,50}$'; then
    kubedee::exit_error "Invalid name (only '[[:alnum:]-]{1,50}' allowed): ${orig_name}"
  fi
  # Do some normalization to allow input like 'v1.8.4' while
  # matching host / interface name requirements
  local name="${orig_name//[._]/-}"
  if [[ "${orig_name}" != "${name}" ]]; then
    kubedee::log_warn "Normalized name '${orig_name}' -> '${name}'"
  fi
  echo "${name}"
}

kubedee::cd_or_exit_error() {
  local target="${1}"
  cd "${target}" || kubedee::exit_error "Failed to cd to ${target}"
}

# Args:
#   $1 The target file or directory
#   $* The source files or directories
kubedee::copyl_or_exit_error() {
  local target="${1}"
  shift
  for f in "$@"; do
    if ! cp -l "${f}" "${target}" &>/dev/null; then
      if ! cp "${f}" "${target}"; then
        kubedee::exit_error "Failed to copy '${f}' to '${target}'"
      fi
    fi
  done
}

# Args:
#   $1 The target file or directory
#   $* The source files or directories
kubedee::copy_or_exit_error() {
  local target="${1}"
  shift
  for f in "$@"; do
    if ! cp "${f}" "${target}"; then
      kubedee::exit_error "Failed to copy '${f}' to '${target}'"
    fi
  done
}

# Args:
#   $1 The validated cluster name
#   $2 The path to the k8s bin directory (optional)
kubedee::copy_k8s_binaries() {
  local name="${1}"
  local target_dir="${kubedee_dir}/clusters/${name}/rootfs/usr/local/bin"
  mkdir -p "${target_dir}"
  local source_dir="${2:-$(pwd)/_output/bin}"
  local files=(
    kube-apiserver
    kube-controller-manager
    kube-proxy
    kube-scheduler
    kubectl
    kubelet
  )
  for f in "${files[@]}"; do
    kubedee::copy_or_exit_error "${target_dir}/" "${source_dir}/${f}"
  done
}

kubedee::fetch_etcd() {
  local cache_dir="${kubedee_cache_dir}/etcd/${kubedee_etcd_version}"
  mkdir -p "${cache_dir}"
  [[ -e "${cache_dir}/etcd" && -e "${cache_dir}/etcdctl" ]] && return
  local tmp_dir
  tmp_dir="$(mktemp -d /tmp/kubedee-XXXXXX)"
  (
    kubedee::cd_or_exit_error "${tmp_dir}"
    kubedee::log_info "Fetch etcd ${kubedee_etcd_version} ..."
    curl -fsSL -O "https://github.com/coreos/etcd/releases/download/${kubedee_etcd_version}/etcd-${kubedee_etcd_version}-linux-amd64.tar.gz"
    tar -xf "etcd-${kubedee_etcd_version}-linux-amd64.tar.gz" --strip-components 1
    kubedee::copyl_or_exit_error "${cache_dir}/" etcd etcdctl
  )
  rm -rf "${tmp_dir}"
}

kubedee::fetch_crio() {
  local cache_dir="${kubedee_cache_dir}/crio/${kubedee_crio_version}"
  mkdir -p "${cache_dir}"
  [[ -e "${cache_dir}/crio" ]] && return
  local tmp_dir
  tmp_dir="$(mktemp -d /tmp/kubedee-XXXXXX)"
  (
    kubedee::cd_or_exit_error "${tmp_dir}"
    kubedee::log_info "Fetch crio ${kubedee_crio_version} ..."
    curl -fsSL -O "https://files.schu.io/pub/cri-o/crio-amd64-${kubedee_crio_version}.tar.gz"
    tar -xf "crio-amd64-${kubedee_crio_version}.tar.gz"
    kubedee::copyl_or_exit_error "${cache_dir}/" crio conmon pause seccomp.json crio.conf crictl.yaml crio-umount.conf policy.json
  )
  rm -rf "${tmp_dir}"
}

kubedee::fetch_runc() {
  local cache_dir="${kubedee_cache_dir}/runc/${kubedee_runc_version}"
  mkdir -p "${cache_dir}"
  [[ -e "${cache_dir}/runc" ]] && return
  local tmp_dir
  tmp_dir="$(mktemp -d /tmp/kubedee-XXXXXX)"
  (
    kubedee::cd_or_exit_error "${tmp_dir}"
    kubedee::log_info "Fetch runc ${kubedee_runc_version} ..."
    curl -fsSL -O "https://github.com/opencontainers/runc/releases/download/${kubedee_runc_version}/runc.amd64"
    chmod +x runc.amd64
    kubedee::copyl_or_exit_error "${cache_dir}/runc" runc.amd64
  )
  rm -rf "${tmp_dir}"
}

kubedee::fetch_cni_plugins() {
  local cache_dir="${kubedee_cache_dir}/cni-plugins/${kubedee_cni_plugins_version}"
  mkdir -p "${cache_dir}"
  [[ -e "${cache_dir}/flannel" ]] && return
  local tmp_dir
  tmp_dir="$(mktemp -d /tmp/kubedee-XXXXXX)"
  (
    kubedee::cd_or_exit_error "${tmp_dir}"
    kubedee::log_info "Fetch cni plugins ${kubedee_cni_plugins_version} ..."
    curl -fsSL -O "https://github.com/containernetworking/plugins/releases/download/${kubedee_cni_plugins_version}/cni-plugins-amd64-${kubedee_cni_plugins_version}.tgz"
    tar -xf "cni-plugins-amd64-${kubedee_cni_plugins_version}.tgz"
    rm -rf "cni-plugins-amd64-${kubedee_cni_plugins_version}.tgz"
    kubedee::copyl_or_exit_error "${cache_dir}/" ./*
  )
  rm -rf "${tmp_dir}"
}

# Args:
#   $1 The validated cluster name
kubedee::copy_etcd_binaries() {
  local name="${1}"
  kubedee::fetch_etcd
  local cache_dir="${kubedee_cache_dir}/etcd/${kubedee_etcd_version}"
  local target_dir="${kubedee_dir}/clusters/${name}/rootfs/usr/local/bin"
  mkdir -p "${target_dir}"
  kubedee::copyl_or_exit_error "${target_dir}/" "${cache_dir}/"{etcd,etcdctl}
}

# Args:
#   $1 The validated cluster name
kubedee::copy_crio_files() {
  local name="${1}"
  kubedee::fetch_crio
  local cache_dir="${kubedee_cache_dir}/crio/${kubedee_crio_version}"
  local target_dir="${kubedee_dir}/clusters/${name}/rootfs/usr/local/bin"
  mkdir -p "${target_dir}"
  kubedee::copyl_or_exit_error "${target_dir}/" "${cache_dir}/crio"
  local target_dir="${kubedee_dir}/clusters/${name}/rootfs/usr/local/libexec/crio"
  mkdir -p "${target_dir}"
  kubedee::copyl_or_exit_error "${target_dir}/" "${cache_dir}/"{pause,conmon}
  local target_dir="${kubedee_dir}/clusters/${name}/rootfs/etc/crio"
  mkdir -p "${target_dir}/"
  kubedee::copyl_or_exit_error "${target_dir}/" "${cache_dir}/"{seccomp.json,crio.conf,crictl.yaml,crio-umount.conf,policy.json}
}

# Args:
#   $1 The validated cluster name
kubedee::copy_runc_binaries() {
  local name="${1}"
  kubedee::fetch_runc
  local cache_dir="${kubedee_cache_dir}/runc/${kubedee_runc_version}"
  local target_dir="${kubedee_dir}/clusters/${name}/rootfs/usr/local/bin"
  mkdir -p "${target_dir}"
  kubedee::copyl_or_exit_error "${target_dir}/" "${cache_dir}/runc"
}

# Args:
#   $1 The validated cluster name
kubedee::copy_cni_plugins() {
  local name="${1}"
  kubedee::fetch_cni_plugins
  local cache_dir="${kubedee_cache_dir}/cni-plugins/${kubedee_cni_plugins_version}"
  local target_dir="${kubedee_dir}/clusters/${name}/rootfs/opt/cni/bin"
  mkdir -p "${target_dir}"
  kubedee::copyl_or_exit_error "${target_dir}/" "${cache_dir}/"*
}

# Args:
#   $1 A valid network name
kubedee::create_network() {
  local name="${1}"
  if ! lxc network show "${name}" &>/dev/null; then
    lxc network create "${name}"
  fi
}

# Args:
#   $1 A valid network name
kubedee::delete_network() {
  local name="${1}"
  if lxc network show "${name}" &>/dev/null; then
    lxc network delete "${name}"
  fi
}

# Args:
#   $1 The storage pool name (optional)
#   $2 The storage pool driver (optional)
kubedee::create_storage_pool() {
  local name="${1:-kubedee}"
  local driver="${2:-btrfs}"
  if ! lxc storage show "${name}" &>/dev/null; then
    lxc storage create "${name}" "${driver}"
  fi
}

kubedee::container_status_code() {
  local name="${1}"
  lxc list --format json | jq -r ".[] | select(.name == \"${name}\").state.status_code"
}

kubedee::container_ipv4_address() {
  local name="${1}"
  lxc list --format json | jq -r ".[] | select(.name == \"${name}\").state.network.eth0.addresses[] | select(.family == \"inet\").address"
}

kubedee::container_wait_running() {
  local name="${1}"
  until [[ "$(kubedee::container_status_code "${name}")" -eq ${lxd_status_code_running} ]]; do
    kubedee::log_info "Waiting for ${name} to reach state running ..."
    sleep 3
  done
  until [[ "$(kubedee::container_ipv4_address "${name}")" != "" ]]; do
    kubedee::log_info "Waiting for ${name} to get IPv4 address ..."
    sleep 3
  done
}

# Args:
#   $1 The validated cluster name
kubedee::create_certificate_authority() {
  local name="${1}"
  local target_dir="${kubedee_dir}/clusters/${name}/certificates"
  mkdir -p "${target_dir}"
  (
    kubedee::cd_or_exit_error "${target_dir}"
    kubedee::log_info "Generate certificate authority ..."
    cat <<EOF | cfssl gencert -initca - | cfssljson -bare ca
{
  "CN": "Kubernetes",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "DE",
      "L": "Berlin",
      "O": "Kubernetes",
      "OU": "CA",
      "ST": "Berlin"
    }
  ]
}
EOF
    cat >ca-config.json <<EOF
{
  "signing": {
    "default": {
      "expiry": "8760h"
    },
    "profiles": {
      "kubernetes": {
        "usages": ["signing", "key encipherment", "server auth", "client auth"],
        "expiry": "8760h"
      }
    }
  }
}
EOF
  )
}

# Args:
#   $1 The validated cluster name
kubedee::create_certificate_admin() {
  local name="${1}"
  local target_dir="${kubedee_dir}/clusters/${name}/certificates"
  mkdir -p "${target_dir}"
  (
    kubedee::cd_or_exit_error "${target_dir}"
    kubedee::log_info "Generate admin certificate ..."
    cat <<EOF | cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=kubernetes - | cfssljson -bare admin
{
  "CN": "admin",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "DE",
      "L": "Berlin",
      "O": "system:masters",
      "OU": "kubedee",
      "ST": "Berlin"
    }
  ]
}
EOF
  )
}

# Args:
#   $1 The validated cluster name
kubedee::create_certificate_etcd() {
  local name="${1}"
  local target_dir="${kubedee_dir}/clusters/${name}/certificates"
  local ip
  ip="$(kubedee::container_ipv4_address "kubedee-${name}-etcd")"
  [[ -z "${ip}" ]] && kubedee::exit_error "Failed to get IPv4 for kubedee-${name}-etcd"
  mkdir -p "${target_dir}"
  (
    kubedee::cd_or_exit_error "${target_dir}"
    kubedee::log_info "Generate etcd certificate ..."
    cat <<EOF | cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=kubernetes -hostname="${ip},127.0.0.1" - | cfssljson -bare etcd
{
  "CN": "etcd",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "DE",
      "L": "Berlin",
      "O": "etcd",
      "OU": "kubedee",
      "ST": "Berlin"
    }
  ]
}
EOF
  )
}

# Args:
#   $1 The validated cluster name
kubedee::create_certificate_kubernetes() {
  local name="${1}"
  local target_dir="${kubedee_dir}/clusters/${name}/certificates"
  local ip
  ip="$(kubedee::container_ipv4_address "kubedee-${name}-controller")"
  [[ -z "${ip}" ]] && kubedee::exit_error "Failed to get IPv4 for kubedee-${name}-controller"
  mkdir -p "${target_dir}"
  (
    kubedee::cd_or_exit_error "${target_dir}"
    kubedee::log_info "Generate controller certificate ..."
    cat <<EOF | cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=kubernetes -hostname="10.32.0.1,${ip},127.0.0.1" - | cfssljson -bare kubernetes
{
  "CN": "kubernetes",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "DE",
      "L": "Berlin",
      "O": "Kubernetes",
      "OU": "kubedee",
      "ST": "Berlin"
    }
  ]
}
EOF
    cat <<EOF | cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=kubernetes - | cfssljson -bare kube-proxy
{
  "CN": "system:kube-proxy",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "DE",
      "L": "Berlin",
      "O": "system:node-proxier",
      "OU": "kubedee",
      "ST": "Berlin"
    }
  ]
}
EOF
  )
}

# Args:
#   $1 The validated cluster name
kubedee::create_certificate_worker() {
  local name="${1}"
  local suffix="${2}"
  local container_name="kubedee-${name}-worker-${suffix}"
  local target_dir="${kubedee_dir}/clusters/${name}/certificates"
  local ip
  ip="$(kubedee::container_ipv4_address "${container_name}")"
  [[ -z "${ip}" ]] && kubedee::exit_error "Failed to get IPv4 for ${container_name}"
  mkdir -p "${target_dir}"
  (
    kubedee::cd_or_exit_error "${target_dir}"
    kubedee::log_info "Generate ${container_name} certificate ..."
    cat <<EOF | cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=kubernetes -hostname="${ip},${container_name}" - | cfssljson -bare "${container_name}"
{
  "CN": "system:node:${container_name}",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "DE",
      "L": "Berlin",
      "O": "system:nodes",
      "OU": "kubedee",
      "ST": "Berlin"
    }
  ]
}
EOF
  )
}

# Args:
#   $1 The validated cluster name
kubedee::create_kubeconfig_admin() {
  local name="${1}"
  local cluster_dir="${kubedee_dir}/clusters/${name}"
  local controller_ip
  controller_ip="$(kubedee::container_ipv4_address "kubedee-${name}-controller")"
  mkdir -p "${cluster_dir}/kubeconfig"

  kubectl config set-cluster kubedee \
    --certificate-authority="${cluster_dir}/certificates/ca.pem" \
    --embed-certs=true \
    --server="https://${controller_ip}:6443" \
    --kubeconfig="${cluster_dir}/kubeconfig/admin.kubeconfig"

  kubectl config set-credentials admin \
    --client-certificate="${cluster_dir}/certificates/admin.pem" \
    --client-key="${cluster_dir}/certificates/admin-key.pem" \
    --kubeconfig="${cluster_dir}/kubeconfig/admin.kubeconfig"

  kubectl config set-context default \
    --cluster=kubedee \
    --user=admin \
    --kubeconfig="${cluster_dir}/kubeconfig/admin.kubeconfig"

  kubectl config use-context default --kubeconfig="${cluster_dir}/kubeconfig/admin.kubeconfig"
}

# Args:
#   $1 The validated cluster name
kubedee::create_kubeconfig_worker() {
  local name="${1}"
  local suffix="${2}"
  local container_name="kubedee-${name}-worker-${suffix}"
  local cluster_dir="${kubedee_dir}/clusters/${name}"
  local controller_ip
  controller_ip="$(kubedee::container_ipv4_address "kubedee-${name}-controller")"
  mkdir -p "${cluster_dir}/kubeconfig"

  kubedee::log_info "Generate ${container_name} kubeconfig ..."

  kubectl config set-cluster kubedee \
    --certificate-authority="${cluster_dir}/certificates/ca.pem" \
    --embed-certs=true \
    --server="https://${controller_ip}:6443" \
    --kubeconfig="${cluster_dir}/kubeconfig/kube-proxy.kubeconfig"

  kubectl config set-credentials kube-proxy \
    --client-certificate="${cluster_dir}/certificates/kube-proxy.pem" \
    --client-key="${cluster_dir}/certificates/kube-proxy-key.pem" \
    --embed-certs=true \
    --kubeconfig="${cluster_dir}/kubeconfig/kube-proxy.kubeconfig"

  kubectl config set-context default \
    --cluster=kubedee \
    --user=kube-proxy \
    --kubeconfig="${cluster_dir}/kubeconfig/kube-proxy.kubeconfig"

  kubectl config use-context default --kubeconfig="${cluster_dir}/kubeconfig/kube-proxy.kubeconfig"

  kubectl config set-cluster kubedee \
    --certificate-authority="${cluster_dir}/certificates/ca.pem" \
    --embed-certs=true \
    --server="https://${controller_ip}:6443" \
    --kubeconfig="${cluster_dir}/kubeconfig/kubelet.kubeconfig"

  kubectl config set-credentials "system:node:${container_name}" \
    --client-certificate="${cluster_dir}/certificates/${container_name}.pem" \
    --client-key="${cluster_dir}/certificates/${container_name}-key.pem" \
    --embed-certs=true \
    --kubeconfig="${cluster_dir}/kubeconfig/kubelet.kubeconfig"

  kubectl config set-context default \
    --cluster=kubedee \
    --user="system:node:${container_name}" \
    --kubeconfig="${cluster_dir}/kubeconfig/kubelet.kubeconfig"

  kubectl config use-context default --kubeconfig="${cluster_dir}/kubeconfig/kubelet.kubeconfig"
}

# Args:
#   $1 The validated cluster name
kubedee::launch_etcd() {
  local name="${1}"
  local container_name="kubedee-${name}-etcd"
  lxc info "${container_name}" &>/dev/null && return
  lxc launch \
    --storage kubedee \
    --network "kubedee-${name}" \
    --config raw.lxc="lxc.aa_allow_incomplete=1" \
    "${kubedee_container_image}" "${container_name}"
}

# Args:
#   $1 The validated cluster name
kubedee::configure_etcd() {
  local name="${1}"
  local container_name="kubedee-${name}-etcd"
  kubedee::container_wait_running "${container_name}"
  kubedee::create_certificate_etcd "${name}"
  local ip
  ip="$(kubedee::container_ipv4_address "${container_name}")"
  kubedee::log_info "Providing files to ${container_name} ..."

  lxc config device add "${container_name}" binary-etcd disk source="${kubedee_dir}/clusters/${name}/rootfs/usr/local/bin/etcd" path="/usr/local/bin/etcd"
  lxc config device add "${container_name}" binary-etcdctl disk source="${kubedee_dir}/clusters/${name}/rootfs/usr/local/bin/etcdctl" path="/usr/local/bin/etcdctl"

  lxc file push -p "${kubedee_dir}/clusters/${name}/certificates/"{etcd.pem,etcd-key.pem,ca.pem} "${container_name}/etc/etcd/"

  kubedee::log_info "Configuring ${container_name} ..."
  cat <<EOF | lxc exec "${container_name}" bash
set -euo pipefail
cat >/etc/systemd/system/etcd.service <<ETCD_UNIT
[Unit]
Description=etcd

[Service]
ExecStart=/usr/local/bin/etcd \
  --name ${container_name} \
  --cert-file=/etc/etcd/etcd.pem \
  --key-file=/etc/etcd/etcd-key.pem \
  --peer-cert-file=/etc/etcd/etcd.pem \
  --peer-key-file=/etc/etcd/etcd-key.pem \
  --trusted-ca-file=/etc/etcd/ca.pem \
  --peer-trusted-ca-file=/etc/etcd/ca.pem \
  --peer-client-cert-auth \
  --client-cert-auth \
  --initial-advertise-peer-urls https://${ip}:2380 \
  --listen-peer-urls https://${ip}:2380 \
  --listen-client-urls https://${ip}:2379,http://127.0.0.1:2379 \
  --advertise-client-urls https://${ip}:2379 \
  --initial-cluster-token etcd-cluster-0 \
  --initial-cluster ${container_name}=https://${ip}:2380 \
  --initial-cluster-state new \
  --data-dir=/var/lib/etcd
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
ETCD_UNIT

systemctl daemon-reload
systemctl -q enable etcd
systemctl start etcd
EOF
}

# Args:
#   $1 The validated cluster name
kubedee::launch_controller() {
  local name="${1}"
  local container_name="kubedee-${name}-controller"
  lxc info "${container_name}" &>/dev/null && return
  lxc launch \
    --storage kubedee \
    --network "kubedee-${name}" \
    --config raw.lxc="lxc.aa_allow_incomplete=1" \
    "${kubedee_container_image}" "${container_name}"
}

# Args:
#   $1 The validated cluster name
kubedee::configure_controller() {
  local name="${1}"
  local etcd_ip
  etcd_ip="$(kubedee::container_ipv4_address "kubedee-${name}-etcd")"
  local container_name="kubedee-${name}-controller"
  kubedee::container_wait_running "${container_name}"
  kubedee::create_certificate_kubernetes "${name}"
  local ip
  ip="$(kubedee::container_ipv4_address "kubedee-${name}-controller")"
  kubedee::log_info "Providing files to ${container_name} ..."

  lxc config device add "${container_name}" binary-kube-apiserver disk source="${kubedee_dir}/clusters/${name}/rootfs/usr/local/bin/kube-apiserver" path="/usr/local/bin/kube-apiserver"
  lxc config device add "${container_name}" binary-kube-controller-manager disk source="${kubedee_dir}/clusters/${name}/rootfs/usr/local/bin/kube-controller-manager" path="/usr/local/bin/kube-controller-manager"
  lxc config device add "${container_name}" binary-kube-scheduler disk source="${kubedee_dir}/clusters/${name}/rootfs/usr/local/bin/kube-scheduler" path="/usr/local/bin/kube-scheduler"
  lxc config device add "${container_name}" binary-kubectl disk source="${kubedee_dir}/clusters/${name}/rootfs/usr/local/bin/kubectl" path="/usr/local/bin/kubectl"

  lxc file push -p "${kubedee_dir}/clusters/${name}/certificates/"{kubernetes.pem,kubernetes-key.pem,ca.pem,ca-key.pem} "${container_name}/etc/kubernetes/"

  kubedee::log_info "Configuring ${container_name} ..."
  cat <<EOF | lxc exec "${container_name}" bash
set -euo pipefail
cat >/etc/systemd/system/kube-apiserver.service <<KUBE_APISERVER_UNIT
[Unit]
Description=Kubernetes API Server

[Service]
ExecStart=/usr/local/bin/kube-apiserver \
  --admission-control=NamespaceLifecycle,NodeRestriction,LimitRanger,ServiceAccount,DefaultStorageClass,ResourceQuota \
  --allow-privileged=true \
  --apiserver-count=3 \
  --audit-log-maxage=30 \
  --audit-log-maxbackup=3 \
  --audit-log-maxsize=100 \
  --audit-log-path=/var/log/audit.log \
  --authorization-mode=Node,RBAC \
  --bind-address=0.0.0.0 \
  --client-ca-file=/etc/kubernetes/ca.pem \
  --enable-swagger-ui=true \
  --etcd-cafile=/etc/kubernetes/ca.pem \
  --etcd-certfile=/etc/kubernetes/kubernetes.pem \
  --etcd-keyfile=/etc/kubernetes/kubernetes-key.pem \
  --etcd-servers=https://${etcd_ip}:2379 \
  --event-ttl=1h \
  --insecure-bind-address=0.0.0.0 \
  --kubelet-certificate-authority=/etc/kubernetes/ca.pem \
  --kubelet-client-certificate=/etc/kubernetes/kubernetes.pem \
  --kubelet-client-key=/etc/kubernetes/kubernetes-key.pem \
  --kubelet-https=true \
  --runtime-config=rbac.authorization.k8s.io/v1alpha1 \
  --service-account-key-file=/etc/kubernetes/ca-key.pem \
  --service-cluster-ip-range=10.32.0.0/24 \
  --service-node-port-range=30000-32767 \
  --tls-ca-file=/etc/kubernetes/ca.pem \
  --tls-cert-file=/etc/kubernetes/kubernetes.pem \
  --tls-private-key-file=/etc/kubernetes/kubernetes-key.pem \
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
KUBE_APISERVER_UNIT

cat >/etc/systemd/system/kube-controller-manager.service <<KUBE_CONTROLLER_MANAGER_UNIT
[Unit]
Description=Kubernetes Controller Manager
Documentation=https://github.com/GoogleCloudPlatform/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-controller-manager \
  --address=0.0.0.0 \
  --allocate-node-cidrs=true \
  --cluster-cidr=10.244.0.0/16 \
  --cluster-name=kubernetes \
  --cluster-signing-cert-file=/etc/kubernetes/ca.pem \
  --cluster-signing-key-file=/etc/kubernetes/ca-key.pem \
  --leader-elect=true \
  --master=http://${ip}:8080 \
  --root-ca-file=/etc/kubernetes/ca.pem \
  --service-account-private-key-file=/etc/kubernetes/ca-key.pem \
  --service-cluster-ip-range=10.32.0.0/24 \
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
KUBE_CONTROLLER_MANAGER_UNIT

cat >/etc/systemd/system/kube-scheduler.service <<KUBE_SCHEDULER_UNIT
[Unit]
Description=Kubernetes Scheduler

[Service]
ExecStart=/usr/local/bin/kube-scheduler \
  --leader-elect=true \
  --master=http://${ip}:8080 \
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
KUBE_SCHEDULER_UNIT


systemctl daemon-reload

systemctl -q enable kube-apiserver
systemctl start kube-apiserver

systemctl -q enable kube-controller-manager
systemctl start kube-controller-manager

systemctl -q enable kube-scheduler
systemctl start kube-scheduler
EOF
}

# Args:
#   $1 The validated cluster name
kubedee::configure_rbac() {
  local name="${1}"
  local container_name="kubedee-${name}-controller"
  kubedee::container_wait_running "${container_name}"
  cat <<EOF | lxc exec "${container_name}" bash
set -euo pipefail

cat <<APISERVER_RBAC | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1beta1
kind: ClusterRole
metadata:
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: "true"
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
  name: system:kube-apiserver-to-kubelet
rules:
  - apiGroups:
      - ""
    resources:
      - nodes/proxy
      - nodes/stats
      - nodes/log
      - nodes/spec
      - nodes/metrics
    verbs:
      - "*"
APISERVER_RBAC

cat <<APISERVER_BINDING | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1beta1
kind: ClusterRoleBinding
metadata:
  name: system:kube-apiserver
  namespace: ""
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:kube-apiserver-to-kubelet
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: User
    name: kubernetes
APISERVER_BINDING

EOF
}

# Args:
#   $1 The validated cluster name
kubedee::launch_worker() {
  local name="${1}"
  local suffix="${2}"
  local container_name="kubedee-${name}-worker-${suffix}"
  lxc info "${container_name}" &>/dev/null && return
  read -r -d '' raw_lxc <<RAW_LXC || true
lxc.aa_profile=unconfined
lxc.mount.auto=proc:rw sys:rw cgroup:rw
lxc.cgroup.devices.allow=a
lxc.cap.drop=
lxc.aa_allow_incomplete=1
RAW_LXC
  lxc launch \
    --storage kubedee \
    --network "kubedee-${name}" \
    --profile default \
    --config security.privileged=true \
    --config security.nesting=true \
    --config linux.kernel_modules=ip_tables,ip6_tables,netlink_diag,nf_nat,overlay \
    --config raw.lxc="${raw_lxc}" \
    "${kubedee_image_worker}" "${container_name}"
}

# Args:
#   $1 The validated cluster name
kubedee::configure_worker() {
  local name="${1}"
  local suffix="${2}"
  local container_name="kubedee-${name}-worker-${suffix}"
  kubedee::container_wait_running "${container_name}"
  kubedee::create_certificate_worker "${name}" "${suffix}"
  kubedee::create_kubeconfig_worker "${name}" "${suffix}"
  kubedee::log_info "Providing files to ${container_name} ..."

  lxc config device add "${container_name}" binary-kubelet disk source="${kubedee_dir}/clusters/${name}/rootfs/usr/local/bin/kubelet" path="/usr/local/bin/kubelet"
  lxc config device add "${container_name}" binary-kube-proxy disk source="${kubedee_dir}/clusters/${name}/rootfs/usr/local/bin/kube-proxy" path="/usr/local/bin/kube-proxy"
  lxc config device add "${container_name}" binary-kubectl disk source="${kubedee_dir}/clusters/${name}/rootfs/usr/local/bin/kubectl" path="/usr/local/bin/kubectl"

  lxc config device add "${container_name}" binary-runc disk source="${kubedee_dir}/clusters/${name}/rootfs/usr/local/bin/runc" path="/usr/local/bin/runc"

  lxc config device add "${container_name}" binary-crio disk source="${kubedee_dir}/clusters/${name}/rootfs/usr/local/bin/crio" path="/usr/local/bin/crio"
  lxc config device add "${container_name}" crio-config disk source="${kubedee_dir}/clusters/${name}/rootfs/etc/crio/" path="/etc/crio/"
  lxc config device add "${container_name}" crio-libexec disk source="${kubedee_dir}/clusters/${name}/rootfs/usr/local/libexec/crio/" path="/usr/local/libexec/crio/"

  lxc file push -p "${kubedee_dir}/clusters/${name}/certificates/"{"${container_name}.pem","${container_name}-key.pem",ca.pem} "${container_name}/etc/kubernetes/"
  lxc file push -p "${kubedee_dir}/clusters/${name}/kubeconfig/"* "${container_name}/etc/kubernetes/"

  lxc config device add "${container_name}" cni-plugins disk source="${kubedee_dir}/clusters/${name}/rootfs/opt/cni/bin/" path="/opt/cni/bin/"

  kubedee::log_info "Configuring ${container_name} ..."
  cat <<EOF | lxc exec "${container_name}" bash
set -euo pipefail

mkdir -p /etc/containers
ln -s /etc/crio/policy.json /etc/containers/policy.json

mkdir -p /etc/cni/net.d

cat >/etc/systemd/system/crio.service <<CRIO_UNIT
[Unit]
Description=CRI-O daemon

[Service]
ExecStart=/usr/local/bin/crio --runtime /usr/local/bin/runc --registry docker.io
Restart=always
RestartSec=10s

[Install]
WantedBy=multi-user.target
CRIO_UNIT

cat >/etc/systemd/system/kubelet.service <<KUBELET_UNIT
[Unit]
Description=Kubernetes Kubelet
After=crio.service
Requires=crio.service

[Service]
ExecStart=/usr/local/bin/kubelet \
  --fail-swap-on=false \
  --anonymous-auth=false \
  --authorization-mode=Webhook \
  --client-ca-file=/etc/kubernetes/ca.pem \
  --allow-privileged=true \
  --cluster-dns=10.32.0.10 \
  --cluster-domain=cluster.local \
  --container-runtime=remote \
  --container-runtime-endpoint=unix:///var/run/crio/crio.sock \
  --image-pull-progress-deadline=2m \
  --image-service-endpoint=unix:///var/run/crio/crio.sock \
  --kubeconfig=/etc/kubernetes/kubelet.kubeconfig \
  --network-plugin=cni \
  --pod-cidr=10.20.0.0/16 \
  --register-node=true \
  --runtime-request-timeout=10m \
  --tls-cert-file=/etc/kubernetes/${container_name}.pem \
  --tls-private-key-file=/etc/kubernetes/${container_name}-key.pem \
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
KUBELET_UNIT

cat >/etc/systemd/system/kube-proxy.service <<KUBE_PROXY_UNIT
[Unit]
Description=Kubernetes Kube Proxy

[Service]
ExecStart=/usr/local/bin/kube-proxy \
  --cluster-cidr=10.200.0.0/16 \
  --kubeconfig=/etc/kubernetes/kube-proxy.kubeconfig \
  --proxy-mode=iptables \
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
KUBE_PROXY_UNIT

systemctl daemon-reload

systemctl -q enable crio
systemctl start crio

systemctl -q enable kubelet
systemctl start kubelet

systemctl -q enable kube-proxy
systemctl start kube-proxy
EOF
}

# Args:
#   $1 The validated cluster name
kubedee::deploy_flannel() {
  local name="${1}"
  kubedee::log_info "Deploying flannel ..."
  kubectl --kubeconfig "${kubedee_dir}/clusters/${name}/kubeconfig/admin.kubeconfig" \
    apply -f "${dir}/manifests/kube-flannel.yml"
}

# Args:
#   $1 The validated cluster name
kubedee::prepare_worker_image() {
  local name="${1}"
  kubedee::log_info "Pruning old kubedee worker images ..."
  for c in $(lxc image list --format json | jq -r '.[].aliases[].name'); do
    if [[ "${c}" == "kubedee-image-worker-"* ]] && ! [[ "${c}" == "${kubedee_image_worker}" ]]; then
      lxc image delete "${c}"
    fi
  done
  lxc image info "${kubedee_image_worker}" &>/dev/null && return
  kubedee::log_info "Preparing kubedee worker image ..."
  lxc delete -f "${kubedee_image_worker}-setup" &>/dev/null || true
  lxc launch \
    --storage kubedee \
    --network "kubedee-${name}" \
    --config raw.lxc="lxc.aa_allow_incomplete=1" \
    "${kubedee_container_image}" "${kubedee_image_worker}-setup"
  kubedee::container_wait_running "${kubedee_image_worker}-setup"
  cat <<'EOF' | lxc exec "${kubedee_image_worker}-setup" bash
set -euo pipefail

apt-get update
apt-get upgrade -y

# crio requires libgpgme11
apt-get install -y libgpgme11
EOF
  lxc snapshot "${kubedee_image_worker}-setup" snap
  lxc publish "${kubedee_image_worker}-setup/snap" --alias "${kubedee_image_worker}" kubedee-version="${kubedee_version}"
  lxc delete -f "${kubedee_image_worker}-setup"
}