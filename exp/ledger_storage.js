'use strict';

const path = require('path');

const LOGGER = require('loglevel');
//more docs here - https://github.com/pimterry/loglevel#documentation
LOGGER.setDefaultLevel('info');
const FabricFront = require("../app/fabricfront").FabricFront;
const LEDGER_SIZE_FIELD = require("../app/fabricfront").LEDGER_SIZE_FIELD;
const LEDGER_HEIGHT_FIELD = require("../app/fabricfront").LEDGER_HEIGHT_FIELD;

const ORG_DIR = process.argv[2];
const CHANNEL_NAME = process.argv[3];

LOGGER.info("Parameters: ")
LOGGER.info(`\t ORG_DIR : ${ORG_DIR}`);
LOGGER.info(`\t CHANNEL_NAME : ${CHANNEL_NAME}`);
LOGGER.info(`---------------------------------------------`);

Promise.resolve().then(()=>{
    var fabric_front;
    var org_id = 1;
    const profile_path = path.resolve(ORG_DIR, `org${org_id}.example.com`, `connection-org${org_id}.json`);
    const mspId = `Org${org_id}MSP`;
    const cert_path = path.resolve(ORG_DIR, `org${org_id}.example.com`, "users", `Admin@org${org_id}.example.com`, "msp", "signcerts", `Admin@org${org_id}.example.com-cert.pem`);
    const key_path = path.resolve(ORG_DIR, `org${org_id}.example.com`, "users", `Admin@org${org_id}.example.com`, "msp", "keystore", "priv_sk");


    fabric_front = new FabricFront(profile_path, CHANNEL_NAME, mspId, cert_path, key_path);
    return fabric_front.InitNetwork();
}).then((fabric_front)=>{
    return fabric_front.ScanLedgerForDelayStorage();
}).then((ledger_info) => {
    var ledger_size = ledger_info[LEDGER_SIZE_FIELD];
    var blk_count = ledger_info[LEDGER_HEIGHT_FIELD]
    LOGGER.info(`Ledger Size (Bytes): ${ledger_size}, Block Count: ${blk_count} `);
}).catch((err)=>{
    LOGGER.error("Invocation fails with err msg: " + err.stack);
}).finally(()=>{
    process.exit(0)
})
;




