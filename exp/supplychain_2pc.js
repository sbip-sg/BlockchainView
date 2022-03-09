'use strict';

const path = require('path');
const fs = require('fs');

const FabricFront = require("../app/fabricfront").FabricFront;
const MockFabricFront = require("../app/fabricfront").MockFabricFront;
const TwoPhaseTxnMgr = require("./two_phase_mgr").TwoPhaseTxnMgr;
const LEDGER_SIZE_FIELD = require("../app/fabricfront").LEDGER_SIZE_FIELD;

const LOGGER = require('loglevel');
//more docs here - https://github.com/pimterry/loglevel#documentation
LOGGER.setDefaultLevel('info');

const WORKLOAD_PATH = process.argv[2]; 
var PHYSICAL_VIEW_COUNT = process.argv[3];
const CHANNEL_NAME = process.argv[4]; // assume the same channel name for each chain
var ORG_DIRS = [];
for (var i = 5; i < process.argv.length; i+=1) {
    ORG_DIRS.push(process.argv[i]);
}
const TWO_PC_CHAINCODEID = "txncoordinator";

LOGGER.info("Parameters: ")
LOGGER.info(`\t # of Chains : ${ORG_DIRS.length}`);
LOGGER.info(`\t ORG_DIRS : ${ORG_DIRS}`);
LOGGER.info(`\t WORKLOAD_PATH : ${WORKLOAD_PATH}`);
LOGGER.info(`\t CHANNEL_NAME : ${CHANNEL_NAME}`);
LOGGER.info(`\t TWO_PC_CHAINCODEID : ${TWO_PC_CHAINCODEID}`);
LOGGER.info(`\t PHYSICAL_VIEW_COUNT : ${PHYSICAL_VIEW_COUNT}`);
LOGGER.info(`=============================================`);

var WORKLOAD = JSON.parse(fs.readFileSync(WORKLOAD_PATH));
var EXEC_START;
var TOTAL_REQ_COUNT = 0;
var BATCH_ID = 0;
var BATCH_EXEC_DELAY = 0;

const CONFIDENTIAL_DATA = "SECRET_PAYLOAD";

var LOGICAL2PHYSICALVIEWS = {};
var COMMITTED_TXN_COUNT = 0;
var REJECTED_TXN_COUNT = 0;

function get_physical_view_name(id) {
    return "PhysicalView"+ id;    
}

