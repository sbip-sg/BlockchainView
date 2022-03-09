#!/bin/bash
#
# Copyright IBM Corp All Rights Reserved
#
# SPDX-License-Identifier: Apache-2.0
#

# This script brings up a Hyperledger Fabric network for testing smart contracts
# and applications. The test network consists of two organizations with one
# peer each, and a single node Raft ordering service. Users can also use this
# script to create a channel deploy a chaincode on the channel
#
# prepending $PWD/../bin to PATH to ensure we are picking up the correct binaries
# this may be commented out to resolve installed version of tools if desired
export PATH=${PWD}/../bin:$PATH
export VERBOSE=false

. scripts/utils.sh
. env.sh

if [ -z "${PEER_COUNT}" ]; then
  fatalln '$PEER_COUNT not set. exiting the program...'
fi
export FABRIC_CFG_PATH=${PWD}/configtx${PEER_COUNT}

# Before you can bring up a network, each organization needs to generate the crypto
# material that will define that organization on the network. Because Hyperledger
# Fabric is a permissioned blockchain, each node and user on the network needs to
# use certificates and keys to sign and verify its actions. In addition, each user
# needs to belong to an organization that is recognized as a member of the network.
# You can use the Cryptogen tool or Fabric CAs to generate the organization crypto
# material.

# By default, the sample network uses cryptogen. Cryptogen is a tool that is
# meant for development and testing that can quickly create the certificates and keys
# that can be consumed by a Fabric network. The cryptogen tool consumes a series
# of configuration files for each organization in the "organizations/cryptogen"
# directory. Cryptogen uses the files to generate the crypto  material for each
# org in the "organizations" directory.

# You can also Fabric CAs to generate the crypto material. CAs sign the certificates
# and keys that they generate to create a valid root of trust for each organization.
# The script uses Docker Compose to bring up three CAs, one for each peer organization
# and the ordering organization. The configuration file for creating the Fabric CA
# servers are in the "organizations/fabric-ca" directory. Within the same directory,
# the "registerEnroll.sh" script uses the Fabric CA client to create the identities,
# certificates, and MSP folders that are needed to create the test network in the
# "organizations/ordererOrganizations" directory.

# Create Organization crypto material using cryptogen or CAs
function createOrgs() {
  if [ -d "organizations/peerOrganizations" ]; then
    rm -Rf organizations/peerOrganizations && rm -Rf organizations/ordererOrganizations
  fi

  # Create crypto material using cryptogen
  if [ "$CRYPTO" == "cryptogen" ]; then
    which cryptogen
    if [ "$?" -ne 0 ]; then
      fatalln "cryptogen tool not found. exiting"
    fi
    infoln "Generating certificates using cryptogen tool"

    for i in $(seq 1 ${PEER_COUNT})
    do
      infoln "Creating Org${i} Identities"
      set -x
      cryptogen generate --config=./organizations/cryptogen/crypto-config-org${i}.yaml --output="organizations"
      res=$?
      { set +x; } 2>/dev/null
      if [ $res -ne 0 ]; then
        fatalln "Failed to generate certificates..."
      fi
    done


    infoln "Creating Orderer Org Identities"

    set -x
    cryptogen generate --config=./organizations/cryptogen/crypto-config-orderer.yaml --output="organizations"
    res=$?
    { set +x; } 2>/dev/null
    if [ $res -ne 0 ]; then
      fatalln "Failed to generate certificates..."
    fi
  fi

  # Create crypto material using Fabric CA
  if [ "$CRYPTO" == "Certificate Authorities" ]; then
    fatalln "Certificate Authorities Not Supported..."
  fi

  infoln "Generating CCP files for Org1 and Org2"
  ./organizations/ccp-generate.sh
}

# Once you create the organization crypto material, you need to create the
# genesis block of the orderer system channel. This block is required to bring
# up any orderer nodes and create any application channels.

