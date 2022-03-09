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
    pushd ${NETWORK_DIR} > /dev/null 2>&1
    ./network.sh up
    ./network.sh createChannel -c ${CHANNEL_NAME}
    popd  > /dev/null 2>&1
}

function deploy_chaincode() {
    pushd ${NETWORK_DIR} > /dev/null 2>&1
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
    pushd ${NETWORK_DIR} > /dev/null 2>&1
    ./network.sh down
    popd  > /dev/null 2>&1
}

function run_exp() {
    workload_file="$1"
    hiding_scheme="$2"
    view_mode="$3"
    client_count=$4

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
    echo "Start launching ${client_count} client processes with data hiding scheme : ${hiding_scheme}, view mode : ${view_mode}."
    for i in $(seq ${client_count}) 
    do
        log_file="${log_dir}/${SCRIPT_NAME}_$(basename ${workload_file} .json)_${hiding_scheme}_${view_mode}_${i}_${client_count}.log"
        echo "    Client ${i} log at ${log_file}"
        (timeout ${MAX_CLI_RUNNING_TIME} node supplychain_view.js ${ORG_DIR} ${workload_file} ${hiding_scheme} ${view_mode} ${CHANNEL_NAME} ${workload_chaincodeID} > ${log_file} 2>&1 ; exit 0) & # if timeout, the command returns with status code 0 instead of 124; so that the script will not exit. 
    done

    echo "Wait for at most ${MAX_CLI_RUNNING_TIME} for client processes to finish"
    wait

    aggregated_result_file="${result_dir}/${SCRIPT_NAME}_$(basename ${workload_file} .json)_${hiding_scheme}_${view_mode}_${client_count}clients"

    echo "=========================================================="
    echo "Aggregate client results " | tee ${aggregated_result_file}

    total_thruput=0
    total_batch_delay=0
    finished_cli_count=0

    for i in $(seq ${client_count}) 
    do
        # Must be identical to the above
        log_file="${log_dir}/${SCRIPT_NAME}_$(basename ${workload_file} .json)_${hiding_scheme}_${view_mode}_${i}_${client_count}.log"

        last_line="$(tail -1 ${log_file})" 
        if [[ "${last_line}" =~ ^Total* ]]; then

            IFS=' ' read -ra tokens <<< "${last_line}"
            latency=${tokens[3]} # ms units
            app_txn_count=${tokens[9]}
            committed_count=${tokens[14]}
            batch_delay=${tokens[20]}

            thruput=$((${committed_count}*1000/${latency})) # tps
            total_batch_delay=$((${total_batch_delay}+${batch_delay}))
            echo "    result_${i}: total_duration: ${latency} ms, app_txn_count: ${app_txn_count}, committed_count: ${committed_count} thruput: ${thruput} avg batch delay: ${batch_delay}" | tee -a ${aggregated_result_file} 
            total_thruput=$((${total_thruput}+${thruput}))
            finished_cli_count=$((${finished_cli_count}+1))

        else
            echo "    Client ${i} does not finish within ${MAX_CLI_RUNNING_TIME}. " | tee -a ${aggregated_result_file} 
        fi
    done

    if (( ${finished_cli_count} == 0 )); then
        echo "No clients finish in time. "
    else
        avg_batch_delay=$((${total_batch_delay}/${finished_cli_count}))
        echo "Total Thruput(tps): ${total_thruput} tps, Batch Delay(ms): ${avg_batch_delay} , # of Finished Client: ${finished_cli_count} " | tee -a ${aggregated_result_file}
    fi
    echo "=========================================================="

    network_down
}


# The main function
main() {
    if [[ $# < 2 ]]; then 
       echo "Insufficient arguments, expecting at least 2, actually $#" >&2 
       echo "    Usage: perf_end2end.sh [workload_path] [client_count]" >&2 
       exit 1
    fi
    pushd ${__SCRIPT_DIR} > /dev/null 2>&1
    
    workload_file="$1"
    client_count=$2

    for hiding_scheme in "${ENCRYPTION_SCHEME}" "${HASH_SCHEME}" ; do
        for view_mode in "${REVOCABLE_MODE}" "${IRREVOCABLE_MODE}" "${VIEWINCONTRACT_MODE}"; do
            run_exp ${workload_file} ${hiding_scheme} ${view_mode} ${client_count}
            echo "Sleep for 10s before the next experiment"
            sleep 10s
        done
    done

    popd > /dev/null 2>&1
}

main "$@"

# exit normally except being sourced.
[[ "$0" != "${BASH_SOURCE[0]}" ]] || exit 0