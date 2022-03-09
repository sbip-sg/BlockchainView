# Must be consistent with in app/global.js

export REVOCABLE_MODE="revocable"
export IRREVOCABLE_MODE="irrevocable"
export VIEWINCONTRACT_MODE="view_in_contract"
export MOCK_MODE="mock_fabric"
export ONLYWORKLOAD_MODE="only_workload"

export ENCRYPTION_SCHEME="encryption"
export HASH_SCHEME="hash"
export PLAIN_SCHEME="plain"

export CHANNEL_NAME="viewchannel"

# export network_dir="../test-network"
export NETWORK_DIR="../gcp-network" 
export ORG_DIR="${NETWORK_DIR}/organizations/peerOrganizations"
export MAX_CLI_RUNNING_TIME=200s
