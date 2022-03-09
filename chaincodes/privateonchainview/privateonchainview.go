/*
SPDX-License-Identifier: Apache-2.0
*/

package main

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// Persistant Data Structures:

// view_txns : [$view_name1 -> [$txn_id1, $txn_id2, ...], $view_name2->[]]

// view_predicates : [$view_name1 -> $predicate1, $view_name2 -> $predicate2]

// txn_privates : [$txn_id1 -> $secret_part1(encrpytion-based or hash based), $txn_id2 -> $secret_part2]

type PrivateOnChainView struct {
	contractapi.Contract
}

// Func RetrieveTxnIdsByView(viewName):
//     Return view_txns[view_name];
func (t *PrivateOnChainView) RetrieveTxnIdsByView(ctx contractapi.TransactionContextInterface, view_name string) string {
	var err error
	stub := ctx.GetStub()
	viewTxns := []string{}
	if viewTxnsData, err := stub.GetState("viewtxns_" + view_name); err != nil {
		return fmt.Sprintf("fail to retrieve view_txn_ids with err msg %s", err.Error())
	} else if err := json.Unmarshal(viewTxnsData, &viewTxns); err != nil {
		return fmt.Sprintf("fail to unmarshal view_txn_ids with err msg %s", err.Error())
	}
	var last_time_data []byte
	if last_time_data, err = stub.GetState("viewlastmerged_" + view_name); err != nil {
		return fmt.Sprintf("Fail to get the last unmerged time for view %s\n", view_name)
	}
	last_time_str := string(last_time_data)
	fmt.Println("========================================")
	fmt.Printf("RetrieveTxnIdsByView for %s\n", view_name)
	fmt.Printf("Before-merge Txns %s\n", viewTxns)
	fmt.Printf("Last merge time %s\n", last_time_str)

	if unmerged_txns, err := t.txns_from(ctx, view_name, last_time_str); err != nil {
		return fmt.Sprintf("Fail to get unmerged txns %s\n", view_name)
	} else {
		fmt.Printf("Unmerged Txns %s\n", unmerged_txns)
		viewTxns = append(viewTxns, unmerged_txns...)
	}

	if viewTxnsdata, err := json.Marshal(viewTxns); err != nil {
		return fmt.Sprintf("Fail to marshal view txns data")
	} else {
		return string(viewTxnsdata)
	}

}

// CreateView can be constrained to be called by view owner only.
// Refer to https://hyperledger-fabric.readthedocs.io/en/release-2.2/access_control.html
// Func CreateView(viewName, viewPredicate):
//     view_predicates[viewName] = viewPredicate;
//     view_txns[viewName] = [];
func (t *PrivateOnChainView) CreateView(ctx contractapi.TransactionContextInterface, viewName, viewPredicate, mergePeriod string) error {
	stub := ctx.GetStub()
	fmt.Printf("CreateView with viewName=[%s], viewPredicate=[%s]\n", viewName, viewPredicate)

	_ = stub.PutState("viewpredicate_"+viewName, []byte(viewPredicate))
	fmt.Printf("\tDB[%s]=[%s]\n", "viewpredicate_"+viewName, viewPredicate)

	empty_array_data, _ := json.Marshal([]string{})
	_ = stub.PutState("viewtxns_"+viewName, empty_array_data)

	now := time.Now()      // current local time
	nsec := now.UnixNano() // number of nanoseconds since January 1, 1970 UTC
	_ = stub.PutState("viewlastmerged_"+viewName, []byte(strconv.FormatInt(nsec, 10)))
	fmt.Printf("\tDB[%s]=[%s]\n", "viewlastmerged_"+viewName, strconv.FormatInt(nsec, 10))

	_ = stub.PutState("viewperiod_"+viewName, []byte(mergePeriod))

	return nil
}

const TxnPrvPrefix = "TxnPrv"

// Can be called by anyone.
// Func GetPrivateArg(txnID):
//     return txn_privates[txnID];
// func (t *PrivateOnChainView) GetPrivateArg(ctx contractapi.TransactionContextInterface, txnId, private_arg string) string {
// 	stub := ctx.GetStub()
// 	if val, err := stub.GetState(TxnPrvPrefix + txnId); err != nil {
// 		return ""
// 	} else {
// 		return string(val)
// 	}
// }

