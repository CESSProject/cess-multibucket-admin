#!/bin/bash

multibucket_admin_version="v0.0.2"
aliyun_address="region.cn-hangzhou.aliyuncs.com"
skip_chain="false"
base_dir=/opt/cess/multibucket-admin
script_dir=$base_dir/scripts
config_path=$base_dir/config.yaml
build_dir=$base_dir/build
compose_yaml=$build_dir/docker-compose.yaml
profile="testnet"
kernel_ver_req="5.11"
docker_ver_req="20.10"
yq_ver_req="4.25"
cpu_req=4
ram_req=8
PM=""
DISTRO=""

each_bucket_ram_req=4  # at least 4GB RAM for each bucket
each_bucket_cpu_req=1  # at least 1 core for each bucket
each_rpcnode_ram_req=2 # at least 2GB RAM for each rpcnode
each_rpcnode_cpu_req=1 # at least 1 core for each rpcnode

function echo_c() {
  printf "\033[0;$1m$2\033[0m\n"
}

function log_info() {
  echo_c 33 "$1"
}

function log_success() {
  echo_c 32 "$1"
}

function log_err() {
  echo_c 35 "[ERROR] $1"
}

check_port() {
  local port=$1
  local grep_port=$(netstat -tlpn | grep "\b$port\b")
  if [ -n "$grep_port" ]; then
    log_err "please make sure port $port is not occupied"
    exit 1
  fi
}

## 0 for running, 2 for error, 1 for stop
check_docker_status() {
  local exist=$(docker inspect --format '{{.State.Running}}' $1 2>/dev/null)
  if [ x"${exist}" == x"true" ]; then
    return 0
  elif [ "${exist}" == "false" ]; then
    return 2
  else
    return 1
  fi
}

## rnd=$(rand 1 50)
rand() {
  min=$1
  max=$(($2 - $min + 1))
  num=$(date +%s%N)
  echo $(($num % $max + $min))
}

ensure_root() {
  if [ $(id -u) -ne 0 ]; then
    log_err "Please run with sudo!"
    exit 1
  fi
}

