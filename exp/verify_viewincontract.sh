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

. env.sh
SCRIPT_NAME=$(basename $0 .sh)

function network_channel_up() {
    pushd ${NETWORK_DIR} > /dev/null 2>&1
    ./network.sh up
    wait_period=5s
    echo "Wait for ${wait_period} for the system fully up"
    sleep ${wait_period}
    ./network.sh createChannel -c ${CHANNEL_NAME}
    popd  > /dev/null 2>&1
}

function deploy_chaincode() {
    pushd ${NETWORK_DIR} > /dev/null 2>&1
    chaincode_name="$1"
    all_org=""
    for i in $(seq ${PEER_COUNT})
    do
        all_org="$all_org 'Org${i}MSP.peer'"
    done

    function join_by { local d=$1; shift; local f=$1; shift; printf %s "$f" "${@/#/$d}"; }
    endorse_policy="OR($(join_by , $all_org))"

    ./network.sh deployCC -c ${CHANNEL_NAME} -ccl go -ccn ${chaincode_name} -ccp ../chaincodes/${chaincode_name} -ccep ${endorse_policy} -cccg ../chaincodes/${chaincode_name}/collection_config.json
    popd  > /dev/null 2>&1
}

function network_down() {
    pushd ${NETWORK_DIR} > /dev/null 2>&1
    ./network.sh down
    popd  > /dev/null 2>&1
}

function run_exp() {

    hiding_scheme="$1"
    txn_count=$2
    scanned_txn_per_batch=$3
    workload_chaincodeID="onchainview"
    
    network_channel_up
    deploy_chaincode ${workload_chaincodeID} ${PEER_COUNT}

    result_dir="result/$(date +%d-%m)"
    log_dir="log/$(date +%d-%m)"
    mkdir -p ${log_dir}
    mkdir -p ${result_dir}

    echo "========================================================="
    echo "Start a single client process with data hiding scheme : ${hiding_scheme}, # of txns : ${txn_count} , # of scanned txns per batch : ${scanned_txn_per_batch}."

    log_file="${log_dir}/${SCRIPT_NAME}_${hiding_scheme}_${txn_count}txns_${scanned_txn_per_batch}batchsize.log"
    echo "  log at ${log_file}"

    node verify_viewincontract.js ${ORG_DIR} ${hiding_scheme} ${CHANNEL_NAME} ${txn_count} ${scanned_txn_per_batch} > ${log_file} 2>&1

    result_file="${result_dir}/${SCRIPT_NAME}_${hiding_scheme}_${txn_count}txns_${scanned_txn_per_batch}batchsize.log"

    echo "---------------------------------------------------------"
    echo "Verification Delay from a client: " | tee ${result_file}

    echo "Verifying Soundness: " | tee -a ${result_file} 
    tail -2 ${log_file} | head -1 | tee -a ${result_file}
    echo "" | tee -a ${result_file}
    echo "Verifying Completeness: " | tee -a ${result_file} 
    tail -1 ${log_file} | tee -a ${result_file}
    echo "========================================================="

    network_down
}


# The main function
main() {
    if [[ $# < 0 ]]; then 
       echo "Insufficient arguments, expecting at least 0, actually $#" >&2 
       echo "    Usage: $0 " >&2 
       exit 1
    fi
    pushd ${__SCRIPT_DIR} > /dev/null 2>&1
    scanned_txn_per_batch=50
    for hiding_scheme in "${ENCRYPTION_SCHEME}"  ; do
        # for txn_count in 400 600 800 1000 ; do
        for txn_count in 200 400 600 800 1000 ; do
            run_exp ${hiding_scheme} ${txn_count} ${scanned_txn_per_batch}
        done
    done

    popd > /dev/null 2>&1
}

main "$@"

# exit normally except being sourced.
[[ "$0" != "${BASH_SOURCE[0]}" ]] || exit 0