# The configtxgen tool is used to create the genesis block. Configtxgen consumes a
# "configtx.yaml" file that contains the definitions for the sample network. The
# genesis block is defined using the "TwoOrgsOrdererGenesis" profile at the bottom
# of the file. This profile defines a sample consortium, "SampleConsortium",
# consisting of our two Peer Orgs. This consortium defines which organizations are
# recognized as members of the network. The peer and ordering organizations are defined
# in the "Profiles" section at the top of the file. As part of each organization
# profile, the file points to a the location of the MSP directory for each member.
# This MSP is used to create the channel MSP that defines the root of trust for
# each organization. In essence, the channel MSP allows the nodes and users to be
# recognized as network members. The file also specifies the anchor peers for each
# peer org. In future steps, this same file is used to create the channel creation
# transaction and the anchor peer updates.
#
#
# If you receive the following warning, it can be safely ignored:
#
# [bccsp] GetDefault -> WARN 001 Before using BCCSP, please call InitFactories(). Falling back to bootBCCSP.
#
# You can ignore the logs regarding intermediate certs, we are not using them in
# this crypto implementation.

# Generate orderer system channel genesis block.
function createConsortium() {
  which configtxgen
  if [ "$?" -ne 0 ]; then
    fatalln "configtxgen tool not found."
  fi

  infoln "Generating Orderer Genesis block"

  # Note: For some unknown reason (at least for now) the block file can't be
  # named orderer.genesis.block or the orderer will fail to launch!
  set -x
  configtxgen -profile TwoOrgsOrdererGenesis -channelID system-channel -outputBlock $LOCAL_GENESIS_BLK
  res=$?
  { set +x; } 2>/dev/null
  if [ $res -ne 0 ]; then
    fatalln "Failed to generate orderer genesis block..."
  fi
}

# After we create the org crypto material and the system channel genesis block,
# we can now bring up the peers and ordering service. By default, the base
# file for creating the network is "docker-compose-test-net.yaml" in the ``docker``
# folder. This file defines the environment variables and file mounts that
# point the crypto material and genesis block that were created in earlier.

