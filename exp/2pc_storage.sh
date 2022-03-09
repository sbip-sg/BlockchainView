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

SCRIPT_NAME=$(basename $0 .sh)

function network_channel_up() {
    echo "We only spin up a single chain. This single chain runs for all views..."
    echo "  Can modify here to spin up multiple chains. "
    pushd "${NETWORK_DIR}" > /dev/null 2>&1
    ./network.sh up
    echo "Wait for 5s for the network is fully up. "
    sleep 5s
    ./network.sh createChannel -c ${CHANNEL_NAME}
    popd  > /dev/null 2>&1
}

function deploy_chaincode() {
    echo "  Again, now we assume a single chain. This function can be edited to deploy chaincodes on multiple chains. "
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
    echo "  Again, now we assume a single chain. This function can be eidted to turn down multiple chains. "
    pushd "${NETWORK_DIR}" > /dev/null 2>&1
    ./network.sh down
    popd  > /dev/null 2>&1
}

function run_exp() {
    workload_file="$1"
    view_count="$2"
    client_count=4

    network_channel_up

    workload_chaincodeID="txncoordinator"
    deploy_chaincode ${workload_chaincodeID} ${PEER_COUNT}

    result_dir="result/$(date +%d-%m)"
    log_dir="log/$(date +%d-%m)"
    mkdir -p ${log_dir}
    mkdir -p ${result_dir}

    ORG_DIRS=()
    # for i in $(seq ${view_count}) 
    # do
        
        ORG_DIRS+=(${ORG_DIR}) # We use a single chain to simulate multiple chains. 
    # done

    echo "========================================================="
    echo "Start launching ${client_count} client processes. # of views : ${view_count}."
    for i in $(seq ${client_count}) 
    do
        log_file="${log_dir}/${SCRIPT_NAME}_$(basename ${workload_file} .json)_${view_count}views_${i}.log"
        echo "    Client ${i} log at ${log_file}"

        (timeout ${MAX_CLI_RUNNING_TIME} node supplychain_2pc.js ${workload_file} ${view_count} ${CHANNEL_NAME} ${ORG_DIRS[@]} > ${log_file} 2>&1 ; exit 0) &
    done

    echo "Wait for at most ${MAX_CLI_RUNNING_TIME} for client processes to finish"
    wait


    result_file="${result_dir}/${SCRIPT_NAME}_$(basename ${workload_file} .json)_${view_count}views"

    echo "=========================================================="
    echo "Here we assume a single chain. May modify here to sum up the ledger size of all chains when employing multiple chains."
    echo "Ledger Storage results " | tee ${result_file}

    # for i in $(seq ${view_count}) 
    # do
    #     ORG_ID=$((i-1))
        ORG_ID=0
        echo "  Ledger Info of Chain ${ORG_ID}: " | tee -a ${result_file}
        node ledger_storage.js ${ORG_DIRS[${ORG_ID}]} ${CHANNEL_NAME} | tee -a ${result_file}
        echo "" | tee -a ${result_file}
    # done

    echo "=========================================================="

    network_down
}

# The main function
main() {
    if [[ $# < 2 ]]; then 
       echo "Insufficient arguments, expecting at least 2, actually $#" >&2 
       echo "    Usage: $0 [workload_path] [view_count] " >&2 
       exit 1
    fi
    pushd ${__SCRIPT_DIR} > /dev/null 2>&1
    
    workload_file="$1"
    view_count=$2

    run_exp ${workload_file} ${view_count}

    popd > /dev/null 2>&1
}

main "$@"

# exit normally except being sourced.
[[ "$0" != "${BASH_SOURCE[0]}" ]] || exit 0