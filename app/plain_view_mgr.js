'use strict';

const FabricFront = require("./fabricfront").FabricFront;
const util = require('util');
const LOGGER = require('loglevel');

const cmgr = require('./crypto_mgr.js');
const global = require('./global.js');

class PlainViewMgr {
    // wl_contract_id : contract ID to for the real workload, i.e., supply chain
    constructor(fabric_front, mode, wl_contract_id) {
        this.fabric_front = fabric_front;
        this.mode = mode;
        this.wl_contract_id = wl_contract_id;
        if (!(mode === global.ViewInContractMode || mode === global.MockFabricMode || global.OnlyWorkloadMode)) {
            LOGGER.error(`PlainViewMgr only supports ${global.ViewInContractMode}, ${global.MockFabricMode} or ${global.OnlyWorkloadMode}`);
        }
        this.txn_secret = {}; // txnID to request secret
        this.view_txns = {}; // view_name to a list of txnIDs
        this.view_keys = {}; // view_name to the view key
    }

    InvokeTxn(func_name, pub_arg, prv_arg, raw_req) {
        return this.fabric_front.InvokeTxn(this.wl_contract_id, func_name, [pub_arg, prv_arg]).then((txnID)=>{
            this.txn_secret[txnID] = prv_arg;
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
        if (this.mode === global.OnlyWorkloadMode) {
            LOGGER.info(`Ignore view creations in ${global.OnlyWorkloadMode} mode`);
            return;
        }

        this.view_txns[view_name] = [];
        LOGGER.info(`\tInitialize view ${view_name}`);

        var merge_period_sec = 200;
        return this.fabric_front.InvokeTxn(this.wl_contract_id, "CreateView", [view_name, view_predicate, merge_period_sec]).then(()=>{
            return view_name;
        });
    }

    AppendView(view_name, txnIDs) {
        if (this.mode === global.OnlyWorkloadMode) {
            LOGGER.info(`Ignore view appending in ${global.OnlyWorkloadMode} mode`);
            return;
        }
        this.view_txns[view_name].push(...txnIDs);
        LOGGER.info(`\tAppend view ${view_name} with ${txnIDs}`);
    }

    // return as a Buffer type
    DistributeView(view_name, userPubKey) {
        if (this.mode === global.OnlyWorkloadMode) {
            LOGGER.error(`Not allow to distribute a view ${global.OnlyWorkloadMode} mode`);
            process.exit(1);
        }

        var distributedData = {};
        distributedData.view_name = view_name;
        distributedData.mode = this.mode;
        var view_key = cmgr.CreateKey();
        LOGGER.info(`\tGenerate a view key ${view_key}, used to encode the view message.`) ;

        var txnIDs = this.view_txns[view_name];
        if (txnIDs === undefined) {
            throw new Error(`View  ${view_name} has not been created. `);
        }

        LOGGER.info(`\tAssociate the view-key-encrypted txnID with the view-key-encrypted txn key and serialize the association into a view message. `);
        var encoded_msg_view = {}
        for (var i in txnIDs) {
            var txnID = txnIDs[i];
            encoded_msg_view[cmgr.Encrypt(view_key, txnID)] = cmgr.Encrypt(view_key, this.txn_secret[txnID]);        
        }

        distributedData["viewData"] = JSON.stringify(encoded_msg_view);
        LOGGER.info(`\tDistribute the encoded view message`);
        LOGGER.info(`\tDistribute the view key ${view_key} protected the provided public key`);

        var encrypted_view_key = cmgr.PublicEncrypt(userPubKey, view_key);
        distributedData.encryptedKey = encrypted_view_key;
        return distributedData;
    }

    // To be invoked at the recipient side
    OnReceive(distributedData, userPrvKey) {
        if (this.mode === global.OnlyWorkloadMode) {
            LOGGER.error(`Not allow to receive a view ${global.OnlyWorkloadMode} mode`);
            process.exit(1);
        }

        var view_key = cmgr.PrivateDecrypt(userPrvKey, '', distributedData.encryptedKey);
        var view_name = distributedData.view_name;
        LOGGER.info(`\tRecover the view ${view_name} to ${view_key} with the private key`);
        var encrypted_view_msg = JSON.parse(distributedData.viewData);
        var txnIDs = [];
        for (const encodedTxnID in encrypted_view_msg) {
            var txnID = cmgr.Decrypt(view_key, encodedTxnID.toString());
            // var secret = cmgr.Decrypt(view_key, encrypted_view_msg[encodedTxnID]);
            txnIDs.push(txnID);
        }

        return this.fabric_front.Query(this.wl_contract_id, "RetrieveTxnIdsByView", [view_name]).then((onchain_txnIDs)=>{
            onchain_txnIDs = JSON.parse(onchain_txnIDs);
            LOGGER.debug(`\t View ${view_name}: TxnIDs from View Owner ${txnIDs}, TxnIDs from the contract ${onchain_txnIDs}`);
        }); 
    }
}

module.exports.PlainViewMgr = PlainViewMgr;