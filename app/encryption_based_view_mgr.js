'use strict';

const FabricFront = require("./fabricfront").FabricFront;
const util = require('util');
const cmgr = require('./crypto_mgr.js');
const global = require('./global.js');
const LOGGER = require('loglevel');
LOGGER.setDefaultLevel('debug')

class EncryptionBasedViewMgr {
    // wl_contract_id : contract ID to for the real workload, i.e., supply chain
    // vs_contract_id : view_storage contract ID, exclusively for irrevocable. 
    constructor(fabric_front, mode, wl_contract_id, vs_contract_id) {
        this.fabric_front = fabric_front;
        this.mode = mode;
        this.wl_contract_id = wl_contract_id;
        if (mode == global.IrrevocableMode) {
            this.vs_contract_id = vs_contract_id;
        }

        this.view_txns = {}; // associate the viewName with a list of txnIDs
        this.txn_keys = {}; // associate the viewName with the view key
        this.view_keys = {}; 
    }

    InvokeTxn(func_name, pub_arg, prv_arg, raw_req) { 
        var key = cmgr.CreateKey();
        LOGGER.info(`\tGenerate a random key ${key} for this txn`);

        var secret_payload = cmgr.Encrypt(key, prv_arg); 
        LOGGER.info(`\tUse the key to encode the private info ${prv_arg} into ${secret_payload}`);

        return this.fabric_front.InvokeTxn(this.wl_contract_id, func_name, [pub_arg, secret_payload]).then((txnID)=>{
            this.txn_keys[txnID] = key;
            LOGGER.info(`\tSend a txn ${txnID} to invoke ${this.wl_contract_id} with the prv arg. `);
            return [0, txnID, raw_req];
        })
        .catch(error => {
            LOGGER.error(`Error with code ${error}`);
            // probably due to MVCC
            return [error.transactionCode, "", raw_req];
        });
    }

    // view predicate is used when in ViewInContractMode
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
            var merge_period_sec = 500;
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

            LOGGER.info(`\tAssociate the encrypted txnID with the encrypted txn key and serialize the association into a view msg with the view key ${view_key}`);
            var encoded_view_msg = {}
            for (var i in txnIDs) {
                var txnID = txnIDs[i];
                encoded_view_msg[cmgr.Encrypt(view_key, txnID)] = cmgr.Encrypt(view_key, this.txn_keys[txnID]);
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
                encoded_msg_view[cmgr.Encrypt(view_key, txnID)] = cmgr.Encrypt(view_key, this.txn_keys[txnID]);
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

    // // To be invoked at the recipient side
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
            var txn_keys = [];
            var promises = [];
            for (const encoded_txnID in encrypted_view_msg) {
                var txnID = cmgr.Decrypt(view_key, encoded_txnID);
                var txn_key = cmgr.Decrypt(view_key, encrypted_view_msg[encoded_txnID]);

                txnIDs.push(txnID);
                txn_keys.push(txn_key);
                LOGGER.debug(`\tRecover Txn Key ${txn_key} for Txn ID ${txnID}`);
                var prv_field = "secretkey"; // TODO: as hardcoded in secretcontract.go

                promises.push(this.fabric_front.GetWriteFieldFromTxnId(txnID, prv_field));
            }
            
            // Skip the validation step
            LOGGER.info(`\tValidate for View ${view_name}. Use the recovered txn key to decode the original secret data. `);
            return Promise.all(promises).then((secrets)=>{
                for (var i = 0; i < txnIDs.length; i++) {
                    var txnID = txnIDs[i];
                    var secret_data = cmgr.Decrypt(txn_keys[i], secrets[i]);
                    LOGGER.debug(`\t\tTxnID: ${txnID}, The decoded secret data: ${secret_data}`);
                }
            });
        });
    }
}

module.exports.EncryptionBasedViewMgr = EncryptionBasedViewMgr;