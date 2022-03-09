/*
SPDX-License-Identifier: Apache-2.0
*/

package main

import (
	"fmt"

	"github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// SecretContract provides functions for managing a car
type SecretContract struct {
	contractapi.Contract
}

func (t *SecretContract) InvokeTxn(ctx contractapi.TransactionContextInterface, pub_arg, private_arg string) error {
	stub := ctx.GetStub()
	txID := stub.GetTxID()

	if err := stub.PutState("secretkey", []byte(private_arg)); err != nil {
		return fmt.Errorf("fail to persist secret for %s", txID)
	}
	return nil
}

func main() {

	chaincode, err := contractapi.NewChaincode(new(SecretContract))

	if err != nil {
		fmt.Printf("Error create SecretContract chaincode: %s", err.Error())
		return
	}

	if err := chaincode.Start(); err != nil {
		fmt.Printf("Error starting SecretContract chaincode: %s", err.Error())
	}
}
