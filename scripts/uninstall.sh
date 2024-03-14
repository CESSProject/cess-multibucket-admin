#!/bin/bash

no_rmi=0
case "$1" in
--no-rmi)
    no_rmi=1
    shift 1
    ;;
esac

install_dir=/opt/cess/multibucket-admin
compose_yaml=$install_dir/build/docker-compose.yaml
bin_file=/usr/bin/cess-multibucket-admin

if [ $(id -u) -ne 0 ]; then
    echo "Please run with sudo!"
    exit 1
fi

if [ -f "$compose_yaml" ]; then
    docker compose -f $compose_yaml rm -sf
    rmi_opt="--rmi all"
    if [[ $no_rmi -eq 1 ]]; then
        rmi_opt=""
    fi
    docker compose -f $compose_yaml down -v --remove-orphans $rmi_opt
fi

if [ -f "$bin_file" ]; then
    rm /usr/bin/cess-multibucket-admin
fi

rm -rf $install_dir
