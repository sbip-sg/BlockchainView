#!/bin/bash

set -o nounset
# Exit on error. Append || true if you expect an error.
set -o errexit
# Exit on error inside any functions or subshells.
set -o errtrace
# Catch the error in case mysqldump fails (but gzip succeeds) in `mysqldump |gzip`
set -o pipefail
# Turn on traces, useful while debugging but commented out by default
# set -o xtrace

IFS=$'\t\n'    # Split on newlines and tabs (but not on spaces)

# Global variables
[[ -n "${__SCRIPT_DIR+x}" ]] || readonly __SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
[[ -n "${__SCRIPT_NAME+x}" ]] || readonly __SCRIPT_NAME="$(basename -- $0)"

. ./env.sh

function gcp_network_new() {
    cecho "GREEN" "Creating a network ${GCP_NETWORK}..."
    gcloud compute networks create ${GCP_NETWORK} --bgp-routing-mode=global -q

    cecho "GREEN" "Creating a firewall rule ${FIREWALL_RULENAME} for the network..."
    # three tcp 705x ports for fabric. 
    gcloud compute firewall-rules create ${FIREWALL_RULENAME} \
        --network ${GCP_NETWORK} \
        --allow tcp:22,tcp:3389,tcp:7050,tcp:7051,tcp:7052,icmp \
        --quiet

}

