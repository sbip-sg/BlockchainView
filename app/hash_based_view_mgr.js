'use strict';

const FabricFront = require("./fabricfront").FabricFront;
const util = require('util');
const LOGGER = require('loglevel');

const cmgr = require('./crypto_mgr.js');
const global = require('./global.js');

class HashBasedViewMgr {
    // wl_contract_id : contract ID to for the real workload, i.e., supply chain
    // vs_contract_id : view_storage contract ID, exclusively for irrevocable. 
    constructor(fabric_front, mode, wl_contract_id, vs_contract_id) {
        this.fabric_front = fabric_front;
        this.mode = mode;
        this.wl_contract_id = wl_contract_id;
        if (mode == global.IrrevocableMode) {
            this.vs_contract_id = vs_contract_id;
        }

        this.txn_secret = {}; // txnID to request secret
        this.view_txns = {}; // view_name to a list of txnIDs
        this.view_keys = {}; // view_name to the view key
        this.txn_salt = {}; // txnID to its salt
    }

    InvokeTxn(func_name, pub_arg, prv_arg, raw_req) { 
        var salt = cmgr.CreateSalt();
        LOGGER.info(`\tCreate a random salt ${salt}`);
        var secret_payload = cmgr.HashOp(prv_arg + salt);
        LOGGER.info(`\tHash the confidential part into ${secret_payload} `);

        return this.fabric_front.InvokeTxn(this.wl_contract_id, func_name, [pub_arg, secret_payload]).then((txnID)=>{
            this.txn_secret[txnID] = prv_arg;
            this.txn_salt[txnID] = salt;
            LOGGER.info(`\tSend a txn ${txnID} to invoke ${this.wl_contract_id} with the prv arg. `);
            return [0, txnID, raw_req];
        })
        .catch(error => {
            LOGGER.error(`Error with code ${error}`);
            // probably due to MVCC
            return [error.transactionCode, "", raw_req];
        });
    }

    CreateView(view_name, view_predicate) {
        this.view_txns[view_name] = [];
        LOGGER.info(`\tInitialize view ${view_name}`);

        if (this.mode === global.IrrevocableMode) {
            var view_key = cmgr.CreateKey();
            LOGGER.info(`\tGenerate a key ${view_key} for view ${view_name}`);
            this.view_keys[view_name] = view_key;
            // TODO: CreateView function name is hardcoded as in viewstorage.go
            return this.fabric_front.InvokeTxn(this.vs_contract_id, "CreateView", [view_name, ""]).then(()=>{
                return view_name;
            });
        } else if (this.mode === global.ViewInContractMode) {
            var merge_period_sec = 200;
            return this.fabric_front.InvokeTxn(this.wl_contract_id, "CreateView", [view_name, view_predicate, merge_period_sec]).then(()=>{
                return view_name;
            });;
        } else if (this.mode === global.RevocableMode || this.mode === global.MockFabricMode) { // revocable
            return view_name;
        } else {
            LOGGER.error(`Unrecognized View Mode ${this.mode}`);
            process.exit(1);
        }
    }

    AppendView(view_name, txnIDs) {        
        this.view_txns[view_name].push(...txnIDs);
        LOGGER.info(`\tAppend view ${view_name} with ${txnIDs}`);
        if (this.mode === global.IrrevocableMode) {  // Irrevocable
            var view_key = this.view_keys[view_name];

            LOGGER.info(`\tAssociate the encrypted txnID with the encrypted txn secrets and salts. Then serialize the association into a view msg with the view key ${view_key}`);
            var encoded_view_msg = {}
            for (var i in txnIDs) {
                var txnID = txnIDs[i];
                encoded_view_msg[cmgr.Encrypt(view_key, txnID)] = {
                    "cipher": cmgr.Encrypt(view_key, this.txn_secret[txnID]),
                    "salt": this.txn_salt[txnID]
                };
            }

            let msg = JSON.stringify(encoded_view_msg);
            LOGGER.info("\tUpload the encoded message to the view_storage contract. ");
            return this.fabric_front.InvokeTxn(this.vs_contract_id, "AppendView", [view_name, msg]).then(()=>{
                return view_name;
            }).catch(err => {
                // May raise MVCC conflict. Temporarily ignore. 
                // console.log("MVCC Conflict")
                return view_name;
            });
        } else {
            return view_name;
        }
    }