Promise.resolve().then(()=>{
    var logical_view_count = WORKLOAD["views"].length;

    // We treat the workload-specified views as logical, whereas we actually implement ${PHYSICAL_VIEW_COUNT} physical views. 
    // Their associations are maintained in ${LOGICAL2PHYSICALVIEWS}. 
    // We decouple them so that we can flexibly change the number of views while using the same workload. 
    if (PHYSICAL_VIEW_COUNT == 0) {
        PHYSICAL_VIEW_COUNT = logical_view_count;
    }

    LOGGER.info(`Create ${PHYSICAL_VIEW_COUNT} physical views for ${logical_view_count} logical ones. `);

    for (var i = 0; i < logical_view_count; i++) {
        var logical_view_name = WORKLOAD["views"][i];
        var physical_view_name =  get_physical_view_name(i % PHYSICAL_VIEW_COUNT);
        // Must be identical to the above physical view name
        LOGICAL2PHYSICALVIEWS[logical_view_name] = physical_view_name;
        LOGGER.info(`\tLogical View ${logical_view_name} to PhysicalView ${physical_view_name}`);
    }

    // Assign physical views to chains in roundrobin manner.
    // Under the case when views outnumber chains, a chain may run for multiple views. 
    var view2chain = {};
    for (var i = 0; i < PHYSICAL_VIEW_COUNT; i++) {
        var org_dir = ORG_DIRS[i % ORG_DIRS.length];
        if (org_dir === "Mock") {
            view2chain[get_physical_view_name(i)] = new MockFabricFront();
        } else {
            var peer_count = 1;
            if (process.env.PEER_COUNT) {
                peer_count = parseInt(process.env.PEER_COUNT);
            } else {
                LOGGER.error("Not setting global env var PEER_COUNT");
                process.exit(1);
            }
            var org_id = 1 + i % peer_count;
            const profile_path = path.resolve(org_dir, `org${org_id}.example.com`, `connection-org${org_id}.json`);
            const mspId = `Org${org_id}MSP`;
            const cert_path = path.resolve(org_dir, `org${org_id}.example.com`, "users", `Admin@org${org_id}.example.com`, "msp", "signcerts", `Admin@org${org_id}.example.com-cert.pem`);
            const key_path = path.resolve(org_dir, `org${org_id}.example.com`, "users", `Admin@org${org_id}.example.com`, "msp", "keystore", "priv_sk");

            view2chain[get_physical_view_name(i)] = new FabricFront(profile_path, CHANNEL_NAME, mspId, cert_path, key_path);
        }
    }
    let two_phase_mgr = new TwoPhaseTxnMgr(TWO_PC_CHAINCODEID, view2chain);
    return two_phase_mgr.InitNetworks();
}).then((two_phase_mgr)=>{
    EXEC_START = new Date();
    var req_batches = WORKLOAD["blocks"];
    LOGGER.info(`# of Request Batches: ${req_batches.length}`);

    return req_batches.reduce( async (previousPromise, req_batch) => {
        await previousPromise;
        BATCH_ID+=1;
        var batch_req_count = req_batch.length;
        TOTAL_REQ_COUNT += batch_req_count;
        LOGGER.info(`Prepare to group ${batch_req_count} requests in batch ${BATCH_ID}`);

        var batch_start = new Date();
        var request_promises = [];
        for (var i = 0; i < batch_req_count; i++) {

            var req = req_batch[i];
            var req_logical_view_count = req["views"].length;
            var req_physical_views = [];
            var reqID = req["tid"];
            // Filter out views with no regard to this request. 
            for (var ii = 0; ii < req_logical_view_count; ii++) {
                if  (req["views"][ii]["tid"] !== reqID) { continue; }
                var req_physical_view = LOGICAL2PHYSICALVIEWS[req["views"][ii]["name"]];
                req_physical_views.push(req_physical_view);
            }
            LOGGER.info(`Req ${reqID} to ${req_physical_views}`);
            var two_phase_req = two_phase_mgr.TwoPhaseCommit(req_physical_views, reqID, CONFIDENTIAL_DATA).then(()=>{
                COMMITTED_TXN_COUNT+=1;
            }).catch(()=>{
                REJECTED_TXN_COUNT+=1;
            });
            request_promises.push(two_phase_req);
        }

        await Promise.all(request_promises).then(()=>{
            let batch_elapsed = new Date() - batch_start;
            BATCH_EXEC_DELAY += batch_elapsed;
        });
    });
// }).then(() => {
//     return two_phase_mgr.ScanLedgersForDelayStorage();
// }).then((info_of_ledgers) => {
//     LOGGER.info("===========================================");
//     var size_sum = 0;
//     var chain_count = 0;
//     for (var view_name in this.info_of_ledgers) {
//         chain_count+=1;
//         var ledger_size = info_of_ledgers[view_name][LEDGER_SIZE_FIELD];
//         LOGGER.info(`\tLedger Size (Bytes) of the Chain for View ${view_name} : ${ledger_size}`);
//         size_sum += ledger_size;
//     }
//     LOGGER.info(`${chain_count} Chains with Total Size (Bytes) : ${size_sum}`);
}).catch((err)=>{
    LOGGER.error("Invocation fails with err msg: " + err.stack);
}).finally(()=>{
    let elapsed = new Date() - EXEC_START;
    let avg_batch_delay = Math.floor(BATCH_EXEC_DELAY / BATCH_ID);
    LOGGER.info(`Total Duration (ms): ${elapsed} ,  # of app txn:  ${TOTAL_REQ_COUNT} , Committed Txn Count: ${COMMITTED_TXN_COUNT} , avg batch delay (ms): ${avg_batch_delay} # of batches ${BATCH_ID}`);    

    process.exit(0)
})
;




