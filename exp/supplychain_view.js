'use strict';

const path = require('path');
const fs = require('fs');
const util = require('util');

const FabricFront = require("../app/fabricfront").FabricFront;
const MockFabricFront = require("../app/fabricfront").MockFabricFront;
const LEDGER_SIZE_FIELD = require("../app/fabricfront").LEDGER_SIZE_FIELD;

const EncryptionBasedViewMgr = require("../app/encryption_based_view_mgr").EncryptionBasedViewMgr;
const HashBasedViewMgr = require("../app/hash_based_view_mgr").HashBasedViewMgr;
const PlainViewMgr = require("../app/plain_view_mgr").PlainViewMgr;
const global = require('../app/global.js');

const LOGGER = require('loglevel');
const { loadavg } = require('os');
//more docs here - https://github.com/pimterry/loglevel#documentation
LOGGER.setDefaultLevel('info');

const ORG_DIR = process.argv[2];
const WORKLOAD_PATH = process.argv[3]; 
const DATA_HIDING_SCHEME = process.argv[4]; // encryption/hash/plain
const VIEW_MODE = process.argv[5]; // irrevocable/revocable/view_in_contract/mock_fabric
const CHANNEL_NAME = process.argv[6];
const WORKLOAD_CHAINCODEID = process.argv[7];

var PHYSICAL_VIEW_COUNT = 0; 
if (process.argv[8] !== undefined) {
    PHYSICAL_VIEW_COUNT = parseInt(process.argv[8]);
}

LOGGER.info("Parameters: ")
LOGGER.info(`\t ORG_DIR : ${ORG_DIR}`);
LOGGER.info(`\t WORKLOAD_PATH : ${WORKLOAD_PATH}`);
LOGGER.info(`\t DATA_HIDING_SCHEME : ${DATA_HIDING_SCHEME}`);
LOGGER.info(`\t VIEW_MODE : ${VIEW_MODE}`);
LOGGER.info(`\t CHANNEL_NAME : ${CHANNEL_NAME}`);
LOGGER.info(`\t WORKLOAD_CHAINCODEID : ${WORKLOAD_CHAINCODEID}`);
LOGGER.info(`\t PHYSICAL_VIEW_COUNT : ${PHYSICAL_VIEW_COUNT}`);
LOGGER.info(`=============================================`);

var VIEW_MGR;
var WORKLOAD = JSON.parse(fs.readFileSync(WORKLOAD_PATH));
var EXEC_START;
var REQID2TXNID = {}; // mapping from application requestID to blockchain transactionID 
var TOTAL_REQ_COUNT = 0;
var BATCH_ID = 0;
var BATCH_EXEC_DELAY = 0;
var TOTAL_ELAPSED = 0;

const CONFIDENTIAL_DATA = "SECRET_PAYLOAD";
const WL_FUNC_NAME = "InvokeTxn"; // consistent to onchainview, secretcontract, noop, privateonchainview, privateonly contracts 

var LOGICAL2PHYSICALVIEWS = {};
var COMMITTED_TXN_COUNT = 0;
var REJECTED_TXN_COUNT = 0;
var FABRIC_FRONT;

function PreparePubArg(view_mode, req) {
    var pub_arg = "random_pub_arg";
    if (view_mode === global.ViewInContractMode) {
        // Compute the involved physical views for the request.
        // Prepare the pub_arg as in the format of <PhysicalView1>_<PhysicalView2> ...
        // THis pub_arg is only useful ViewInContractMode 
        var reqID = req["tid"];
        var req_logical_view_count = req["views"].length;
        var req_physical_views = [];
        for (var ii = 0; ii < req_logical_view_count; ii++) {
            if (req["views"][ii]["tid"] != reqID) { continue; }
            var logical_view_name = req["views"][ii]["name"];
            var physical_view_name = LOGICAL2PHYSICALVIEWS[logical_view_name];
            req_physical_views.push(physical_view_name);
        }
        pub_arg = req_physical_views.join("_");  
    }
    return pub_arg;
}

