#!/bin/bash

# imports  
. scripts/envVar.sh
. scripts/utils.sh

CHANNEL_NAME="$1"
DELAY="$2"
MAX_RETRY="$3"
VERBOSE="$4"
: ${CHANNEL_NAME:="mychannel"}
: ${DELAY:="3"}
: ${MAX_RETRY:="1"}
: ${VERBOSE:="false"}

if [ ! -d "channel-artifacts" ]; then
	mkdir channel-artifacts
fi

createChannelTx() {
	set -x
	configtxgen -profile TwoOrgsChannel -outputCreateChannelTx ./channel-artifacts/${CHANNEL_NAME}.tx -channelID $CHANNEL_NAME
	res=$?
	{ set +x; } 2>/dev/null
	verifyResult $res "Failed to generate channel configuration transaction..."
}

createAnchorTx() {
	setPeerGlobals $1
	configtxgen -profile TwoOrgsChannel -outputAnchorPeersUpdate ./channel-artifacts/${CORE_PEER_LOCALMSPID}_anchors.tx -channelID $CHANNEL_NAME -asOrg ${CORE_PEER_LOCALMSPID}
}


createChannel() {
	setPeerGlobals 1
	setOrdererGlobals 1
	# Poll in case the raft leader is not set yet
	local rc=1
	local COUNTER=1
	while [ $rc -ne 0 -a $COUNTER -lt $MAX_RETRY ] ; do
		sleep $DELAY
		set -x
		peer channel create -o ${ORDERER_ADDR} -c ${CHANNEL_NAME} --ordererTLSHostnameOverride ${ORDERER_DOMAIN} -f ./channel-artifacts/${CHANNEL_NAME}.tx --outputBlock $BLOCKFILE --tls --cafile ${ORDERER_CA} >&log.txt
		res=$?
		{ set +x; } 2>/dev/null
		let rc=$res
		COUNTER=$(expr $COUNTER + 1)
	done
	cat log.txt
	verifyResult $res "Channel creation failed"
}

# joinChannel ORG
joinChannel() {
	FABRIC_CFG_PATH=$PWD/../config/
	ORG=$1
	setPeerGlobals ${ORG}
	local rc=1
	local COUNTER=1
	## Sometimes Join takes time, hence retry
	while [ $rc -ne 0 -a $COUNTER -lt $MAX_RETRY ] ; do
		sleep $DELAY
		set -x
		peer channel join -b $BLOCKFILE >&log.txt
		res=$?
		{ set +x; } 2>/dev/null
		let rc=$res
		COUNTER=$(expr $COUNTER + 1)
	done
	cat log.txt
	verifyResult $res "After $MAX_RETRY attempts, peer0.org${ORG} has failed to join channel '$CHANNEL_NAME' "
}

setAnchorPeer() {
	ORG=$1
	setPeerGlobals $ORG
	setOrdererGlobals 1
	
	local rc=1
	local COUNTER=1
	## Sometimes Join takes time, hence retry
	while [ $rc -ne 0 -a $COUNTER -lt $MAX_RETRY ] ; do
		sleep $DELAY
		set -x
		peer channel update -o ${ORDERER_ADDR} -c $CHANNEL_NAME --ordererTLSHostnameOverride ${ORDERER_DOMAIN} -f ./channel-artifacts/${CORE_PEER_LOCALMSPID}_anchors.tx --tls --cafile $ORDERER_CA >&log.txt
		res=$?
		set +x
		let rc=$res
		COUNTER=$(expr $COUNTER + 1)
	done
	cat log.txt
	verifyResult $res "Anchor peer update failed"
	echo "===================== Anchor peers updated for org '$CORE_PEER_LOCALMSPID' on channel '$CHANNEL_NAME' ===================== "
	sleep $DELAY
	echo
}

export FABRIC_CFG_PATH=${PWD}/configtx${PEER_COUNT}

if [ -z "${PEER_COUNT}" ]; then
  fatalln '$PEER_COUNT not set. exiting the program...'
fi


## Create channeltx
infoln "Generating channel create transaction '${CHANNEL_NAME}.tx'"
createChannelTx

for i in $(seq $((PEER_COUNT)))
do
	infoln "Generating AnchorTx for each Org{$i}"
	createAnchorTx $i
done


FABRIC_CFG_PATH=$PWD/../config/
BLOCKFILE="./channel-artifacts/${CHANNEL_NAME}.block"

## Create channel
infoln "Creating channel ${CHANNEL_NAME}"
createChannel
successln "Channel '$CHANNEL_NAME' created"

# Join all the peers to the channel
for i in $(seq $((PEER_COUNT)))
do
	infoln "Joining org${i} peer to the channel..."
	joinChannel ${i}
done
successln "Channel '$CHANNEL_NAME' joined"

## Set the anchor peers for each org in the channel
for i in $(seq $((PEER_COUNT)))
do
	infoln "Setting anchor peer for org${i}..."
	setAnchorPeer ${i}
done

successln "Anchor Peer updated..."