//Func InvokeTxn(txnID, pub_arg, private_arg):
//  private_arg is either hash protected, or encryption-protected.
//
//  txn_privates[txnId]=private_args
//  for viewName, viewPredicate in view_predicates:
//     if viewPredicate.satisfied(pub_arg, txnId):
//         view_txns[viewName].push(txnId);

func (t *PrivateOnChainView) InvokeTxn(ctx contractapi.TransactionContextInterface, pub_arg, private_arg string) error {
	fmt.Println("===========================================")
	fmt.Printf("InvokeTxn with pub_arg=[%s]\n", pub_arg)

	txnId := ctx.GetStub().GetTxID()
	stub := ctx.GetStub()

	_ = stub.PutState("pubarg", []byte(pub_arg))
	_ = stub.PutPrivateData("TwoPeerCollection", "secretkey", []byte(private_arg))

	view_predicates := map[string]string{} //viewName -> viewPredicate

	predicateIterator, err := stub.GetStateByRange("viewpredicate", "viewpredicatf")
	if err != nil {
		return fmt.Errorf("fail to get predicate iterator")
	}
	defer predicateIterator.Close()

	for predicateIterator.HasNext() {
		predicateEntry, err := predicateIterator.Next()
		if err != nil {
			return fmt.Errorf("fail to get predicate value")
		}
		rawPredicateKey := predicateEntry.Key
		view_name := strings.Split(rawPredicateKey, "_")[1]
		predicate := string(predicateEntry.Value)
		view_predicates[view_name] = predicate
	}

	for view_name, view_predicate := range view_predicates {
		fmt.Printf("ViewName=[%s], view_predicate=[%s]\n", view_name, view_predicate)
		if t.satisfy(pub_arg, view_predicate) {
			fmt.Printf("pub_arg=[%s], YES, INCLUDE TxnId %s\n", pub_arg, txnId)

			// viewTxns = append(viewTxns, txnId)
			// if marshalled, err := json.Marshal(viewTxns); err != nil {
			// 	return fmt.Errorf("fail to marshal view_txn_ids with err msg %s", err.Error())
			// } else if err := stub.PutState("viewtxns_"+view_name, marshalled); err != nil {
			// 	return fmt.Errorf("fail to update view_txn_ids with err msg %s", err.Error())
			// }
			// do real contracts here. Real txn logic happens here.
			if merged, err := t.check_to_merge(ctx, view_name, txnId); err != nil {
				return err
			} else if !merged {
				now := time.Now()      // current local time
				nsec := now.UnixNano() // number of nanoseconds since January 1, 1970 UTC
				viewTS := "viewTS_" + view_name + "_" + strconv.FormatInt(nsec, 10)
				stub.PutState(viewTS, []byte(txnId))
				fmt.Printf("Put [%s] = [%s]\n", viewTS, txnId)
			}

		} else {
			fmt.Printf("pub_arg=[%s], NO\n", pub_arg)
		}
	}

	return nil
}

func (t *PrivateOnChainView) txns_from(ctx contractapi.TransactionContextInterface, view_name string, last_time_str string) ([]string, error) {
	stub := ctx.GetStub()
	viewTxns := []string{}

	startKey := "viewTS_" + view_name + "_" + last_time_str
	now := time.Now()      // current local time
	nsec := now.UnixNano() // number of nanoseconds since January 1, 1970 UTC
	endKey := "viewTS_" + view_name + "_" + strconv.FormatInt(nsec, 10)
	fmt.Printf("RangeScan between startKey = [%s], endKey= [%s]\n", startKey, endKey)
	txnIdIterator, err := stub.GetStateByRange(startKey, endKey)

	if err != nil {
		return nil, fmt.Errorf("fail to get predicate iterator")
	}
	defer txnIdIterator.Close()

	for txnIdIterator.HasNext() {
		if txnIdEntry, err := txnIdIterator.Next(); err != nil {
			return nil, fmt.Errorf("fail to get predicate value")
		} else {
			txnId := string(txnIdEntry.Value)
			// fmt.Printf("Recent TxnId=[%s]\n", txnId)
			viewTxns = append(viewTxns, txnId)
		}
	}
	return viewTxns, nil
}

