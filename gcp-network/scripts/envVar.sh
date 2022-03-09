#!/bin/bash
#
# Copyright IBM Corp All Rights Reserved
#
# SPDX-License-Identifier: Apache-2.0
#

# This is a collection of bash functions used by different scripts

# imports
. scripts/utils.sh
. env.sh

export CORE_PEER_TLS_ENABLED=true

function setPeerGlobals() {
  local org_id=$1
  echo "Using organization ${org_id}"
  export CORE_PEER_LOCALMSPID="Org${org_id}MSP"

  local org_domain="${ORG_DNS_NAMES[$((org_id-1))]}"
  # local org_peer_ip="$(sed -n ${org_id}p ${PEER_EXTERNAL_IP_PATH})" # idx starts from 1 in sed. 
  local peer_domain="${PEER_DNS_NAMES[$((org_id-1))]}"

  export ORG_PEER_DOMAIN="${PEER_DNS_NAMES[$((org_id-1))]}"
  export CORE_PEER_MSPCONFIGPATH=${PWD}/organizations/peerOrganizations/${org_domain}/users/Admin@${org_domain}/msp
  export CORE_PEER_ADDRESS=${peer_domain}:7051
  export CORE_PEER_TLS_ROOTCERT_FILE=${PWD}/organizations/peerOrganizations/${org_domain}/peers/${ORG_PEER_DOMAIN}/tls/ca.crt

  # echo "CORE_PEER_LOCALMSPID: ${CORE_PEER_LOCALMSPID}"
  # echo "CORE_PEER_MSPCONFIGPATH: ${CORE_PEER_MSPCONFIGPATH}"
  # echo "CORE_PEER_ADDRESS: ${CORE_PEER_ADDRESS}"
  # echo "CORE_PEER_TLS_ROOTCERT_FILE: ${CORE_PEER_TLS_ROOTCERT_FILE}"
}

setOrdererGlobals() {
  local orderer_id=$1
  echo "Using orderer ${orderer_id}"

  export ORDERER_DOMAIN=${ORDERER_DNS_NAMES[$((orderer_id-1))]}

	export ORDERER_CA=${PWD}/organizations/ordererOrganizations/${DNS_SUFFIX}/orderers/${ORDERER_DOMAIN}/msp/tlscacerts/tlsca.${DNS_SUFFIX}-cert.pem
  export ORDERER_ADDR=${ORDERER_DOMAIN}:7050

  # echo "ORDERER_CA : ${ORDERER_CA}"
  # echo "ORDERER_ADDR : ${ORDERER_ADDR}"
}




# export ORDERER_CA=${PWD}/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem
# export PEER0_ORG1_CA=${PWD}/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt
# export PEER0_ORG2_CA=${PWD}/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt
# export PEER0_ORG3_CA=${PWD}/organizations/peerOrganizations/org3.example.com/peers/peer0.org3.example.com/tls/ca.crt

# # Set environment variables for the peer org
# setGlobals() {
#   local USING_ORG=""
#   if [ -z "$OVERRIDE_ORG" ]; then
#     USING_ORG=$1
#   else
#     USING_ORG="${OVERRIDE_ORG}"
#   fi
#   infoln "Using organization ${USING_ORG}"
#   if [ $USING_ORG -eq 1 ]; then
#     export CORE_PEER_LOCALMSPID="Org1MSP"
#     export CORE_PEER_TLS_ROOTCERT_FILE=$PEER0_ORG1_CA
#     export CORE_PEER_MSPCONFIGPATH=${PWD}/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp
#     export CORE_PEER_ADDRESS=localhost:7051
#   elif [ $USING_ORG -eq 2 ]; then
#     export CORE_PEER_LOCALMSPID="Org2MSP"
#     export CORE_PEER_TLS_ROOTCERT_FILE=$PEER0_ORG2_CA
#     export CORE_PEER_MSPCONFIGPATH=${PWD}/organizations/peerOrganizations/org2.example.com/users/Admin@org2.example.com/msp
#     export CORE_PEER_ADDRESS=localhost:9051

#   elif [ $USING_ORG -eq 3 ]; then
#     export CORE_PEER_LOCALMSPID="Org3MSP"
#     export CORE_PEER_TLS_ROOTCERT_FILE=$PEER0_ORG3_CA
#     export CORE_PEER_MSPCONFIGPATH=${PWD}/organizations/peerOrganizations/org3.example.com/users/Admin@org3.example.com/msp
#     export CORE_PEER_ADDRESS=localhost:11051
#   else
#     errorln "ORG Unknown"
#   fi

#   if [ "$VERBOSE" == "true" ]; then
#     env | grep CORE
#   fi
# }

# # Set environment variables for use in the CLI container 
# setGlobalsCLI() {
#   setGlobals $1

#   local USING_ORG=""
#   if [ -z "$OVERRIDE_ORG" ]; then
#     USING_ORG=$1
#   else
#     USING_ORG="${OVERRIDE_ORG}"
#   fi
#   if [ $USING_ORG -eq 1 ]; then
#     export CORE_PEER_ADDRESS=peer0.org1.example.com:7051
#   elif [ $USING_ORG -eq 2 ]; then
#     export CORE_PEER_ADDRESS=peer0.org2.example.com:9051
#   elif [ $USING_ORG -eq 3 ]; then
#     export CORE_PEER_ADDRESS=peer0.org3.example.com:11051
#   else
#     errorln "ORG Unknown"
#   fi
# }

# parsePeerConnectionParameters $@
# Helper function that sets the peer connection parameters for a chaincode
# operation
parsePeerConnectionParameters() {
  export PEER_CONN_PARMS=""
  export PEERS=""
  while [ "$#" -gt 0 ]; do
    setPeerGlobals $1
    PEER="peer0.org$1"
    ## Set peer adresses
    PEERS="$PEERS $PEER"
    PEER_CONN_PARMS="$PEER_CONN_PARMS --peerAddresses $CORE_PEER_ADDRESS"
    ## Set path to TLS certificate
    PEER_CONN_PARMS="$PEER_CONN_PARMS --tlsRootCertFiles  $CORE_PEER_TLS_ROOTCERT_FILE"
    # shift by one to get to the next organization
    shift
  done
  # remove leading space for output
  PEERS="$(echo -e "$PEERS" | sed -e 's/^[[:space:]]*//')"
}

verifyResult() {
  if [ $1 -ne 0 ]; then
    fatalln "$2"
  fi
}
