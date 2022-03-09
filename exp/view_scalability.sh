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
    peer_count=$1
    export PEER_COUNT=${peer_count}

    pushd ${NETWORK_DIR} > /dev/null 2>&1
    ./network.sh up
    wait_duration=5s
    echo "Wait for ${wait_duration} for the network fully up"
    sleep ${wait_duration}
    ./network.sh createChannel -c ${CHANNEL_NAME}
    popd  > /dev/null 2>&1
}

function deploy_chaincode() {
    chaincode_name="$1"
    peer_count=$2
    export PEER_COUNT=${peer_count}
    all_org=""
    for i in $(seq ${peer_count})
    do
        all_org="$all_org 'Org${i}MSP.peer'"
    done
    function join_by { local d=$1; shift; local f=$1; shift; printf %s "$f" "${@/#/$d}"; }
    endorse_policy="OR($(join_by , $all_org))"

    pushd ${NETWORK_DIR} > /dev/null 2>&1
    ./network.sh deployCC -c ${CHANNEL_NAME} -ccl go -ccn ${chaincode_name} -ccp ../chaincodes/${chaincode_name} -ccep ${endorse_policy} -cccg ../chaincodes/${chaincode_name}/collection_config.json
    popd  > /dev/null 2>&1
}

function network_down() {
    peer_count=$1
    export PEER_COUNT=${peer_count}
    pushd ${NETWORK_DIR} > /dev/null 2>&1
    ./network.sh down
    popd  > /dev/null 2>&1
}

function run_exp() {
    workload_file="$1"
    hiding_scheme="$2"
    workload_chaincodeID="$3"  
    peer_count=$4

    export PEER_COUNT=${peer_count}

    view_mode="${VIEWINCONTRACT_MODE}"
    client_count=48

    network_channel_up ${peer_count}

    deploy_chaincode ${workload_chaincodeID} ${peer_count}

    result_dir="result/$(date +%d-%m)"
    log_dir="log/$(date +%d-%m)"
    mkdir -p ${log_dir}
    mkdir -p ${result_dir}

    echo "========================================================="
    echo "Start launching ${client_count} client processes with data hiding scheme : ${hiding_scheme}, view mode : ${view_mode}, workload_chaincodeID : ${workload_chaincodeID}, # of peers : ${peer_count} ."
    for i in $(seq ${client_count}) 
    do
        log_file="${log_dir}/${SCRIPT_NAME}_$(basename ${workload_file} .json)_${hiding_scheme}_${workload_chaincodeID}_${peer_count}peers_${i}.log"
        echo "    Client ${i} log at ${log_file}"
        (timeout ${MAX_CLI_RUNNING_TIME} node supplychain_view.js ${ORG_DIR} ${workload_file} ${hiding_scheme} ${view_mode} ${CHANNEL_NAME} ${workload_chaincodeID} > ${log_file} 2>&1 ; exit 0 ) &
    done

    echo "Wait for at most ${MAX_CLI_RUNNING_TIME} for client processes to finish"
    wait

    aggregated_result_file="${result_dir}/${SCRIPT_NAME}_$(basename ${workload_file} .json)_${hiding_scheme}_${workload_chaincodeID}_${peer_count}peers"

    echo "=========================================================="
    echo "Aggregate client results " | tee ${aggregated_result_file}

    total_thruput=0
    total_batch_delay=0
    finished_cli_count=0
    for i in $(seq ${client_count}) 
    do
        # Must be identical to the above
        log_file="${log_dir}/${SCRIPT_NAME}_$(basename ${workload_file} .json)_${hiding_scheme}_${workload_chaincodeID}_${peer_count}peers_${i}.log"

        last_line="$(tail -1 ${log_file})" 

        if [[ "${last_line}" =~ ^Total* ]]; then
            finished_cli_count=$((${finished_cli_count}+1))
            IFS=' ' read -ra tokens <<< "${last_line}"
            latency=${tokens[3]} # ms units
            app_txn_count=${tokens[9]}
            committed_count=${tokens[14]}
            batch_delay=${tokens[20]}

            thruput=$((${committed_count}*1000/${latency})) # tps
            total_batch_delay=$((${total_batch_delay}+${batch_delay}))
            echo "    result_${i}: total_duration: ${latency} ms, app_txn_count: ${app_txn_count}, committed_count: ${committed_count} thruput: ${thruput} avg batch delay: ${batch_delay}" | tee -a ${aggregated_result_file} 
            total_thruput=$((${total_thruput}+${thruput}))
        else
            echo "    Client ${i} does not finish within ${MAX_CLI_RUNNING_TIME}. " | tee -a ${aggregated_result_file} 
        fi
    done

    if (( ${finished_cli_count} == 0 )); then
        echo "No clients finish in time. "
    else
        avg_batch_delay=$((${total_batch_delay}/${finished_cli_count}))
        echo "Total Thruput(tps): ${total_thruput} tps, Batch Delay(ms): ${avg_batch_delay}" | tee -a ${aggregated_result_file}
    fi
    echo "=========================================================="

    network_down ${peer_count}
}


# The main function
main() {
    if [[ $# < 1 ]]; then 
       echo "Insufficient arguments, expecting at least 1, actually $#" >&2 
       echo "    Usage: view_scalability.sh [workload_path] [peer_count]" >&2 
       exit 1
    fi
    pushd ${__SCRIPT_DIR} > /dev/null 2>&1
    
    workload_file="$1"
    peer_count=$2
    # Protect the secret data by encryption and store the encrypted as a transaction's public part. 
    run_exp ${workload_file}  "${ENCRYPTION_SCHEME}" "onchainview" ${peer_count}

    # Store the plain secret as a transaction's private part. 
    run_exp ${workload_file} "${PLAIN_SCHEME}" "privateonchainview" ${peer_count}

    # Store the plain secret as a transaction's private part, but no view manamgent in contracts. 
    run_exp ${workload_file} "${PLAIN_SCHEME}" "privateonly" ${peer_count}

    popd > /dev/null 2>&1
}

main "$@"

# exit normally except being sourced.
[[ "$0" != "${BASH_SOURCE[0]}" ]] || exit 0