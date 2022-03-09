/*
SPDX-License-Identifier: Apache-2.0
*/

package main

import (
	"fmt"

	"github.com/hyperledger/fabric-contract-api-go/contractapi"
)

type Noop struct {
	contractapi.Contract
}

func (t *Noop) CreateView(ctx contractapi.TransactionContextInterface, viewName, viewPredicate, mergePeriod string) error {
	return nil
}

func (t *Noop) InvokeTxn(ctx contractapi.TransactionContextInterface, pub_arg, private_arg string) error {
	return nil
}

func main() {

	chaincode, err := contractapi.NewChaincode(new(Noop))

	if err != nil {
		fmt.Printf("Error create viewstorage chaincode: %s", err.Error())
		return
	}

	if err := chaincode.Start(); err != nil {
		fmt.Printf("Error starting viewstorage chaincode: %s", err.Error())
	}
}
