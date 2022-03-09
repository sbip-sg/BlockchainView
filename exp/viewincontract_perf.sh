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
    wait_period=5s
    echo "Wait for ${wait_period} for the system fully up"
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

    hiding_scheme="$1"
    view_count="$2"
    selectivity="$3"
    client_count=$4
    workload_chaincodeID="onchainview"
    
    txn_count=400
    batch_size=50

    network_channel_up
    deploy_chaincode ${workload_chaincodeID} ${PEER_COUNT}


    result_dir="result/$(date +%d-%m)"
    log_dir="log/$(date +%d-%m)"
    mkdir -p ${log_dir}
    mkdir -p ${result_dir}

    echo "========================================================="
    echo "Start launching ${client_count} client processes with data hiding scheme : ${hiding_scheme}, # of views : ${view_count}, # of txns : ${txn_count} , txns per batch : ${batch_size}, selectivity : ${selectivity}."

    for i in $(seq ${client_count}) 
    do
        log_file="${log_dir}/${SCRIPT_NAME}_${hiding_scheme}_${view_count}views_${selectivity}_${client_count}clients_${i}.log"
        echo "    Client ${i} log at ${log_file}"

        (timeout ${MAX_CLI_RUNNING_TIME}  node perf_viewincontract.js ${ORG_DIR} ${hiding_scheme} ${CHANNEL_NAME} ${view_count} ${txn_count} ${batch_size} ${selectivity} > ${log_file} 2>&1 ; exit 0) &
    done

    echo "Wait for at most ${MAX_CLI_RUNNING_TIME} for client processes to finish"
    wait

    aggregated_result_file="${result_dir}/${SCRIPT_NAME}_${hiding_scheme}_${view_count}views_${selectivity}"

    echo "=========================================================="
    echo "Aggregate client results " | tee ${aggregated_result_file}

    total_thruput=0
    total_batch_delay=0
    finished_cli_count=0

    for i in $(seq ${client_count}) 
    do
        # Must be identical to the above
        log_file="${log_dir}/${SCRIPT_NAME}_${hiding_scheme}_${view_count}views_${selectivity}_${client_count}clients_${i}.log"

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
            finished_cli_count=$((${finished_cli_count}+1))

            total_thruput=$((${total_thruput}+${thruput}))
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
    if [[ $# < 3 ]]; then 
       echo "Insufficient arguments, expecting at least 3, actually $#" >&2 
       echo "    Usage: viewincontract_perf.sh <selectivity [all | single]> <view_count> <cli_count> " >&2 
       exit 1
    fi
    pushd ${__SCRIPT_DIR} > /dev/null 2>&1
    selectivity="$1"
    view_count=$2
    cli_count=$3

    for hiding_scheme in "${ENCRYPTION_SCHEME}" "${HASH_SCHEME}"  ; do
        run_exp ${hiding_scheme} ${view_count} ${selectivity} ${cli_count}
    done

    popd > /dev/null 2>&1
}

main "$@"

# exit normally except being sourced.
[[ "$0" != "${BASH_SOURCE[0]}" ]] || exit 0