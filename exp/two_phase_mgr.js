
const LOGGER = require('loglevel');
//more docs here - https://github.com/pimterry/loglevel#documentation
LOGGER.setDefaultLevel('info');

class TwoPhaseTxnMgr {
    constructor(chaincodeID, view2chain) {
        this.chaincodeID = chaincodeID;
        this.view2chain = view2chain;
    }

    async InitNetworks() {
        var init_promises = [];
        for (var view_name in this.view2chain) {
            LOGGER.info(`Init the chain for view ${view_name}`);
            init_promises.push(this.view2chain[view_name].InitNetwork());
        }
        return Promise.all(init_promises).then(()=>{
            return this;
        });
    }

    async TwoPhaseCommit(view_names, reqID, req_secret) {
        var chains = [];
        for (var i = 0; i < view_names.length; i+=1) {
            let view_name = view_names[i];
            let chain = this.view2chain[view_name];

            if (chain === undefined) {
                LOGGER.error(`Fail to find the chain for view ${view_name}`);
            }
            chains.push(chain);
        }

        var prepare_reqs = [];
        chains.forEach((chain)=>{
            prepare_reqs.push(chain.InvokeTxn(this.chaincodeID, "Prepare", [reqID, req_secret]));
        });
        await Promise.all(prepare_reqs);

        var commit_reqs = [];
        chains.forEach((chain)=>{
            commit_reqs.push(chain.InvokeTxn(this.chaincodeID, "Commit", [reqID, req_secret]));
        });
        await Promise.all(commit_reqs);
    }

    async ScanLedgersForDelayStorage() {
        var scan_requests = [];
        for (var view_name in this.view2chain) {
            scan_requests.push(this.view2chain[view_name].ScanLedgerForDelayStorage());
        }
        return Promise.all(scan_requests).then((infos)=>{
            var result = {};
            var i = 0;
            for (var view_name in this.view2chain) {
                result[view_name] = infos[i];
                i+=1;
            }
            return result;
        });
    }
};
module.exports.TwoPhaseTxnMgr = TwoPhaseTxnMgr;