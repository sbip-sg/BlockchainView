'use strict';

const readline = require('readline-sync');
const util = require('util');
const crypto = require('crypto');
const path = require('path');

const FabricFront = require("./fabricfront").FabricFront;
const EncryptionBasedViewMgr = require("./encryption_based_view_mgr").EncryptionBasedViewMgr;
const HashBasedViewMgr = require("./hash_based_view_mgr").HashBasedViewMgr;
const PlainViewMgr = require("./plain_view_mgr").PlainViewMgr;
const global = require('./global.js');

const LOGGER = require('loglevel');
//more docs here - https://github.com/pimterry/loglevel#documentation
LOGGER.setDefaultLevel('info')
var VIEW_MGR;
const CONFIDENTIAL_DATA = "SECRET_PAYLOAD";
const CHANNEL_NAME = "viewchannel";
var WORKLOAD_CHAINCODEID;

const WL_FUNC_NAME = "InvokeTxn"; // consistent to onchainview, secretcontract, noop, privateonchainview, privateonly contracts 

const VIEW_NAME = "DEMOVIEW";

const keyPair = crypto.generateKeyPairSync('rsa', { 
    modulusLength: 520, 
    publicKeyEncoding: { 
        type: 'spki', 
        format: 'pem'
    }, 
    privateKeyEncoding: { 
    type: 'pkcs8', 
    format: 'pem', 
    cipher: 'aes-256-cbc', 
    passphrase: ''
    } 
}); 

// The key pair for User U2. 
const PUB_KEY = keyPair.publicKey;
const PRV_KEY = keyPair.privateKey;

var USER_INPUT;
/////////////////////////////////////////////////////////////
// Below are expected to execute at the U1 side, who invokes the transaction and creates the view. 
Promise.resolve().then(()=>{
    const network_dir="gcp-network";
    // const network_dir="test-network";
    const profile_path = path.resolve(__dirname, '..', network_dir, 'organizations', 'peerOrganizations', 'org1.example.com', 'connection-org1.json');
    const mspId = "Org1MSP";
    const cert_path = path.resolve(__dirname, '..', network_dir, 'organizations', 'peerOrganizations', 'org1.example.com', "users", `Admin@org1.example.com`, "msp", "signcerts", `Admin@org1.example.com-cert.pem`);
    const key_path = path.resolve(__dirname, '..', network_dir, 'organizations', 'peerOrganizations', `org1.example.com`, "users", `Admin@org1.example.com`, "msp", "keystore", "priv_sk");
    var fabric_front = new FabricFront(profile_path, CHANNEL_NAME, mspId, cert_path, key_path);
    return fabric_front.InitNetwork();
}).then((fabric_front)=>{
    LOGGER.info("===============================================");
/////////////////////////////////////////////////////////////////////
    // const view_mode = global.ViewInContractMode;
    // WORKLOAD_CHAINCODEID = "onchainview";

    const view_mode = global.RevocableMode
    WORKLOAD_CHAINCODEID = "secretcontract";

    // const view_mode = global.IrrevocableMode
    // WORKLOAD_CHAINCODEID = "secretcontract";
    const viewstorage_contractID = "viewstorage"; // only used in irrevocable mode
// ================================================================
    VIEW_MGR = new EncryptionBasedViewMgr(fabric_front, view_mode, WORKLOAD_CHAINCODEID, viewstorage_contractID);

    // VIEW_MGR = new HashBasedViewMgr(fabric_front, view_mode, WORKLOAD_CHAINCODEID, viewstorage_contractID);

/////////////////////////////////////////////////////////////////////
    // const view_mode = global.ViewInContractMode;
    // WORKLOAD_CHAINCODEID = "privateonchainview";
    // VIEW_MGR = new PlainViewMgr(fabric_front, view_mode, WORKLOAD_CHAINCODEID);

// ================================================================
/////////////////////////////////////////////////////////////////////

    LOGGER.info("===============================================");
    LOGGER.info(`1. The view owner prepares a view named ${VIEW_NAME}`);
    return VIEW_MGR.CreateView(VIEW_NAME, VIEW_NAME);
}).then(()=>{
    USER_INPUT = readline.question(`\nCONTINUE?\n`);
    LOGGER.info("===============================================");
    LOGGER.info(`2. A view owner prepares a txn to invoke Contract ${WORKLOAD_CHAINCODEID} with confidential part ${CONFIDENTIAL_DATA}`);
    return VIEW_MGR.InvokeTxn(WL_FUNC_NAME, VIEW_NAME, CONFIDENTIAL_DATA, 1);

}).then((txn_info)=>{
    var txn_status = txn_info[0];
    var txnID = txn_info[1];
    USER_INPUT = readline.question(`\nCONTINUE?\n`);
    LOGGER.info("===============================================");
    LOGGER.info(`3. A view owner inserts txn ${txnID} to View ${VIEW_NAME}`);
    return VIEW_MGR.AppendView(VIEW_NAME, [txnID]);
}).then(()=>{
    USER_INPUT = readline.question(`\nCONTINUE?\n`);
    LOGGER.info("===============================================");
    LOGGER.info(`4. The view owner distributes view ${VIEW_NAME} to a user identified by its public key.`);
    return VIEW_MGR.DistributeView(VIEW_NAME, PUB_KEY);
}).then((distributedData)=>{
    USER_INPUT = readline.question(`\nCONTINUE?\n`);
    LOGGER.info("===============================================");
    LOGGER.info("5. The view user receives the view data from the view owner.");
    return VIEW_MGR.OnReceive(distributedData, PRV_KEY);
}).then(()=>{
    LOGGER.info("===============================================");
    USER_INPUT = readline.question(`\nCONTINUE?\n`);
    LOGGER.info("END.");
}).catch((err)=>{
    console.error(`Encounter error: ${err.stack}`);
    // throw new Error("Invocation fails with err msg: " + err.message);
});