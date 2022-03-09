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

# IFS=$'\t\n'    # Split on newlines and tabs (but not on spaces)

# Global variables
[[ -n "${__SCRIPT_DIR+x}" ]] || readonly __SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
[[ -n "${__SCRIPT_NAME+x}" ]] || readonly __SCRIPT_NAME="$(basename -- $0)"

PEER_COUNT=2

. env.sh

function network_channel_up() {
    pushd "${NETWORK_DIR}" > /dev/null 2>&1
    ./network.sh up
    echo "Wait for 5s for the network is fully up. "
    sleep 5s
    ./network.sh createChannel -c ${CHANNEL_NAME}
    popd  > /dev/null 2>&1
}

function deploy_chaincode() {
    pushd "${NETWORK_DIR}" > /dev/null 2>&1
    chaincode_name="$1"
    peer_count=$2
    all_org=""
    for i in $(seq ${peer_count})
    do
        all_org="$all_org 'Org${i}MSP.peer'"
    done

    function join_by { local d=$1; shift; local f=$1; shift; printf %s "$f" "${@/#/$d}"; }
    endorse_policy="OR($(join_by , $all_org))"

    ./network.sh deployCC -c ${CHANNEL_NAME} -ccl go -ccn ${chaincode_name} -ccp ../chaincodes/${chaincode_name} -ccep ${endorse_policy} -cccg ../chaincodes/${chaincode_name}/collection_config.json
    popd  > /dev/null 2>&1
}

function network_down() {
    pushd "${NETWORK_DIR}" > /dev/null 2>&1
    ./network.sh down
    popd  > /dev/null 2>&1
}

function run_exp() {
    workload_file="$1"
    hiding_scheme="$2"
    view_mode="$3"
    view_count=$4
    client_count=4

    network_channel_up

    if [[ "$view_mode" == "${REVOCABLE_MODE}" ]] ; then
        workload_chaincodeID="secretcontract"
        deploy_chaincode ${workload_chaincodeID} ${PEER_COUNT}
    fi

    if [[ "$view_mode" == "${IRREVOCABLE_MODE}" ]] ; then
        deploy_chaincode "viewstorage" ${PEER_COUNT}

        workload_chaincodeID="secretcontract"
        deploy_chaincode ${workload_chaincodeID} ${PEER_COUNT}
    fi

    if [[ "$view_mode" == "${VIEWINCONTRACT_MODE}" ]] ; then
        workload_chaincodeID="onchainview"
        deploy_chaincode ${workload_chaincodeID} ${PEER_COUNT}
    fi

    result_dir="result/$(date +%d-%m)"
    log_dir="log/$(date +%d-%m)"
    mkdir -p ${log_dir}
    mkdir -p ${result_dir}

    echo "========================================================="
    echo "Start launching ${client_count} client processes with data hiding scheme : ${hiding_scheme}, view mode : ${view_mode}, # of views : ${view_count}."
    for i in $(seq ${client_count}) 
    do
        log_file="${log_dir}/storage_$(basename ${workload_file} .json)_${hiding_scheme}_${view_mode}_${view_count}views_${i}.log"
        echo "    Client ${i} log at ${log_file}"
        (timeout ${MAX_CLI_RUNNING_TIME} node supplychain_view.js ${ORG_DIR} ${workload_file} ${hiding_scheme} ${view_mode} ${CHANNEL_NAME} ${workload_chaincodeID} ${view_count} > ${log_file}  2>&1 ; exit 0) & 
    done

    echo "Wait for at most ${MAX_CLI_RUNNING_TIME} for client processes to finish"
    wait

    result_file="${result_dir}/storage_$(basename ${workload_file} .json)_${hiding_scheme}_${view_mode}_${view_count}views"

    echo "Ledger Info: " | tee ${result_file}
    node ledger_storage.js ${ORG_DIR} ${CHANNEL_NAME} | tee -a ${result_file}

    network_down
}


# The main function
main() {
    if [[ $# < 2 ]]; then 
       echo "Insufficient arguments, expecting at least 2, actually $#" >&2 
       echo "    Usage: view_storage.sh [workload_path] [view_count] " >&2 
       exit 1
    fi
    pushd ${__SCRIPT_DIR} > /dev/null 2>&1

    workload_file="$1"
    view_count=$2
    # for hiding_scheme in "${ENCRYPTION_SCHEME}"  ; do
    #     for view_mode in "${IRREVOCABLE_MODE}"  ; do
    for hiding_scheme in "${ENCRYPTION_SCHEME}" "${HASH_SCHEME}"  ; do
        for view_mode in "${REVOCABLE_MODE}" "${IRREVOCABLE_MODE}" "${VIEWINCONTRACT_MODE}" ; do
            run_exp ${workload_file} ${hiding_scheme} ${view_mode} ${view_count}
        done
    done

    popd > /dev/null 2>&1
}

main "$@"

# exit normally except being sourced.
[[ "$0" != "${BASH_SOURCE[0]}" ]] || exit 0