# Clean up the transferred files
function cleanGcp() {
  infoln "Clean up transferred files, and persistant data in gcp. "
  local orderer_count=${#ORDERER_INSTANCES[@]}
  for i in $(seq 0 $((orderer_count-1)))
  do
      local orderer_instance=${ORDERER_INSTANCES[$i]}
      local orderer_zone=${ORDERER_ZONES[$i]}
      local orderer_dns_name=${ORDERER_DNS_NAMES[$i]}
      # Based on https://stackoverflow.com/questions/7114990/pseudo-terminal-will-not-be-allocated-because-stdin-is-not-a-terminal, 
      # '--ssh-flag="-t"' option is to suppress the annoying essage 'Pseudo-terminal will not be allocated because stdin is not a terminal.'
      gcloud compute ssh --ssh-flag="-t" --zone ${orderer_zone} ${orderer_instance}  --quiet -- "rm -rf ${REMOTE_ORDERER_DIR}" &
  done

  for i in $(seq 0 $((PEER_COUNT-1)))
  do
      local peer_instance=${PEER_INSTANCES[$i]}
      local peer_zone=${PEER_ZONES[$i]}
      local peer_dns_name=${PEER_DNS_NAMES[$i]}
      local org_dns_name=${ORG_DNS_NAMES[$i]}
      gcloud compute ssh --ssh-flag="-t" --zone  ${peer_zone} ${peer_instance} --quiet -- "rm -rf ${REMOTE_PEER_DIR} " &
  done

  infoln "Wait for file removal to complete..."
  wait
}

function line2space() {
  echo "$1" | tr '\n' ' '
}

# Bring up the peer and orderer nodes using docker compose.
function networkUp() {
  # if [ ! -d "organizations/peerOrganizations" ]; then
  createOrgs
  createConsortium
  # fi

  cleanGcp
  infoln "Transfer files to intances."
  local orderer_count=${#ORDERER_INSTANCES[@]}
  for i in $(seq 0 $((orderer_count-1)))
  do
      local orderer_instance=${ORDERER_INSTANCES[$i]}
      local orderer_zone=${ORDERER_ZONES[$i]}
      local orderer_dns_name=${ORDERER_DNS_NAMES[$i]}

      gcloud compute ssh --ssh-flag="-t" --zone ${orderer_zone} ${orderer_instance} --quiet -- "mkdir -p ${REMOTE_ORDERER_DIR} ${REMOTE_ORDERER_DATA_DIR} ${REMOTE_ORDERER_CONSENSUS_WAL_DIR} ${REMOTE_ORDERER_CONSENSUS_SNAP_DIR}"

      gcloud compute scp --scp-flag=-q  --recurse ${LOCAL_GENESIS_BLK} ${orderer_instance}:${REMOTE_GENESIS_BLK}  --zone=${orderer_zone} --quiet &

      local local_msp_dir="organizations/ordererOrganizations/example.com/orderers/${orderer_dns_name}/msp"
      gcloud compute scp --scp-flag=-q  --recurse ${local_msp_dir} ${orderer_instance}:${REMOTE_ORDERER_MSP_DIR} --zone=${orderer_zone} --quiet &

      local local_tls_dir="organizations/ordererOrganizations/example.com/orderers/${orderer_dns_name}/tls"
      gcloud compute scp --scp-flag=-q  --recurse --zone=${orderer_zone} ${local_tls_dir} ${orderer_instance}:${REMOTE_ORDERER_TLS_DIR} --zone=${orderer_zone} --quiet &
  done

  for i in $(seq 0 $((PEER_COUNT-1)))
  do
      local peer_instance=${PEER_INSTANCES[$i]}
      local peer_zone=${PEER_ZONES[$i]}
      local peer_dns_name=${PEER_DNS_NAMES[$i]}
      local org_dns_name=${ORG_DNS_NAMES[$i]}
      gcloud compute ssh --ssh-flag="-t" --zone ${peer_zone} ${peer_instance} --quiet -- "mkdir -p ${REMOTE_PEER_DIR} ${REMOTE_PEER_DATA_DIR}"

      local local_msp_dir="organizations/peerOrganizations/${org_dns_name}/peers/${peer_dns_name}/msp"
      gcloud compute scp --scp-flag=-q  --recurse ${local_msp_dir} ${peer_instance}:${REMOTE_PEER_MSP_DIR} --zone=${peer_zone} --quiet &

      local local_tls_dir="organizations/peerOrganizations/${org_dns_name}/peers/${peer_dns_name}/tls"
      gcloud compute scp --scp-flag=-q  --recurse ${local_tls_dir} ${peer_instance}:${REMOTE_PEER_TLS_DIR} --zone=${peer_zone} --quiet &

  done

  infoln "Wait for file transfers to complete"
  wait

  # Run commands to launch fabric processes in gcp
  local orderer_count=${#ORDERER_INSTANCES[@]}
  for i in $(seq 0 $((orderer_count-1)))
  do
      local orderer_instance=${ORDERER_INSTANCES[$i]}
      local orderer_zone=${ORDERER_ZONES[$i]}
      local orderer_dns_name=${ORDERER_DNS_NAMES[$i]}

      # See my posted question on why using tr -d '\r': https://stackoverflow.com/questions/70986450/later-chars-displaces-previous-chars-in-string-concat-and-output
      local instance_home_dir=$(gcloud compute ssh  ${orderer_instance} --zone ${orderer_zone}  -- 'echo ${HOME}' | tr -d '\r') # use single quote to avoid var substitution locally. 

      # File paths in parameters must be in the absolute form, except $FABRIC_CFG_PATH
      # Otherwise, in the relative form, orderer assumes they are relative to $FABRIC_CFG_PATH
      local cmd="
        FABRIC_CFG_PATH=${REMOTE_FABRIC_CFG_PATH}
        FABRIC_LOGGING_SPEC=INFO
        ORDERER_GENERAL_LISTENADDRESS=0.0.0.0
        ORDERER_GENERAL_LISTENPORT=7050
        ORDERER_GENERAL_GENESISMETHOD=file
        ORDERER_GENERAL_GENESISFILE=${instance_home_dir}/${REMOTE_GENESIS_BLK}
        ORDERER_GENERAL_LOCALMSPID=OrdererMSP
        ORDERER_GENERAL_LOCALMSPDIR=${instance_home_dir}/${REMOTE_ORDERER_MSP_DIR}
        ORDERER_OPERATIONS_LISTENADDRESS=0.0.0.0:17050
        ORDERER_GENERAL_TLS_ENABLED=true
        ORDERER_GENERAL_TLS_PRIVATEKEY=${instance_home_dir}/${REMOTE_ORDERER_TLS_DIR}/server.key
        ORDERER_GENERAL_TLS_CERTIFICATE=${instance_home_dir}/${REMOTE_ORDERER_TLS_DIR}/server.crt
        ORDERER_GENERAL_TLS_ROOTCAS=[${instance_home_dir}/${REMOTE_ORDERER_TLS_DIR}/ca.crt]
        ORDERER_GENERAL_CLUSTER_CLIENTCERTIFICATE=${instance_home_dir}/${REMOTE_ORDERER_TLS_DIR}/server.crt
        ORDERER_GENERAL_CLUSTER_CLIENTPRIVATEKEY=${instance_home_dir}/${REMOTE_ORDERER_TLS_DIR}/server.key
        ORDERER_GENERAL_CLUSTER_ROOTCAS=[${instance_home_dir}/${REMOTE_ORDERER_TLS_DIR}/ca.crt]
        ORDERER_FILELEDGER_LOCATION=${instance_home_dir}/${REMOTE_ORDERER_DATA_DIR}
        ORDERER_CONSENSUS_WALDIR=${instance_home_dir}/${REMOTE_ORDERER_CONSENSUS_WAL_DIR}
        ORDERER_CONSENSUS_SNAPDIR=${instance_home_dir}/${REMOTE_ORDERER_CONSENSUS_SNAP_DIR}
        ${REMOTE_ORDERER_EXEC} > ${REMOTE_ORDERER_LOG} 2>&1 
        "
      infoln "Launch orderer process at instance ${orderer_instance} with cmd: "
      infoln "${cmd}"
      # replace line breaks in cmd with spaces
      gcloud compute ssh --ssh-flag="-t" --zone ${orderer_zone} ${orderer_instance} -- "$(echo "$cmd" | tr '\n' ' ')" &
  done


  for i in $(seq 0 $((PEER_COUNT-1)))
  do

      local peer_instance=${PEER_INSTANCES[$i]}
      local peer_zone=${PEER_ZONES[$i]}
      local peer_dns_name=${PEER_DNS_NAMES[$i]}
      local org_dns_name=${ORG_DNS_NAMES[$i]}
      local org_msg=${ORG_MSPS[$i]}

      local instance_home_dir=$(gcloud compute ssh  ${peer_instance} --zone ${peer_zone}  -- 'echo ${HOME}' | tr -d '\r') # use single quote to avoid var substitution locally. 

      local cmd="
        FABRIC_CFG_PATH=${REMOTE_FABRIC_CFG_PATH}
        FABRIC_LOGGING_SPEC=INFO
        CORE_PEER_TLS_ENABLED=true
        CORE_PEER_TLS_CERT_FILE=${instance_home_dir}/${REMOTE_PEER_TLS_DIR}/server.crt
        CORE_PEER_TLS_KEY_FILE=${instance_home_dir}/${REMOTE_PEER_TLS_DIR}/server.key
        CORE_PEER_TLS_ROOTCERT_FILE=${instance_home_dir}/${REMOTE_PEER_TLS_DIR}/ca.crt
        CORE_PEER_TLS_CLIENTAUTHREQUIRED=false
        CORE_PEER_ID=${peer_dns_name}
        CORE_PEER_ADDRESS=${peer_dns_name}:7051
        CORE_PEER_LISTENADDRESS=0.0.0.0:7051
        CORE_PEER_CHAINCODEADDRESS=${peer_dns_name}:7052
        CORE_PEER_CHAINCODELISTENADDRESS=0.0.0.0:7052
        CORE_PEER_GOSSIP_BOOTSTRAP=${peer_dns_name}:7051
        CORE_PEER_GOSSIP_EXTERNALENDPOINT=${peer_dns_name}:7051
        CORE_PEER_LOCALMSPID=${org_msg}
        CORE_OPERATIONS_LISTENADDRESS=0.0.0.0:17051
        CORE_PEER_MSPCONFIGPATH=${instance_home_dir}/${REMOTE_PEER_MSP_DIR}
        CORE_PEER_FILESYSTEMPATH=${instance_home_dir}/${REMOTE_PEER_DATA_DIR}
        ${REMOTE_PEER_EXEC} node start > ${REMOTE_PEER_LOG} 2>&1
      "
      infoln "Launch peer process at instance ${peer_instance} with cmd: "
      infoln "${cmd}"
      # replace line breaks in cmd with spaces
      gcloud compute ssh  --zone ${peer_zone} ${peer_instance} -- "$(echo "$cmd" | tr '\n' ' ')" &
  done
}


# Tear down running network
function networkDown() {
  # Run commands to shut fabric processes in gcp
  local orderer_count=${#ORDERER_INSTANCES[@]}
  for i in $(seq 0 $((orderer_count-1)))
  do
      local orderer_instance=${ORDERER_INSTANCES[$i]}
      local orderer_zone=${ORDERER_ZONES[$i]}
      local cmd='kill -9 $(pgrep -f orderer) > /dev/null 2>&1'
      infoln "Kill orderer process at instance ${orderer_instance}"

      gcloud compute ssh --ssh-flag="-t" --zone ${orderer_zone} ${orderer_instance} -- "${cmd}" > /dev/null 2>&1 &
  done

  for i in $(seq 0 $((PEER_COUNT-1)))
  do
      local peer_instance=${PEER_INSTANCES[$i]}
      local peer_zone=${PEER_ZONES[$i]}
      local cmd='kill -9 $(pgrep -f peer) '
      infoln "Kill peer process at instance ${peer_instance}: "

      gcloud compute ssh --ssh-flag="-t" --zone ${peer_zone} ${peer_instance} -- "${cmd}" > /dev/null 2>&1 &
  done
  infoln "Wait to kill all processes..."
  wait

  cleanGcp
}

# call the script to create the channel, join the peers of org1 and org2,
# and then update the anchor peers for each organization
function createChannel() {
  # Bring up the network if it is not already up.

  if [ ! -d "organizations/peerOrganizations" ]; then
    infoln "Bringing up network"
    networkUp
  fi

  # now run the script that creates a channel. This script uses configtxgen once
  # more to create the channel creation transaction and the anchor peer updates.
  # configtx.yaml is mounted in the cli container, which allows us to use it to
  # create the channel artifacts
  scripts/createChannel.sh $CHANNEL_NAME $CLI_DELAY $MAX_RETRY $VERBOSE
}


## Call the script to deploy a chaincode to the channel
function deployCC() {
  scripts/deployCC.sh $CHANNEL_NAME $CC_NAME $CC_SRC_PATH $CC_SRC_LANGUAGE $CC_VERSION $CC_SEQUENCE $CC_INIT_FCN $CC_END_POLICY $CC_COLL_CONFIG $CLI_DELAY $MAX_RETRY $VERBOSE

  if [ $? -ne 0 ]; then
    fatalln "Deploying chaincode failed"
  fi
}


# Obtain the OS and Architecture string that will be used to select the correct
# native binaries for your platform, e.g., darwin-amd64 or linux-amd64
OS_ARCH=$(echo "$(uname -s | tr '[:upper:]' '[:lower:]' | sed 's/mingw64_nt.*/windows/')-$(uname -m | sed 's/x86_64/amd64/g')" | awk '{print tolower($0)}')
# Using crpto vs CA. default is cryptogen
CRYPTO="cryptogen"
# timeout duration - the duration the CLI should wait for a response from
# another container before giving up
MAX_RETRY=2
# default for delay between commands
CLI_DELAY=3
# channel name defaults to "mychannel"
CHANNEL_NAME="mychannel"
# chaincode name defaults to "NA"
CC_NAME="NA"
# chaincode path defaults to "NA"
CC_SRC_PATH="NA"
# endorsement policy defaults to "NA". This would allow chaincodes to use the majority default policy.
CC_END_POLICY="NA"
# collection configuration defaults to "NA"
CC_COLL_CONFIG="NA"
# chaincode init function defaults to "NA"
CC_INIT_FCN="NA"
# use this as the default docker-compose yaml definition
COMPOSE_FILE_BASE=docker/docker-compose-test-net.yaml
# docker-compose.yaml file if you are using couchdb
COMPOSE_FILE_COUCH=docker/docker-compose-couch.yaml
# certificate authorities compose file
COMPOSE_FILE_CA=docker/docker-compose-ca.yaml
# use this as the docker compose couch file for org3
COMPOSE_FILE_COUCH_ORG3=addOrg3/docker/docker-compose-couch-org3.yaml
# use this as the default docker-compose yaml definition for org3
COMPOSE_FILE_ORG3=addOrg3/docker/docker-compose-org3.yaml
#
# chaincode language defaults to "NA"
CC_SRC_LANGUAGE="NA"
# Chaincode version
CC_VERSION="1.0"
# Chaincode definition sequence
CC_SEQUENCE=1
# default image tag
IMAGETAG="latest"
# default ca image tag
CA_IMAGETAG="latest"
# default database
DATABASE="leveldb"

# Parse commandline args

## Parse mode
if [[ $# -lt 1 ]] ; then
  printHelp
  exit 0
else
  MODE=$1
  shift
fi

# parse a createChannel subcommand if used
if [[ $# -ge 1 ]] ; then
  key="$1"
  if [[ "$key" == "createChannel" ]]; then
      export MODE="createChannel"
      shift
  fi
fi

# parse flags

while [[ $# -ge 1 ]] ; do
  key="$1"
  case $key in
  -h )
    printHelp $MODE
    exit 0
    ;;
  -c )
    CHANNEL_NAME="$2"
    shift
    ;;
  -ca )
    CRYPTO="Certificate Authorities"
    ;;
  -r )
    MAX_RETRY="$2"
    shift
    ;;
  -d )
    CLI_DELAY="$2"
    shift
    ;;
  -s )
    DATABASE="$2"
    shift
    ;;
  -ccl )
    CC_SRC_LANGUAGE="$2"
    shift
    ;;
  -ccn )
    CC_NAME="$2"
    shift
    ;;
  -ccv )
    CC_VERSION="$2"
    shift
    ;;
  -ccs )
    CC_SEQUENCE="$2"
    shift
    ;;
  -ccp )
    CC_SRC_PATH="$2"
    shift
    ;;
  -ccep )
    CC_END_POLICY="$2"
    shift
    ;;
  -cccg )
    CC_COLL_CONFIG="$2"
    shift
    ;;
  -cci )
    CC_INIT_FCN="$2"
    shift
    ;;
  -i )
    IMAGETAG="$2"
    shift
    ;;
  -cai )
    CA_IMAGETAG="$2"
    shift
    ;;
  -verbose )
    VERBOSE=true
    shift
    ;;
  * )
    errorln "Unknown flag: $key"
    printHelp
    exit 1
    ;;
  esac
  shift
