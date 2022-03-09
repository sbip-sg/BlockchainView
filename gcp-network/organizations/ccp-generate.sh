#!/bin/bash

function one_line_pem {
    echo "`awk 'NF {sub(/\\n/, ""); printf "%s\\\\\\\n",$0;}' $1`"
}

function json_ccp {
    local PP=$(one_line_pem $5)
    sed -e "s/\${ORG}/$1/" \
        -e "s#\${ORG_MSP}#$2#" \
        -e "s#\${PEER_DOMAIN}#$3#" \
        -e "s#\${ORG_DOMAIN}#$4#" \
        -e "s#\${PEER_PEM}#$PP#" \
        organizations/ccp-template.json
}


. env.sh
if [ -z "${PEER_COUNT}" ]; then
  fatalln '$PEER_COUNT not set. exiting the program...'
fi

for i in $(seq 0 $((PEER_COUNT-1)))
do
    org=$((i+1))
    org_msp="${ORG_MSPS[$i]}"
    peer_domain="${PEER_DNS_NAMES[$i]}"
    org_domain="${ORG_DNS_NAMES[$i]}"
    peer_pem_path="organizations/peerOrganizations/${org_domain}/tlsca/tlsca.${org_domain}-cert.pem"
    # ca_pem_path="organizations/peerOrganizations/${org_domain}/ca/ca.${org_domain}-cert.pem"
    echo "$(json_ccp ${org} ${org_msp} ${peer_domain} ${org_domain} ${peer_pem_path})" > organizations/peerOrganizations/${org_domain}/connection-org${org}.json
done