Promise.resolve().then(()=>{
    var fabric_front;
    if (VIEW_MODE === global.MockFabricMode) {
        fabric_front = new MockFabricFront();
    } else {
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
    }
    return fabric_front.InitNetwork();
}).then((fabric_front)=>{
    FABRIC_FRONT = fabric_front;
    const viewstorage_contractID = "viewstorage"; // only used in irrevocable mode;
    if (DATA_HIDING_SCHEME == global.HashScheme) {
        VIEW_MGR = new HashBasedViewMgr(fabric_front, VIEW_MODE, WORKLOAD_CHAINCODEID, viewstorage_contractID);; 

    } else if (DATA_HIDING_SCHEME == global.EncryptionScheme) {
        VIEW_MGR = new EncryptionBasedViewMgr(fabric_front, VIEW_MODE, WORKLOAD_CHAINCODEID, viewstorage_contractID);; 
        
    } else if (DATA_HIDING_SCHEME == global.PlainScheme) {
        VIEW_MGR = new PlainViewMgr(fabric_front, VIEW_MODE, WORKLOAD_CHAINCODEID, viewstorage_contractID);; 
    } else {
        LOGGER.error(`Unrecognized Data Hiding Scheme ${DATA_HIDING_SCHEME}`);
        process.exit(1);
    }

    var view_creation_promises = [];
    LOGGER.info("===============================================");
    var logical_view_count = WORKLOAD["views"].length;

    // We treat the workload-specified views as logical, whereas we actually implement ${physical_view_count} physical views. 
    // Their associations are maintained in ${LOGICAL2PHYSICALVIEWS}. 
    // We decouple them so that we can flexibly change the number of views while using the same workload. 
    if (PHYSICAL_VIEW_COUNT == 0) {
        PHYSICAL_VIEW_COUNT = logical_view_count;
    }

    LOGGER.info(`Create ${PHYSICAL_VIEW_COUNT} physical views for ${logical_view_count} logical ones. `);

    for (var i = 0; i < PHYSICAL_VIEW_COUNT; i++) {
        view_creation_promises.push(VIEW_MGR.CreateView("PhysicalView"+i, []));
    }

    for (var i = 0; i < logical_view_count; i++) {
        var logical_view_name = WORKLOAD["views"][i];
        var id = "" + i % PHYSICAL_VIEW_COUNT;
        var physical_view_name =  "PhysicalView"+ id;
        // Must be identical to the above physical view name
        LOGICAL2PHYSICALVIEWS[logical_view_name] = physical_view_name;
        LOGGER.info(`\tLogical View ${logical_view_name} to PhysicalView ${physical_view_name}`);
    }

    return Promise.all(view_creation_promises);

}).then(()=>{
    EXEC_START = new Date();
    var req_batches = WORKLOAD["blocks"];
    LOGGER.info(`# of Request Batches: ${req_batches.length}`);

    return req_batches.reduce( async (previousPromise, req_batch) => {
        await previousPromise;
        BATCH_ID+=1;
        var batch_req_count = req_batch.length;
        TOTAL_REQ_COUNT += batch_req_count;
        LOGGER.info(`Prepare to group ${batch_req_count} requests in batch ${BATCH_ID}`);
        // userinput = readline.question(`\nCONTINUE?\n`);

        var batch_start = new Date();
        var request_promises = [];
        for (var i = 0; i < batch_req_count; i++) {

            var req = req_batch[i]
            var pub_arg = PreparePubArg(VIEW_MODE, req);
            var req_promise = VIEW_MGR.InvokeTxn(WL_FUNC_NAME, pub_arg, CONFIDENTIAL_DATA, req).then((result)=>{
                var status_code = result[0];
                if (status_code !== 0) {
                    REJECTED_TXN_COUNT+=1;
                    return;
                } else if (VIEW_MODE === global.ViewInContractMode) {
                    COMMITTED_TXN_COUNT+=1;
                    return;
                } else { // For Revocable/Irrevocable/MockFabric Mode. Need to explicitly maintain views by appending operations. 
                    COMMITTED_TXN_COUNT+=1;

                    var txnID = result[1];
                    var raw_req = result[2];

                    var reqID = raw_req["tid"];
                    REQID2TXNID[reqID] = txnID;
                    // For each view requests, group into 
                    //   PhysicalView1 -> [txnID1, txnID2, txnID3]
                    //   PhysicalView2 -> [txnID3, txnID4]
                    //   (PhysicalView is transformed from Logical View, txnID from requestID)

                    var logical_view_count = raw_req["views"].length;
                    var physicalview2TxnIDs = {};
                    for (var ii = 0; ii < logical_view_count; ii++) {
                        let other_reqID = raw_req["views"][ii]["tid"];
                        let other_txnID = REQID2TXNID[other_reqID];
                        if (other_txnID === undefined) {
                            // LOGGER.error(`Can not find txnID for req ${other_reqID}`);
                            // Request other_reqID may be in the same batch of the current request. Both are invoked concurrently. Hence the txnID of other_reqID is yet determined. 
                            // Tmp we skip it. 
                            continue;
                        }
                        let other_logical_view_name = raw_req["views"][ii]["name"];
                        let other_physical_view_name = LOGICAL2PHYSICALVIEWS[other_logical_view_name];
                        if (typeof other_physical_view_name === 'undefined'){
                            console.log(`Can not find physical views for ${other_logical_view_name}`);
                            process.exit(1);
                         }


                        if (other_physical_view_name in physicalview2TxnIDs) {
                            var exists = false;
                            for (var j = 0; j < physicalview2TxnIDs[other_physical_view_name].length; j++) {
                                if (physicalview2TxnIDs[other_physical_view_name][j] === other_txnID) {
                                    exists = true; 
                                    break
                                }
                            }
    
                            if (! exists) {
                                physicalview2TxnIDs[other_physical_view_name].push(other_txnID);
                            }
                        } else {
                            physicalview2TxnIDs[other_physical_view_name] = [other_txnID];
                        }
    
                    }

                    var view_append_promises = [];
                    for (var view_name in physicalview2TxnIDs) {
                        LOGGER.info(`View ${view_name} is appended with txns [${physicalview2TxnIDs[view_name]}]. `)
                        
                        view_append_promises.push(VIEW_MGR.AppendView(view_name, physicalview2TxnIDs[view_name]));
                    }

                    return Promise.all(view_append_promises);
                }
            });
            request_promises.push(req_promise);
        }

        await Promise.all(request_promises).then(()=>{
            let batch_elapsed = new Date() - batch_start;
            BATCH_EXEC_DELAY += batch_elapsed;
        });
    });
}).then(() => {
    TOTAL_ELAPSED = new Date() - EXEC_START;
//     return FABRIC_FRONT.ScanLedgerForDelayStorage();
// }).then((ledger_info) => {

//     var ledger_size = ledger_info[LEDGER_SIZE_FIELD];
//     LOGGER.info(`Ledger Size (Bytes): ${ledger_size}`);
}).catch((err)=>{
    LOGGER.error("Invocation fails with err msg: " + err.stack);
}).finally(()=>{
    let avg_batch_delay = Math.floor(BATCH_EXEC_DELAY / BATCH_ID);
    LOGGER.info(`Total Duration (ms): ${TOTAL_ELAPSED} ,  # of app txn:  ${TOTAL_REQ_COUNT} , Committed Txn Count: ${COMMITTED_TXN_COUNT} , avg batch delay (ms): ${avg_batch_delay} # of batches ${BATCH_ID}`);    

    process.exit(0)
})
;