    DistributeView(view_name, userPubKey) {
        var distributedData = {};
        distributedData.view_name = view_name;
        distributedData.mode = this.mode;
        var view_key;

        if (this.mode === global.RevocableMode || this.mode === global.ViewInContractMode) {
            view_key = cmgr.CreateKey();
            LOGGER.info(`\tGenerate a view key ${view_key}, used to encode the view message.`) ;

            var txnIDs = this.view_txns[view_name];
            if (txnIDs === undefined) {
                throw new Error(`View  ${view_name} has not been created. `);
            }

            LOGGER.info(`\tAssociate the view-key-encrypted txnID with the view-key-encrypted txn key and serialize the association into a view message. `);
            var encoded_msg_view = {}
            for (var i in txnIDs) {
                var txnID = txnIDs[i];
                encoded_msg_view[cmgr.Encrypt(view_key, txnID)] = {
                    "cipher": cmgr.Encrypt(view_key, this.txn_secret[txnID]),
                    "salt": this.txn_salt[txnID]
                };;
            }

            distributedData["viewData"] = JSON.stringify(encoded_msg_view);
            LOGGER.info(`\tDistribute the encoded view message`);
        } else { // irrevocable. 
            var view_key = this.view_keys[view_name];
            if (view_key === undefined) {
                throw new Error(`View ${view_name} has not been created. `);
            }
        }

        LOGGER.info(`\tDistribute the view key ${view_key} protected the provided public key`);

        var encrypted_view_key = cmgr.PublicEncrypt(userPubKey, view_key);
        distributedData.encryptedKey = encrypted_view_key;
        return distributedData;
    }

    // To be invoked at the recipient side
    OnReceive(distributedData, userPrvKey) {
        var view_key = cmgr.PrivateDecrypt(userPrvKey, '', distributedData.encryptedKey);
        var view_name = distributedData.view_name;
        LOGGER.info(`\tRecover the view ${view_name} to ${view_key} with the private key`);

        return Promise.resolve().then(()=>{
            if (distributedData.mode === global.RevocableMode || distributedData.mode === global.ViewInContractMode) {
                return distributedData.viewData;
            } else {
                LOGGER.info("\tFor irrevocable view management, pull the view data from the view storage contract.");
                // GetView function name is hard coded in viewstorage.go. 
                return this.fabric_front.Query(this.vs_contract_id, "GetView", [view_name]);
            }
        }).then((encrypted_view_msg)=>{
            encrypted_view_msg = JSON.parse(encrypted_view_msg);
            var txnIDs = [];
            var txn_secret = {};
            var local_computed_hash = {};
            var promises = [];

            for (const encodedTxnID in encrypted_view_msg) {
                var txnID = cmgr.Decrypt(view_key, encodedTxnID.toString());
                var confidential_data = cmgr.Decrypt(view_key, encrypted_view_msg[encodedTxnID]["cipher"]);
                // console.log("\tUse the password to recover the txnID and the confidential part")
                var salt = encrypted_view_msg[encodedTxnID]["salt"];
                // console.log(`\tThe recovered salt is ${salt}`);
                txnIDs.push(txnID);
                txn_secret[txnID] = confidential_data;
                local_computed_hash[txnID] = cmgr.HashOp(confidential_data + salt);
                var prv_field = "secretkey"; // TODO: as hardcoded in secretcontract.go

                promises.push(this.fabric_front.GetWriteFieldFromTxnId(txnID, prv_field));     
            }
            LOGGER.info(`\tValidate for View ${view_name}. Compare the locally computed hash with the hash in txn`);
            
            return Promise.all(promises).then((secrets)=>{
                for (var i = 0; i < txnIDs.length; i++) {
                    var txnID = txnIDs[i];
                    var onchain_hash = secrets[i];
                    LOGGER.debug(`\t\tTxnID: ${txnID}, Confidential Data: ${txn_secret[txnID]}, Secret Payload: ${onchain_hash}, Locally-computed hash: ${local_computed_hash[txnID]}`);
                }
            });
        });
    }
}

module.exports.HashBasedViewMgr = HashBasedViewMgr;