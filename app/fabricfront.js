
const { Gateway, DefaultEventHandlerStrategies} = require('fabric-network');
const { BlockDecoder } = require('fabric-common');
const path = require('path');
const fs = require('fs');
const fabproto6 = require('fabric-protos');

const LOGGER = require('loglevel');
const QUERY_DELAY_FIELD = "query_delay(ms)";
const VERIFY_DELAY_FIELD = "verification_delay(ms)";
const LEDGER_SIZE_FIELD = "ledger_size(bytes)";
const LEDGER_HEIGHT_FIELD = "height";

class FabricFront {
    constructor(profile_path, channel_name, mspId, cert_path, key_path) {
        this.connection_profile = JSON.parse(fs.readFileSync(profile_path, 'utf8'));
        this.channel_name = channel_name;

        const x509Identity = {
            credentials: {
                certificate: fs.readFileSync(cert_path).toString(),
                privateKey: fs.readFileSync(key_path).toString(),
            },
            mspId: mspId,
            type: 'X.509',
        };        

        // Wait for the peer in the org commits this transaction
        let op = DefaultEventHandlerStrategies.MSPID_SCOPE_ALLFORTX;
        let fabric_in_docker = false;
        if (process.env.FABRIC_IN_DOCKER) {
            fabric_in_docker = true;
        }
        this.gateway_option = {
            identity:x509Identity ,
            // According to https://hyperledger.github.io/fabric-sdk-node/release-1.4/module-fabric-network.Gateway.html, asLocalhost is set to true only when fabric runs in docker.  
            discovery: {asLocalhost: fabric_in_docker},
            eventHandlerOptions: {
                strategy: op 
            }  
        };
    }

    async InitNetwork() {
        const gateway = new Gateway();
        await gateway.connect(this.connection_profile, this.gateway_option);
        this.network = await gateway.getNetwork(this.channel_name);
        return this;
    }

    // Invoke a state-modifying txn that undergoes consensus and validation. 
    async InvokeTxn(cc_id, func_name, args) {
        // LOGGER.info(`InvokeTxn ${cc_id} with ${func_name} and ${args}`);
        const contract = this.network.getContract(cc_id);
        const txn = contract.createTransaction(func_name);
        await txn.submit(...args);
        const txnID = txn.getTransactionId();
        return txnID;
    }

    // Query a chaincode state on a peer without undergoing the consensus
    async Query(cc_id, function_name, args) {
        const contract = this.network.getContract(cc_id);
        const result_bytes = await contract.evaluateTransaction(function_name, ...args);
        return result_bytes;
    }

    async GetWriteFieldFromTxnId(txnID, field) {
        let txn_data = await this.GetTxnDataById(txnID);
        let decoded_txn = this.DecodeTxn(txn_data);
        let write_sets = decoded_txn.transactionEnvelope.payload.data.actions[0].payload.action.proposal_response_payload.extension.results.ns_rwset[1].rwset.writes;

        for (var i = 0; i < write_sets.length; i++) {
            if (write_sets[i].key === field ) {
                return write_sets[i].value.toString();
            } else {
                LOGGER.debug("Writekey: ", writeSets[i].key);
            }
        }
    }

    // Inspect a txn's accessed value to mock the verification. 
    InspectTxnRW(txnData) {
        if (txnData.hasOwnProperty('actions')) {
            // a normal txn has `actions` record
            var writeSets = txnData.actions[0].payload.action.proposal_response_payload.extension.results.ns_rwset[1].rwset.writes;

            for (var i = 0; i < writeSets.length; i++) {
            }

            var readSets = txnData.actions[0].payload.action.proposal_response_payload.extension.results.ns_rwset[1].rwset.reads;
            for (var i = 0; i < readSets.length; i++) {
            }
            LOGGER.debug(`read counts = ${readSets.length}, write counts = ${writeSets.length}`);
        } else {
            // Ignore config txns
        }
    }

    async GetLedgerHeight() {
        const result_bytes = await this.Query('qscc', 'GetChainInfo', [this.channel_name]);
        const blockinfoProto = fabproto6.common.BlockchainInfo.decode(result_bytes);
        var height = blockinfoProto.height;
        return height;
    }

    async GetTxnDataById(txn_id) {
        const txn_bytes = await this.Query('qscc', 'GetTransactionByID', [this.channel_name, txn_id]);
        return txn_bytes;
    }

    DecodeTxn(txn_bytes) {
        return BlockDecoder.decodeTransaction(txn_bytes);
    }