get_distro_name() {
  if grep -Eqi "Ubuntu" /etc/issue || grep -Eq "Ubuntu" /etc/*-release; then
    DISTRO='Ubuntu'
    PM='apt'
  elif grep -Eqi "CentOS" /etc/issue || grep -Eq "CentOS" /etc/*-release; then
    DISTRO='CentOS'
    PM='yum'
  elif grep -Eqi "Red Hat Enterprise Linux Server" /etc/issue || grep -Eq "Red Hat Enterprise Linux Server" /etc/*-release; then
    DISTRO='RHEL'
    PM='yum'
  elif grep -Eqi "Aliyun" /etc/issue || grep -Eq "Aliyun" /etc/*-release; then
    DISTRO='Aliyun'
    PM='yum'
  elif grep -Eqi "Fedora" /etc/issue || grep -Eq "Fedora" /etc/*-release; then
    DISTRO='Fedora'
    PM='yum'
  elif grep -Eqi "Debian" /etc/issue || grep -Eq "Debian" /etc/*-release; then
    DISTRO='Debian'
    PM='apt'
  elif grep -Eqi "Raspbian" /etc/issue || grep -Eq "Raspbian" /etc/*-release; then
    DISTRO='Raspbian'
    PM='apt'
  else
    log_err 'unsupport linux distro'
    return 1
  fi
  return 0
}

set_profile() {
  local to_set=$1
  if [ -z $to_set ]; then
    log_info "current profile: $profile"
    return 0
  fi
  if [ x"$to_set" == x"devnet" ] || [ x"$to_set" == x"testnet" ] || [ x"$to_set" == x"mainnet" ]; then
    yq -i eval ".node.profile=\"$to_set\"" $config_path
    log_success "the profile set to $to_set"
    return 0
  fi
  log_err "invalid profile value"
  return 1
}

load_profile() {
  local p="$(yq eval ".node.profile" $config_path)"
  if [ x"$p" == x"devnet" ] || [ x"$p" == x"testnet" ] || [ x"$p" == x"mainnet" ]; then
    profile=$p
    return 0
  fi
  log_info "the profile: $p of config file is invalid, use default value: $profile"
  return 1
}

command_exists() {
  command -v "$@" >/dev/null 2>&1
}

# is_ver_a_ge_b compares two CalVer (YY.MM) version strings. returns 0 (success)
# if version A is newer or equal than version B, or 1 (fail) otherwise. Patch
# releases and pre-release (-alpha/-beta) are not taken into account
# compare docker version、linux-kernel version ...
#
# examples:
#
# is_ver_a_ge_b 20.10 19.03 // 0 (success)
# is_ver_a_ge_b 20.10 20.10 // 0 (success)
# is_ver_a_ge_b 19.03 20.10 // 1 (fail)
is_ver_a_ge_b() (
  set +x

  yy_a="$(echo "$1" | cut -d'.' -f1)"
  yy_b="$(echo "$2" | cut -d'.' -f1)"
  if [ "$yy_a" -lt "$yy_b" ]; then
    return 1
  fi
  if [ "$yy_a" -gt "$yy_b" ]; then
    return 0
  fi
  mm_a="$(echo "$1" | cut -d'.' -f2)"
  mm_b="$(echo "$2" | cut -d'.' -f2)"
  if [ "${mm_a}" -lt "${mm_b}" ]; then
    return 1
  fi

  return 0
)

join_by() {
  local d=$1
  shift
  printf '%s\n' "$@" | paste -sd "$d"
}

get_cpu_core_number() {
  local processors=$(grep -c ^processor /proc/cpuinfo)
  echo $processors # echo can run num > 255
}

get_buckets_num() {
  local bucket_port_str=$(yq eval '.buckets[].port' $config_path |xargs)
  read -a ports_arr <<< "$bucket_port_str"
  echo ${#ports_arr[@]}
}

is_cfgfile_valid() {
  log_info "Set Your Config Path"
  read -t 30 -p "Press enter or wait 30s for default, or set your custom absolute config path: " config_path_custom
  if [ -n "$config_path_custom" ]; then
    config_path=$config_path_custom/config.yaml
  fi

  log_info "Config Path is: $config_path"

  if [ ! -f "$config_path" ]; then
    log_err "Error: ConfigFileNotFoundException, config.yaml not found in $config_path"
    exit 1
  fi

  yq '.' "$config_path" >/dev/null
  if [ $? -ne 0 ]; then
    log_err "Config File: config.yaml Parse Error, Please Check Your File Format"
    exit 1
  fi
}

is_kernel_satisfied() {
  local kernal_version=$(uname -r | cut -d . -f 1,2)
  if ! is_ver_a_ge_b $kernal_version $kernel_ver_req; then
    log_err "The kernel version must be greater than 5.11, your version is $kernal_version. Please upgrade the kernel first."
    exit 1
  fi
  log_info "Linux kernel version: $kernal_version"
}

is_base_hardware_satisfied() {
  local cur_core=$(get_cur_cores)
  local cur_ram=$(get_cur_ram)
  if [ "$cur_core" -lt $cpu_req ]; then
    log_err "Cpu Cores must greater than $cpu_req"
    exit 1
  elif [ "$cur_ram" -lt $ram_req ]; then
    log_err "RAM must greater than $ram_req GB"
    exit 1
  else
    log_info "$cur_core CPU cores and $cur_ram GB of RAM In Server"
  fi
  return $?
}

is_base_cores_satisfied() {
  local bucket_num=$(get_buckets_num)
  local base_buckets_cpu_need=$(($bucket_num * $each_bucket_cpu_req))
  local base_rpcnode_cpu_need=$([ $skip_chain == "false" ] && echo "$each_rpcnode_cpu_req" || echo "0")
  local buckets_cpu_req_in_cfg=$(yq eval '.buckets[].UseCpu' $config_path | xargs | awk '{ sum = 0; for (i = 1; i <= NF; i++) sum += $i; print sum }')
  local total_cpu_req=$([ $skip_chain == "false" ] && echo $(($base_buckets_cpu_need + $base_rpcnode_cpu_need)) || echo $base_buckets_cpu_need)

  local cur_core=$(get_cur_cores)

  if [ $total_cpu_req -gt $cur_core ] || [ $buckets_cpu_req_in_cfg -gt $cur_core ]; then
    log_err "Each bucket request $each_bucket_cpu_req core at least, each rpcnode request $each_rpcnode_cpu_req core at least"
    log_err "Installation request: $total_cpu_req cores in total, but $cur_core in current"
    exit 1
  fi
}

is_base_ram_satisfied() {
  local bucket_num=$(get_buckets_num)

  local base_buckets_ram_need=$(($bucket_num * $each_bucket_ram_req))

  local base_rpcnode_ram_need=$([ $skip_chain == "false" ] && echo "$each_rpcnode_ram_req" || echo "0")

  local total_ram_req=$([ $skip_chain == "false" ] && echo $(($base_buckets_ram_need + $base_rpcnode_ram_need)) || echo $base_buckets_ram_need)

  local cur_ram=$(get_cur_ram)

  if [ $total_ram_req -gt $cur_ram ]; then
    log_err "Each bucket request $each_bucket_ram_req GB ram at least, each rpcnode request $each_rpcnode_ram_req GB ram at least"
    log_err "Installation request: $total_ram_req GB ram in total, but $cur_ram in current"
    exit 1
  fi
}

is_ports_valid() {
  local ports=$(yq eval '.buckets[].port' $config_path | xargs)
  for port in $ports; do
    check_port $port
  done
}

is_workpaths_valid() {
  local disk_path=$(yq eval '.buckets[].diskPath' $config_path | xargs)
  read -a path_arr <<<"$disk_path"
  for disk_path in $path_arr; do
    if [ ! -d "$disk_path" ]; then
      log_err "Work path do not exist: $disk_path"
      exit 1
    fi
    if [[ ! $(findmnt -M "$disk_path") ]]; then
      log_err "$disk_path do not mount any file system !"
      exit 1
    fi
  done
}

get_cur_ram() {
  local cur_ram=0
  local ram_unit=$(sudo dmidecode -t memory | grep -v "No Module Installed" | grep -i size | awk '{print $3}' | head -n 1)
  if [ "$ram_unit" == "MB" ]; then
    for num in $(sudo dmidecode -t memory | grep -v "No Module Installed" | grep -i size | awk '{print $2}'); do cur_ram=$((cur_ram + $num / 1024)); done
  elif [ "$ram_unit" == "GB" ]; then
    for num in $(sudo dmidecode -t memory | grep -v "No Module Installed" | grep -i size | awk '{print $2}'); do cur_ram=$((cur_ram + $num)); done
  else
    log_err "RAM unit can not be recognized"
  fi
  echo $cur_ram # echo can return num > 255
}

get_cur_cores() {
  local processors=$(grep -c ^processor /proc/cpuinfo)
  echo $processors # echo can return num > 255
}

mk_workdir() {
  local disk_paths=$(yq eval '.buckets[].diskPath' $config_path | xargs)
  for disk_path in $disk_paths; do
    sudo mkdir -p "$disk_path/bucket" "$disk_path/storage"
  done
}

split_buckets_config() {
  local buckets_num=$(get_buckets_num)
  for ((i = 0; i < buckets_num; i++)); do
    local get_bucket_config_by_index="yq eval '.[$i]' $build_dir/buckets/config.yaml"
    local get_disk_path_by_index="yq eval '.buckets[$i].diskPath' $config_path"
    local each_path="$(eval "$get_disk_path_by_index")/bucket/config.yaml"
    eval $get_bucket_config_by_index >$each_path
  done
}

is_uint() { case $1 in '' | *[!0-9]*) return 1 ;; esac }
is_int() { case ${1#[-+]} in '' | *[!0-9]*) return 1 ;; esac }
is_unum() { case $1 in '' | . | *[!0-9.]* | *.*.*) return 1 ;; esac }
is_num() { case ${1#[-+]} in '' | . | *[!0-9.]* | *.*.*) return 1 ;; esac }
