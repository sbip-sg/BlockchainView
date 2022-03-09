'use strict';

const path = require('path');

const FabricFront = require("../app/fabricfront").FabricFront;
const QUERY_DELAY_FIELD = require("../app/fabricfront").QUERY_DELAY_FIELD;
const VERIFY_DELAY_FIELD = require("../app/fabricfront").VERIFY_DELAY_FIELD;
const LEDGER_HEIGHT_FIELD = require("../app/fabricfront").LEDGER_HEIGHT_FIELD;

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
const TXN_COUNT = parseInt(process.argv[5]);
const TXN_SCAN_BATCH_SIZE = parseInt(process.argv[6]);

var COMMITTED_TXN_COUNT = 0;
var VIEW_MGR;
var VIEW_NAME = "SingleView";
var FABRIC_FRONT;

var TXN_SCAN_START;
var TXN_SCAN_BATCH_COUNT;

var TXN_QUERY_MS = 0;
var TXN_VERIFY_MS = 0;

const TXN_LOAD_BATCH_SIZE = 50;
const CONFIDENTIAL_DATA = "SECRET_PAYLOAD";
var txn_scan_elapse = 0;

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
    FABRIC_FRONT = fabric_front;
    if (DATA_HIDING_SCHEME == global.HashScheme) {
        VIEW_MGR = new HashBasedViewMgr(fabric_front, VIEW_MODE, WORKLOAD_CHAINCODEID);
    } else if (DATA_HIDING_SCHEME == global.EncryptionScheme) {
        VIEW_MGR = new EncryptionBasedViewMgr(fabric_front, VIEW_MODE, WORKLOAD_CHAINCODEID);
    } else {
        LOGGER.error(`Unrecognized/Unsupported Data Hiding Scheme ${DATA_HIDING_SCHEME}`);
        process.exit(1);
    }
    var view_predicate = VIEW_NAME;
    // Set the view predicate the same as the view name, 
    // Later txn's pub_arg will all be equal to view name so as to fall into this view. 
    return VIEW_MGR.CreateView(VIEW_NAME, view_predicate);

}).then(()=>{
    var batch_count = TXN_COUNT / TXN_LOAD_BATCH_SIZE;
    var batch_ids = [];
    for (var i = 0; i < batch_count; i++) {
        batch_ids.push(i);
    }

    LOGGER.info(`# of batches = ${batch_count}`);

    return batch_ids.reduce( async (previousPromise, batch_id) => {
        await previousPromise;

        LOGGER.info(`sending batch ${batch_id}`);
        var request_promises = [];
        var pub_arg = VIEW_NAME; // since onChainView use pub_args to determine views. 
        for (var i = 0; i < TXN_LOAD_BATCH_SIZE; i++) {
            var req_promise = VIEW_MGR.InvokeTxn(WL_FUNC_NAME, pub_arg, CONFIDENTIAL_DATA, "useless_req");
            request_promises.push(req_promise);
        }

        await Promise.all(request_promises).then((txn_statuses)=>{
            for (var i in txn_statuses) {
                // LOGGER.info(txn_statuses[i]);
                // if (txn_statuses[i][0] != "") {
                //     rejected_txn_count+=1;
                // } else {
                    COMMITTED_TXN_COUNT+=1;
                // }
            }
        });

    },  Promise.resolve());
}).then(()=>{
    LOGGER.info(`Finish loading a view with ${COMMITTED_TXN_COUNT} txns.`);
    TXN_SCAN_START = new Date();
    // As hardcoded in onchainview contract
    return FABRIC_FRONT.Query(WORKLOAD_CHAINCODEID, "RetrieveTxnIdsByView", [VIEW_NAME]);
}).then((result)=>{
    var txn_ids = JSON.parse(result);
    var txn_count = txn_ids.length;
    LOGGER.info("=========================================================");
    LOGGER.info(`# of txns in view: ${txn_count}`);
    LOGGER.info("=========================================================");
    TXN_SCAN_BATCH_COUNT = txn_count / TXN_SCAN_BATCH_SIZE;
    var txn_scan_batch_ids = [];
    for (var i = 0; i < TXN_SCAN_BATCH_COUNT; i++) {
        txn_scan_batch_ids.push(i);
    }

    return txn_scan_batch_ids.reduce( async (previousPromise, batch_id) => {
        await previousPromise;
        // LOGGER.info(`Scan txn batch ${batch_id}`);
        var query_start = new Date();
        var request_promises = [];
        for (var i = 0; i < TXN_SCAN_BATCH_SIZE; i++) {
            let txn_id = txn_ids[batch_id * TXN_SCAN_BATCH_SIZE + i];
            request_promises.push(FABRIC_FRONT.GetTxnDataById(txn_id));
        }

        await Promise.all(request_promises).then((bytes_of_txns)=>{
            var query_end = new Date();
            TXN_QUERY_MS += query_end - query_start;

            var verify_start = query_end;
            for (var i = 0; i < bytes_of_txns.length; i++) {
                var txn = FABRIC_FRONT.DecodeTxn(bytes_of_txns[i]);
                FABRIC_FRONT.InspectTxnRW(txn.transactionEnvelope.payload.data);
            }
            var verify_end = new Date();
            TXN_VERIFY_MS += verify_end - verify_start;

        }).catch((error)=>{
            LOGGER.info(`Fail to get txn ID ${error}`);
        });

    },  Promise.resolve());

}).then(()=>{
    txn_scan_elapse = new Date() - TXN_SCAN_START;

    // Measure Block Query and Verification here. 
    return FABRIC_FRONT.ScanLedgerForDelayStorage();
}).then((ledger_info)=>{
    var chain_height = ledger_info[LEDGER_HEIGHT_FIELD];
    var total_query_ms = ledger_info[QUERY_DELAY_FIELD];
    var total_verification_ms = ledger_info[VERIFY_DELAY_FIELD];
    var total_elapsed = total_query_ms + total_verification_ms;

    LOGGER.info(`Scan ${TXN_SCAN_BATCH_COUNT} ${TXN_SCAN_BATCH_SIZE}-batch transactions in ${txn_scan_elapse} ms ( remote query in ${TXN_QUERY_MS} ms, verify in ${TXN_VERIFY_MS} ms ) `);
    LOGGER.info(`Scan ${chain_height} blocks in ${total_elapsed} ms ( remote query in ${total_query_ms} ms, verify in ${total_verification_ms} ms ) `);
}).catch((err)=>{
    LOGGER.error("Invocation fails with err msg: " + err.stack);
}).finally(()=>{
    process.exit(0);
})
;