func (t *PrivateOnChainView) check_to_merge(ctx contractapi.TransactionContextInterface, view_name string, txnID string) (bool, error) {
	fmt.Println("===========================================")
	fmt.Printf("CHECK TO MERGE\n")
	const THRESHOLD_SEC = 5
	stub := ctx.GetStub()
	var last_time_data []byte
	var err error

	if last_time_data, err = stub.GetState("viewlastmerged_" + view_name); err != nil {
		fmt.Printf("Fail to get the last unmerged time for view %s\n", view_name)
		return false, err
	}
	last_time_str := string(last_time_data)
	var last_time int64
	if last_time, err = strconv.ParseInt(last_time_str, 10, 64); err != nil {
		fmt.Printf("Fail to parse the last unmerged time %d for view %s\n", last_time_str, view_name)
		return false, err
	}
	var period_data []byte
	if period_data, err = stub.GetState("viewperiod_" + view_name); err != nil {
		fmt.Printf("Fail to get the merge period for view %s\n", view_name)
		return false, err
	}
	period_data_str := string(period_data)
	var period_sec int64
	if period_sec, err = strconv.ParseInt(period_data_str, 10, 64); err != nil {
		fmt.Printf("Fail to parse the merge period for view %s\n", view_name)

		return false, err
	}

	now := time.Now()      // current local time
	nsec := now.UnixNano() // number of nanoseconds since January 1, 1970 UTC
	if nsec-last_time > period_sec*1000*1000*1000 {

		viewTxns := []string{}
		if viewTxnsData, err := stub.GetState("viewtxns_" + view_name); err != nil {
			return false, fmt.Errorf(fmt.Sprintf("fail to retrieve view_txn_ids with err msg %s", err.Error()))
		} else if err := json.Unmarshal(viewTxnsData, &viewTxns); err != nil {
			return false, fmt.Errorf("fail to unmarshal view_txn_ids with err msg %s", err.Error())
		}

		if unmerged_txns, err := t.txns_from(ctx, view_name, last_time_str); err != nil {
			return false, err
		} else {
			viewTxns = append(viewTxns, unmerged_txns...)
		}
		viewTxns = append(viewTxns, txnID)

		// viewTxns = append(viewTxns, txnId)
		if marshalled, err := json.Marshal(viewTxns); err != nil {
			return false, fmt.Errorf("fail to marshal view_txn_ids with err msg %s", err.Error())
		} else if err := stub.PutState("viewtxns_"+view_name, marshalled); err != nil {
			return false, fmt.Errorf("fail to update view_txn_ids with err msg %s", err.Error())
		}

		_ = stub.PutState("viewlastmerged_"+view_name, []byte(strconv.FormatInt(nsec, 10)))
		fmt.Printf("\tDB[%s]=[%s]\n", "viewlastmerged_"+view_name, strconv.FormatInt(nsec, 10))

		return true, nil
	} else {
		fmt.Printf("The last merged time %d is within threshold %d sec compared to the current time %d", last_time, THRESHOLD_SEC, nsec)
		return false, nil
	}

}

// view inclusion logic.
func (t *PrivateOnChainView) satisfy(pub_arg string, predicate string) bool {
	if pub_arg == "ALL" {
		return true
	}
	satisified_views := strings.Split(pub_arg, "_")
	for _, s := range satisified_views {
		if s == predicate {
			return true
		}
	}
	return false
}

func main() {

	chaincode, err := contractapi.NewChaincode(new(PrivateOnChainView))

	if err != nil {
		fmt.Printf("Error create viewstorage chaincode: %s", err.Error())
		return
	}

	if err := chaincode.Start(); err != nil {
		fmt.Printf("Error starting viewstorage chaincode: %s", err.Error())
	}
}

// Analysis:
// Soundness (Case I): the view validation is achieved by smart contracts, which must undergo the consensus from the majority.

// Soundness (Case II): the user can pull the private args, either hash protected or encrpytion-protected, to validate the secret data is tamper-free.

// Completeness (Case III): subject to view owners InvokeTxn or not.
//   Can not force owners to invoke,
//   client T > Blockchain (InvokeTxn)

// Nothing is missing.
// If Txn T satisfies View V by definitions, then V must include T.
// Can be tested by any one, as the ledger is public auditable, except that it is inefficient.
