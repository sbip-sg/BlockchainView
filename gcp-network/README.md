# One-time Init
USE WITH CARE!!!
```
./gcp.sh network_new

. ./env.sh
gcloud beta compute instances create fabriccli \
	--zone=asia-southeast1-a \
	--machine-type=${MACHINE_TYPE} \
	--network=${GCP_NETWORK} \
	--source-machine-image=${FABRIC_ENV_IMAGE} \
	--quiet

# Config fabriccli with deps
- ssh key generation
- `gcloud auth login`
- add ssh key to github
- download this repo
- install golang
- download fabric binaries and dockers
- `sudo apt-get install build-essential`
- download node and npm
```

# Before: Per-experimental-set
```

gcloud compute instances start fabriccli --zone=asia-southeast1-a
gcloud compute ssh fabriccli --zone=asia-southeast1-a

# in fabriccli
./gcp.sh instance_up
```

# Before: Per-experiment
```
./network.sh up

CHANNEL_NAME="viewchannel"
./network.sh createChannel -c ${CHANNEL_NAME}


PEER_COUNT=2

CC_NAME="secretcontract" # To work with view_demo
CC_NAME="noop" # To work with front_demo

ALL_ORG=""
for i in $(seq ${PEER_COUNT})
do
   ALL_ORG="$ALL_ORG 'Org${i}MSP.peer'"
done

function join_by { local d=$1; shift; local f=$1; shift; printf %s "$f" "${@/#/$d}"; }

ENDORSE_POLICY="OR($(join_by , $ALL_ORG))" # Result into "OR(Org1MSP.peer,Org2MSP.peer)"

./network.sh deployCC -c ${CHANNEL_NAME} -ccl go -ccn ${CC_NAME} -ccp ../chaincodes/${CC_NAME} -ccep ${ENDORSE_POLICY} -cccg ../chaincodes/${CC_NAME}/collection_config.json

```


# End: Per-experimental-set
gcloud compute instances stop fabriccli

```
# in fabriccli
./gcp.sh instance_down

gcloud compute instances stop fabriccli

```


# One-time Delete
USE WITH CARE!!!
Unless you are sure that you will not run the experiments later. 
```
gcloud compute instances delete fabriccli
./gcp.sh network_delete
```