    async BatchQueryLedgerStorage() {
        var total_storage = 0;
        var chain_height = await this.GetLedgerHeight();
        console.log(`Chain height = ${chain_height}`);

        var num_of_blk_per_batch = 10;
        console.log(`Block Querying the chain with batch size ${num_of_blk_per_batch}...`);
        var batch_count = chain_height / num_of_blk_per_batch;
        var blk_id = 0;
        for (var i = 0 ; i <= batch_count; i++) {
            let blk_query_promises = [];
            console.log(`  Pulling for ${num_of_blk_per_batch} blocks from height ${blk_id} `);
            for (var j = 0 ; j < num_of_blk_per_batch ; j++) {
                blk_id+=1;
                if (blk_id < chain_height) {
                    blk_query_promises.push(this.Query('qscc', 'GetBlockByNumber', [this.channel_name, String(blk_id)]).then((result_bytes)=>{
                        total_storage+=result_bytes.length;
                    }));
                }
            }
            await Promise.all(blk_query_promises);
        }
        var result = {};
        result[LEDGER_SIZE_FIELD] = total_storage;
        result[LEDGER_HEIGHT_FIELD] = chain_height;

        return result;
    }

    async ScanLedgerForDelayStorage() {

        var total_query_ms = 0;
        var total_verification_ms = 0;
        var total_storage = 0;
        console.log(`Querying chain height...`);
        var chain_height = await this.GetLedgerHeight();
        console.log(`Chain height = ${chain_height}`);
        for (var blk_height = 0; blk_height < chain_height; blk_height++) {
                let start_query = new Date();
                if (blk_height % 10 == 0) {
                    console.log(`Pulling block ${blk_height}...`);
                }
                const result_bytes = await this.Query('qscc', 'GetBlockByNumber', [this.channel_name, String(blk_height)] );
                // LOGGER.info(`Pull block ${blk_height} with ${result_bytes.length} bytes`);
                total_storage += result_bytes.length;

                let end_query = new Date();
                total_query_ms += end_query - start_query;

                let start_verify = new Date();
                const block = BlockDecoder.decode(result_bytes);

                for (var index = 0; index < block.data.data.length; index++) {
                    // var channel_header = block.data.data[index].payload.header.channel_header;
                    // LOGGER.info(`\t TxnID = ${channel_header.tx_id}`);
                    // TODO: may fail for some workloads. 
                    // this.InspectTxnRW(block.data.data[index].payload.data);
                }
                let end_verify = new Date();
                total_verification_ms += end_verify - start_verify;
        }
        var result = {};
        result[QUERY_DELAY_FIELD] = total_query_ms;
        result[VERIFY_DELAY_FIELD] = total_verification_ms;
        result[LEDGER_SIZE_FIELD] = total_storage;
        result[LEDGER_HEIGHT_FIELD] = chain_height;

        return result;
    }
}

module.exports.FabricFront = FabricFront;

class MockFabricFront {
    constructor(profile_path, channel_name, mspId, cert_path, key_path) {
    }

    async InitNetwork() {
        LOGGER.info("Mock initing the network");
        return this;
    }

    // Invoke a state-modifying txn that undergoes consensus and validation. 
    async InvokeTxn(cc_id, func_name, args) {
        LOGGER.info(`Mock invoking ${cc_id} with function ${func_name} and args ${args}`);
        let rand_str = (Math.random() + 1).toString(36).substring(7);
        return rand_str;
    }

    // Query a chaincode state on a peer without undergoing the consensus
    async Query(cc_id, function_name, args) {
        return undefined;
    }

    // Inspect a txn's accessed value to mock the verification. 
    InspectTxnRW(txnData) {
        LOGGER.error("Not implemented...");
        process.exit(1)
    }

    async GetLedgerHeight() {
        return 0;
    }

    async GetTxnDataById(txn_id) {
        return undefined;
    }

    DecodeTxn(txn_bytes) {
        LOGGER.error("Not implemented...");
        process.exit(1)
    }

    async ScanLedgerForDelayStorage() {

        var total_query_ms = 0;
        var total_verification_ms = 0;
        var total_storage = 0;
        
        var result = {};
        result[QUERY_DELAY_FIELD] = total_query_ms;
        result[VERIFY_DELAY_FIELD] = total_verification_ms;
        result[LEDGER_SIZE_FIELD] = total_storage;
        result[LEDGER_HEIGHT_FIELD] = 0;

        return result;
    }
}

module.exports.MockFabricFront = MockFabricFront;
module.exports.QUERY_DELAY_FIELD = QUERY_DELAY_FIELD;
module.exports.VERIFY_DELAY_FIELD = VERIFY_DELAY_FIELD;
module.exports.LEDGER_SIZE_FIELD = LEDGER_SIZE_FIELD;
module.exports.LEDGER_HEIGHT_FIELD = LEDGER_HEIGHT_FIELD;
