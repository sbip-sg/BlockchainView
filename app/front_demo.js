const FabricFront = require("./fabricfront").FabricFront;
const path = require('path');

var FRONT;
var TXN_ID = "57a5044a4be561fbc0347f34c680184bb3fd1557a99808ca55e9c506d5e4e630";

const CHANNEL_NAME="viewchannel";
const CC_NAME="noop";
const CC_FUNC="InvokeTxn";
const CC_ARGS=["1", "2"]; 

Promise.resolve().then(()=>{
    const network_dir="gcp-network";
    // const network_dir="test-network";
    const profile_path = path.resolve(__dirname, '..', network_dir, 'organizations', 'peerOrganizations', 'org1.example.com', 'connection-org1.json');
    const mspId = "Org1MSP";
    const cert_path = path.resolve(__dirname, '..', network_dir, 'organizations', 'peerOrganizations', 'org1.example.com', "users", `Admin@org1.example.com`, "msp", "signcerts", `Admin@org1.example.com-cert.pem`);
    const key_path = path.resolve(__dirname, '..', network_dir, 'organizations', 'peerOrganizations', `org1.example.com`, "users", `Admin@org1.example.com`, "msp", "keystore", "priv_sk");
    FRONT = new FabricFront(profile_path, CHANNEL_NAME, mspId, cert_path, key_path);
    return FRONT.InitNetwork();
}).then(()=>{
    return FRONT.InvokeTxn(CC_NAME, CC_FUNC, CC_ARGS); 
}).then((txn_id) => {
    TXN_ID = txn_id;
    var wait_ms = 5000; // wait for 5s, enough for txn to commit
    console.log(`Wait for ${wait_ms} ms for Txn with ID ${txn_id} to commit`);
    return new Promise(resolve => setTimeout(resolve, wait_ms));
}).then(() => {
    console.log(`Retrieve details of a txn with ID ${TXN_ID}`);
    return FRONT.GetTxnDataById(TXN_ID);
}).then((txn_bytes) => {
    var txn = FRONT.DecodeTxn(txn_bytes);
    // console.log(`Decoded Txn ${JSON.stringify(txn)}`);
}).then(() => {
    return FRONT.GetLedgerHeight();
}).then((height) => {
    console.log(`Ledger Height : ${height}`);
    return FRONT.ScanLedgerForDelayStorage();
}).then((ledger_info) => {
    let ledger_info_str = JSON.stringify(ledger_info);
    console.log(`Ledger Info = ${ledger_info_str}`);
}).catch((err)=>{
    console.error(`Encounter error: ${err.stack}`);

    // throw new Error("Invocation fails with err msg: " + err.message);
}).finally(()=>{
    process.exit(0);
});