done

# Are we generating crypto material with this command?
if [ ! -d "organizations/peerOrganizations" ]; then
  CRYPTO_MODE="with crypto from '${CRYPTO}'"
else
  CRYPTO_MODE=""
fi

# Determine mode of operation and printing out what we asked for
if [ "$MODE" == "up" ]; then
  infoln "Starting nodes with CLI timeout of '${MAX_RETRY}' tries and CLI delay of '${CLI_DELAY}' seconds and using database '${DATABASE}' ${CRYPTO_MODE}"
elif [ "$MODE" == "createChannel" ]; then
  infoln "Creating channel '${CHANNEL_NAME}'."
  infoln "If network is not up, starting nodes with CLI timeout of '${MAX_RETRY}' tries and CLI delay of '${CLI_DELAY}' seconds and using database '${DATABASE} ${CRYPTO_MODE}"
elif [ "$MODE" == "down" ]; then
  infoln "Stopping network"
elif [ "$MODE" == "restart" ]; then
  infoln "Restarting network"
elif [ "$MODE" == "deployCC" ]; then
  infoln "deploying chaincode on channel '${CHANNEL_NAME}'"
else
  printHelp
  exit 1
fi

if [ "${MODE}" == "up" ]; then
  networkUp
elif [ "${MODE}" == "createChannel" ]; then
  createChannel
elif [ "${MODE}" == "deployCC" ]; then
  deployCC
elif [ "${MODE}" == "down" ]; then
  networkDown
else
  printHelp
  exit 1
fi
