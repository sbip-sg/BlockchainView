'use strict';

const path = require('path');

const FabricFront = require("../app/fabricfront").FabricFront;

const EncryptionBasedViewMgr = require("../app/encryption_based_view_mgr").EncryptionBasedViewMgr;
const HashBasedViewMgr = require("../app/hash_based_view_mgr").HashBasedViewMgr;
const global = require('../app/global.js');

const LOGGER = require('loglevel');
//more docs here - https://github.com/pimterry/loglevel#documentation
LOGGER.setDefaultLevel('info');

const VIEW_MODE = global.ViewInContractMode;
const WORKLOAD_CHAINCODEID = "onchainview";
const WL_FUNC_NAME = "InvokeTxn"; // consistent to onchainview 

const ORG_DIR = process.argv[2];
const DATA_HIDING_SCHEME = process.argv[3]; // encryption/hash
const CHANNEL_NAME = process.argv[4];

const VIEW_COUNT = parseInt(process.argv[5]);
const TXN_COUNT = parseInt(process.argv[6]);
const BATCH_SIZE = parseInt(process.argv[7]);
const BATCH_COUNT = TXN_COUNT / BATCH_SIZE;
const SELECTIVITY = process.argv[8]; // single / all

LOGGER.info("Parameters: ")
LOGGER.info(`\t ORG_DIR : ${ORG_DIR}`);
LOGGER.info(`\t DATA_HIDING_SCHEME : ${DATA_HIDING_SCHEME}`);
LOGGER.info(`\t VIEW_MODE : ${VIEW_MODE}`);
LOGGER.info(`\t CHANNEL_NAME : ${CHANNEL_NAME}`);
LOGGER.info(`\t WORKLOAD_CHAINCODEID : ${WORKLOAD_CHAINCODEID}`);
LOGGER.info(`\t VIEW_COUNT : ${VIEW_COUNT}`);
LOGGER.info(`\t TXN_COUNT : ${TXN_COUNT}`);
LOGGER.info(`\t BATCH_SIZE : ${BATCH_SIZE}`);
LOGGER.info(`\t BATCH_COUNT : ${BATCH_COUNT}`);
LOGGER.info(`\t SELECTIVITY : ${SELECTIVITY}`);
LOGGER.info(`=============================================`);

var VIEW_MGR;
var EXEC_START;
var TOTAL_REQ_COUNT = 0;
var BATCH_EXEC_DELAY = 0;
var COMMITTED_TXN_COUNT = 0;
var ALL_VIEWS = [];

const CONFIDENTIAL_DATA = "SECRET_PAYLOAD";
const SELECTIVITY_ALL = "all";
const SELECTIVITY_SINGLE = "single";

function build_pub_arg(selectivity) {
    if (selectivity === SELECTIVITY_ALL) {
        // As hardcoded in contract onchainview, 'ALL' pub arg implies this txn satisifies all views. 
        return "ALL"; 
    } else if (selectivity === SELECTIVITY_SINGLE) {
        var vid = Math.floor(Math.random() * ALL_VIEWS.length);
        return ALL_VIEWS[vid];
    } else {
        LOGGER.error(`Unrecognized Selectivity ${selectivity}`);
        process.exit(1);
    }
}

