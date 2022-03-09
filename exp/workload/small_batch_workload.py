#!/usr/bin/python

 

import time
import sys
import random
import json

all_json = {"views": [], "blocks": []}


'''
' Simulates a supply chain
'''

 

# The nodes of the supply chain

nodes = [

    'manufacturer1', 

    'warehouse1', 'warehouse2',

    'delivery1', 

    'shop1', 'shop2', 'shop3'

]

 

# The edges of the supply chain

edges = [

    ('manufacturer1', 'warehouse1'),

    # ('manufacturer2', 'warehouse1'),

    ('warehouse1', 'delivery1'),

    # ('warehouse1', 'delivery2'),

    ('delivery1','warehouse2'),

    # ('delivery2', 'warehouse3'),

    ('warehouse2', 'shop1'),

    ('warehouse2', 'shop2'),

    ('warehouse2', 'shop3'),

    # ('warehouse2', 'shop4'),

    # ('warehouse2', 'shop5'),

    # ('warehouse3', 'shop4'),

    # ('warehouse3', 'shop5'),

    # ('warehouse3', 'shop6'),

    # ('warehouse3', 'shop7'),

]

 

roots = ['manufacturer1', 'manufacturer2']

 


total_view_req_count=0
view_req_counts = {}
# The total number of dispatched items

number_of_items = int(sys.argv[1])

 

# The number of transfers per block

items_per_block = int(sys.argv[2])

 

# Output file

output_file = 'supply_chain_transactions.txt'

PRINT_TO_FILE = True

PRINT_TO_OUTPUT = True

 

 

'''
' Printing the transaction
'''

def print_transaction(f, str):

 

    if PRINT_TO_FILE:

        f.write(str+'\n')

       

    if PRINT_TO_OUTPUT:

        print(str)

 

'''
' Creating the access-control views
'''

def create_views(f):

    print_transaction(f, 'CREATE TABLE DELIVERY (tid, item, from, to);')

    for v in nodes:
        all_json["views"].append(v)

        print_transaction(f, 'CREATE VIEW {} (tid);'.format(v))

 

 

def create_item_list():

 

    items = [(i, [], []) for i in range(number_of_items)]

    return items

 

'''
' Delivery of item from current node to next node
'''

def print_delivery(tid, item, _current, _next, f):
    global all_json

    print_transaction(f, 'INSERT INTO DELIVERY VALUES (tid: {}, item: {}, from: {}, to: {});'.format(tid, item[0], _current, _next))

    operation = {"op": "insert", "tid": tid, "item": item[0], "from": _current, "to": _next, "views":[]}

    for u in item[1]:
        operation["views"].append({"name": u, "tid": tid})
        print_transaction(f, '     ADD TO VIEW {} VALUES (tid: {});'.format(u, tid))
        global total_view_req_count
        total_view_req_count+=1
        global view_counts
        if u not in view_req_counts:
            view_req_counts[u] = 0
        view_req_counts[u]+=1


    item[2].append(tid)

    for t in item[2]:
        operation["views"].append({"name": _next, "tid": t})
        print_transaction(f, '     ADD TO VIEW {} VALUES (tid: {});'.format(_next, t))
        global total_view_req_count 
        total_view_req_count+=1
        global view_counts
        if _next not in view_req_counts:
            view_req_counts[_next] = 0
        view_req_counts[_next]+=1
    all_json["blocks"][-1].append(operation)

def main():

 

    start = time.time()

    print('Starting simulation')

 

    with open(output_file, 'w') as f_out:

 

        create_views(f_out)

        print('\n')

 

        tid = 1

 

        items = create_item_list()

       

        while items:

            # Select random items from the list of items

            n = min(items_per_block, len(items))

            rand_items = random.sample(items, n)

               

            start_block = True

 

            for item in rand_items:

                if not item[1]:

                    # Randomly select a root node as a starting point for the item delivery

                    root = random.choice(roots)

                    item[1].append(root)

               

                current_node = item[1][-1]

                options_for_next_node = [u for v, u in edges if v == current_node]

                if options_for_next_node:

                    if start_block:
                        all_json["blocks"].append([])
                        print_transaction(f_out, '\nSTART BLOCK')

                        start_block = False

                    next_node = random.choice(options_for_next_node)

                    print_delivery(tid, item, current_node, next_node, f_out)

                    item[1].append(next_node)

                    tid += 1

                else:

                    items.remove(item)

 

        end = time.time()
        with open("small_{}items_{}batchsize.json".format(number_of_items, items_per_block), 'w+') as f:
            print(json.dump(all_json, f, indent=4))
        print("\nTotal View Request:",total_view_req_count )
        print("\nView Request Count:",view_req_counts )
        print("\nRunning time: {:01f}\n".format(end-start))

 

if __name__ == "__main__":

                main()