function gcp_instance_up() {
    cecho "GREEN" "Creating a DNS zone ${DNS_ZONE} with suffix ${DNS_SUFFIX} for the network..."
    gcloud dns managed-zones create ${DNS_ZONE} -q \
    --description="for running fabric" \
    --dns-name=${DNS_SUFFIX} \
    --networks=${GCP_NETWORK} \
    --visibility=private

    cecho "GREEN" "Creating ${PEER_COUNT} peer instances..."
    for i in $(seq 0 $((PEER_COUNT-1)))
    do
        peer_instance=${PEER_INSTANCES[$i]}
        peer_zone=${PEER_ZONES[$i]}
        cecho "GREEN" "    Launching ${peer_instance} at Zone ${peer_zone}"
        # Stagger requests. Or, gcloud will reject them
        sleep 1s 
        # For some reason, gcloud beta release must be used for source-machine image flag
        gcloud beta compute instances create ${peer_instance} \
            --zone=${peer_zone} \
            --machine-type=${MACHINE_TYPE} \
            --network=${GCP_NETWORK} \
            --source-machine-image=${FABRIC_ENV_IMAGE} \
            --quiet &
    done

    local orderer_count=${#ORDERER_INSTANCES[@]}
    cecho "GREEN" "Creating ${orderer_count} orderer instances..."
    for i in $(seq 0 $((orderer_count-1)))
    do
        orderer_instance=${ORDERER_INSTANCES[$i]}
        orderer_zone=${ORDERER_ZONES[$i]}
        cecho "GREEN" "    Launching ${orderer_instance} at Zone ${orderer_zone}"

        sleep 1s 
        # For some reason, gcloud beta release must be used for source-machine image flag
        gcloud beta compute instances create ${orderer_instance} \
            --zone=${orderer_zone} \
            --machine-type=${MACHINE_TYPE} \
            --network=${GCP_NETWORK} \
            --source-machine-image=${FABRIC_ENV_IMAGE} \
            --quiet &
    done

    cecho "GREEN" "Wait for instances to fully launch..."
    wait

    local orderer_count=${#ORDERER_INSTANCES[@]}
    cecho "GREEN" "Start DNS Modfication..."
    rm -rf transaction.yaml # In case a DNS txn happens in the middle
    gcloud dns record-sets transaction start --zone="${DNS_ZONE}"

    echo "Dumping peers' internal ips to ${PEER_INTERNAL_IP_PATH}, and external ips to ${PEER_EXTERNAL_IP_PATH}. And updating their internal ips to DNS..."
    rm -rf ${PEER_INTERNAL_IP_PATH}
    rm -rf ${PEER_EXTERNAL_IP_PATH}

    for i in $(seq 0 $((PEER_COUNT-1)))
    do
        peer_instance=${PEER_INSTANCES[$i]}
        peer_zone=${PEER_ZONES[$i]}
        peer_dns_name=${PEER_DNS_NAMES[$i]}
        peer_internal_ip=$(internal_ip ${peer_zone} ${peer_instance})
        peer_external_ip=$(external_ip ${peer_zone} ${peer_instance})

        cecho "GREEN" "   Instance ${peer_instance}: Internal IP -- ${peer_internal_ip} External IP -- ${peer_external_ip} "
        echo "${peer_internal_ip}" >> ${PEER_INTERNAL_IP_PATH}
        echo "${peer_external_ip}" >> ${PEER_EXTERNAL_IP_PATH}
        gcloud dns record-sets transaction add "${peer_internal_ip}" --name="${peer_dns_name}" --ttl="3600" --type="A" --zone="${DNS_ZONE}"
    done

    echo "Dumping orderers' internal ips to ${ORDERER_INTERNAL_IP_PATH}, and external ips to ${ORDERER_EXTERNAL_IP_PATH}.... And updating their internal ips to DNS..."
    rm -rf ${ORDERER_INTERNAL_IP_PATH}
    rm -rf ${ORDERER_EXTERNAL_IP_PATH}

    for i in $(seq 0 $((orderer_count-1)))
    do
        orderer_instance=${ORDERER_INSTANCES[$i]}
        orderer_zone=${ORDERER_ZONES[$i]}
        orderer_dns_name=${ORDERER_DNS_NAMES[$i]}
        orderer_internal_ip=$(internal_ip ${orderer_zone} ${orderer_instance})
        orderer_external_ip=$(external_ip ${orderer_zone} ${orderer_instance})

        cecho "GREEN" "   Instance ${orderer_instance}: Internal IP -- ${orderer_internal_ip} External IP -- ${orderer_external_ip} "
        echo "${orderer_internal_ip}" >> ${ORDERER_INTERNAL_IP_PATH}
        echo "${orderer_external_ip}" >> ${ORDERER_EXTERNAL_IP_PATH}
        gcloud dns record-sets transaction add "${orderer_internal_ip}" --name="${orderer_dns_name}" --ttl="3600" --type="A" --zone="${DNS_ZONE}"
    done
    gcloud dns record-sets transaction execute --zone="${DNS_ZONE}"

    # Flush local dns cache 
    sudo systemd-resolve --flush-caches
}


function gcp_instance_down() {
    cecho "GREEN" "Delete instances and remove DNS records..."
    gcloud dns record-sets transaction start --zone="${DNS_ZONE}"

    for i in $(seq 0 $((PEER_COUNT-1)))
    do
        peer_instance=${PEER_INSTANCES[$i]}
        peer_zone=${PEER_ZONES[$i]}
        peer_dns_name=${PEER_DNS_NAMES[$i]}
        peer_internal_ip=$(internal_ip ${peer_zone} ${peer_instance})

        cecho "GREEN" "   Removing Peer Instance ${peer_instance}: Internal IP -- ${peer_internal_ip}"
        gcloud dns record-sets transaction remove "${peer_internal_ip}" --name="${peer_dns_name}" --ttl="3600" --type="A" --zone="${DNS_ZONE}"
        gcloud compute instances delete --zone="${peer_zone}" --quiet "${peer_instance}" &
    done

    local orderer_count=${#ORDERER_INSTANCES[@]}
    for i in $(seq 0 $((orderer_count-1)))
    do
        orderer_instance=${ORDERER_INSTANCES[$i]}
        orderer_zone=${ORDERER_ZONES[$i]}
        orderer_dns_name=${ORDERER_DNS_NAMES[$i]}
        orderer_internal_ip=$(internal_ip ${orderer_zone} ${orderer_instance})

        cecho "GREEN" "   Removing Orderer Instance ${orderer_instance}: Internal IP -- ${orderer_internal_ip}"

        gcloud dns record-sets transaction remove "${orderer_internal_ip}" --name="${orderer_dns_name}" --ttl="3600" --type="A" --zone="${DNS_ZONE}"
        gcloud compute instances delete --zone="${orderer_zone}" --quiet "${orderer_instance}" &
    done

    gcloud dns record-sets transaction execute --zone="${DNS_ZONE}"
    cecho "GREEN" "Wait for all instances to fully delete..."
    wait

    cecho "GREEN" "Remove files with instance ips..."
    rm -rf ${ORDERER_INTERNAL_IP_PATH} ${ORDERER_EXTERNAL_IP_PATH} ${PEER_INTERNAL_IP_PATH} ${PEER_EXTERNAL_IP_PATH}

    cecho "GREEN" "Remove DNS zone ${DNS_ZONE}..."
    gcloud dns managed-zones delete --quiet ${DNS_ZONE}
}

function gcp_network_delete() {

    cecho "GREEN" "Remove Firewall rule ${FIREWALL_RULENAME}..."
    gcloud compute firewall-rules delete --quiet ${FIREWALL_RULENAME}

    cecho "GREEN" "Remove network ${GCP_NETWORK}..."
    gcloud compute networks delete --quiet "${GCP_NETWORK}"
}

# The main function
main() {
    if (( $# < 1 )); then 
       echo "Insufficient arguments, expecting at least 1, actually $#" >&2 
       echo "    Usage: $0 [network_new|network_delete|instance_up|instance_down]" >&2 
       exit 1
    fi
    # pushd ${__SCRIPT_DIR} > /dev/null 2>&1

    if [ -z "${PEER_COUNT}" ]; then
        fatalln '$PEER_COUNT not set. exiting the program...'
    fi

    if [[ $1 == "network_new" ]]; then
        gcp_network_new
    elif [[ $1 == "network_delete" ]]; then
        gcp_network_delete
    elif [[ $1 == "instance_up" ]]; then
        gcp_instance_up
    elif [[ $1 == "instance_down" ]]; then
        gcp_instance_down
    else
        echo "Unrecognized cmd $1" 
        exit 1
    fi

    # popd > /dev/null 2>&1
}

main "$@"

# exit normally except being sourced.
[[ "$0" != "${BASH_SOURCE[0]}" ]] || exit 0