/////////////////////////////////////////////////////////////
Promise.resolve().then(()=>{
    var fabric_front;
    var peer_count = 1;
    if (process.env.PEER_COUNT) {
        peer_count = parseInt(process.env.PEER_COUNT);
    } else {
        LOGGER.error("Not setting global env var PEER_COUNT");
        process.exit(1);
    }
    
    var org_id = 1 + parseInt(process.pid) % peer_count;
    LOGGER.info(`Using ORG ${org_id}: `);
    const profile_path = path.resolve(ORG_DIR, `org${org_id}.example.com`, `connection-org${org_id}.json`);
    const mspId = `Org${org_id}MSP`;
    const cert_path = path.resolve(ORG_DIR, `org${org_id}.example.com`, "users", `Admin@org${org_id}.example.com`, "msp", "signcerts", `Admin@org${org_id}.example.com-cert.pem`);
    const key_path = path.resolve(ORG_DIR, `org${org_id}.example.com`, "users", `Admin@org${org_id}.example.com`, "msp", "keystore", "priv_sk");
    fabric_front = new FabricFront(profile_path, CHANNEL_NAME, mspId, cert_path, key_path);
    return fabric_front.InitNetwork();

}).then((fabric_front)=>{

    if (DATA_HIDING_SCHEME == global.HashScheme) {
        VIEW_MGR = new HashBasedViewMgr(fabric_front, VIEW_MODE, WORKLOAD_CHAINCODEID);
    } else if (DATA_HIDING_SCHEME == global.EncryptionScheme) {
        VIEW_MGR = new EncryptionBasedViewMgr(fabric_front, VIEW_MODE, WORKLOAD_CHAINCODEID);
    } else {
        LOGGER.error(`Unrecognized/Unsupported Data Hiding Scheme ${DATA_HIDING_SCHEME}`);
        process.exit(1);
    }

    var view_creation_promises = [];

    LOGGER.info(`Create ${VIEW_COUNT} views. `);
    for (var i = 0; i < VIEW_COUNT; i++) {
        var view_name = "View"+i;
        // As hardcoded in onchainview, onchainview will match pub_arg with the view predicate to determine a transaction's validity on a view.  
        // Here, we pass on the view_name as the view predicate. 
        // Later, if SELECTIVITY is single, we will pass the name of a random view as a txns's pub_arg, in order to match the txn to that view. 
        var view_predicate = view_name;
        view_creation_promises.push(VIEW_MGR.CreateView(view_name, view_predicate));
        ALL_VIEWS.push(view_name);
    }

    return Promise.all(view_creation_promises);

}).then(()=>{

    EXEC_START = new Date();
    var batch_ids = [];
    LOGGER.info(`# of batches = ${BATCH_COUNT}`);
    for (var i = 0; i < BATCH_COUNT; i++) {
        batch_ids.push(i);
    }

    return batch_ids.reduce( async (previousPromise, batch_id) => {
        await previousPromise;
        LOGGER.info(`Prepare to batch request ${BATCH_SIZE} in batch ${batch_id}`);

        var batch_start = new Date();
        var request_promises = [];
        for (var i = 0; i < BATCH_SIZE; i++) {
            var pub_arg = build_pub_arg(SELECTIVITY);
            var req_promise = VIEW_MGR.InvokeTxn(WL_FUNC_NAME, pub_arg, CONFIDENTIAL_DATA, "useless_req_id");

            TOTAL_REQ_COUNT+=1;
            request_promises.push(req_promise);
        }
        await Promise.all(request_promises).then((txn_statuses)=>{

            for (var i in txn_statuses) {
                if (txn_statuses[i][0] != "") {
                } else {
                    COMMITTED_TXN_COUNT += 1;
                }
            }

            var batch_elapsed = new Date() - batch_start;
            BATCH_EXEC_DELAY += batch_elapsed;
        });

    },  Promise.resolve());
}).catch((err)=>{
    LOGGER.error("Invocation fails with err msg: " + err.stack);
})
.finally(()=>{
    let elapsed = new Date() - EXEC_START;
    let avg_batch_delay = Math.floor(BATCH_EXEC_DELAY / BATCH_COUNT);
    // LOGGER.info(`Committed Txn Count : ${committed_txn_count}, Rejected Txn Count: ${rejected_txn_count}`);
    LOGGER.info(`Total Duration (ms): ${elapsed} ,  # of app txn:  ${TOTAL_REQ_COUNT} , Committed Txn Count: ${COMMITTED_TXN_COUNT} , avg batch delay (ms): ${avg_batch_delay} # of batches ${BATCH_COUNT}`);
    process.exit(0)
})
;