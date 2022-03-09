/*
SPDX-License-Identifier: Apache-2.0
*/

package main

import (
	"fmt"

	"github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// Persistant Data Structures:

// view_txns : [$view_name1 -> [$txn_id1, $txn_id2, ...], $view_name2->[]]

// view_predicates : [$view_name1 -> $predicate1, $view_name2 -> $predicate2]

// txn_privates : [$txn_id1 -> $secret_part1(encrpytion-based or hash based), $txn_id2 -> $secret_part2]

type PrivateOnly struct {
	contractapi.Contract
}

func (t *PrivateOnly) CreateView(ctx contractapi.TransactionContextInterface, viewName, viewPredicate, mergePeriod string) error {
	return nil
}

const TxnPrvPrefix = "TxnPrv"

// Can be called by anyone.
// Func GetPrivateArg(txnID):
//     return txn_privates[txnID];
// func (t *PrivateOnly) GetPrivateArg(ctx contractapi.TransactionContextInterface, txnId, private_arg string) string {
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

func (t *PrivateOnly) InvokeTxn(ctx contractapi.TransactionContextInterface, pub_arg, private_arg string) error {
	stub := ctx.GetStub()
	// _ = stub.PutState("secretkey", []byte(private_arg))
	_ = stub.PutPrivateData("TwoPeerCollection", "secretkey", []byte(private_arg))
	_ = stub.PutState("pubarg", []byte(pub_arg))
	return nil
}

func main() {

	chaincode, err := contractapi.NewChaincode(new(PrivateOnly))

	if err != nil {
		fmt.Printf("Error create viewstorage chaincode: %s", err.Error())
		return
	}

	if err := chaincode.Start(); err != nil {
		fmt.Printf("Error starting viewstorage chaincode: %s", err.Error())
	}
}
