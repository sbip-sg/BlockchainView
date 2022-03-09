/*
SPDX-License-Identifier: Apache-2.0
*/

package main

import (
	"encoding/json"
	"fmt"

	"github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// ViewStorage provides functions for managing a car
type ViewStorage struct {
	contractapi.Contract
}

func (t *ViewStorage) CreateView(ctx contractapi.TransactionContextInterface, viewName, viewContents string) error {
	return ctx.GetStub().PutState(viewName, []byte(viewContents))
}

func (t *ViewStorage) AppendView(ctx contractapi.TransactionContextInterface, viewName, viewContents string) error {
	stub := ctx.GetStub()
	prevView := map[string]interface{}{}
	if val, err := stub.GetState(viewName); err != nil {
		return fmt.Errorf("fail to get contents for View %s with error msg %s", viewName, err.Error())
	} else if val == nil {
		// do nothing
	} else if err := json.Unmarshal(val, &prevView); err != nil {
		return fmt.Errorf("fail to unmarshal previous View %s with err msg %s", viewName, err.Error())
	}

	appendedViewTxns := map[string]interface{}{}
	if err := json.Unmarshal([]byte(viewContents), &appendedViewTxns); err != nil {
		return fmt.Errorf("fail to unmarshal appended view contents %s with err msg %s", viewName, err)
	}

	// Merge appended view txns with the previous one.
	for k, v := range appendedViewTxns {
		prevView[k] = v
	}

	if val, err := json.Marshal(prevView); err != nil {
		return fmt.Errorf("fail to marshal current view contents with error msg %s", err.Error())
	} else if err := stub.PutState(viewName, val); err != nil {
		return fmt.Errorf("fail to update View %s", viewName)
	}
	return nil
}

func (t *ViewStorage) GetView(ctx contractapi.TransactionContextInterface, viewName string) (string, error) {
	stub := ctx.GetStub()
	if val, err := stub.GetState(viewName); err != nil {
		return "", fmt.Errorf("fail to get value for View %s", viewName)
	} else {
		return string(val), nil
	}
}

func main() {

	chaincode, err := contractapi.NewChaincode(new(ViewStorage))

	if err != nil {
		fmt.Printf("Error create viewstorage chaincode: %s", err.Error())
		return
	}

	if err := chaincode.Start(); err != nil {
		fmt.Printf("Error starting viewstorage chaincode: %s", err.Error())
	}
}
