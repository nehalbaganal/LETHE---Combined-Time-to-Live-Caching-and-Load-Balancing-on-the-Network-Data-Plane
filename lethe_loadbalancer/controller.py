#!/usr/bin/env python3
# Memcached Lethe Mk1 Load Balancer - Controller

# API docu https://nsg-ethz.github.io/p4-utils/p4utils.utils.thrift_API.html


import sys
import time
import os
from p4utils.utils.helper import load_topo
from p4utils.utils.sswitch_p4runtime_API import SimpleSwitchP4RuntimeAPI
from p4utils.utils.sswitch_thrift_API import SimpleSwitchThriftAPI
import threading

N_HOT = 1200         # Number of WARM/HOT objects to determine (may be higher due to hash collisions)
INTERVAL_T = 1      # Update interval in seconds (determine WARM/HOT, write to register each interval)
THRESHOLD_HOT = 30  # Threshold for objects to be classified HOT in requests per interval
aplha = 0.3

marker = 0

class LBController:
    marker = 0

    def __init__(self, sw_name):
        self.topo = load_topo('topology.json')
        self.sw_name = sw_name
        self.thrift_port = self.topo.get_thrift_port(sw_name)
        self.controller = SimpleSwitchThriftAPI(self.thrift_port)

        self.hot_objects = {}

    def test_get_data_from_register(self):
        """
        Test if reading data from register is working. Print status and content of register
        """
        data = self.controller.register_read('counterReg')
        #print(f'Lenght of "counterReg" register: {len(data)} entries')
        #print('Following entries of "coutnerReg" are not 0:')
        for i, d in enumerate(data):
            if d == 0:
                continue
            #print(i, '=>', d)

    def reset_thread(self):
        def _r_t(self):
             fifo_file = '/david.munstein/lethe-testing/lethe_fifo_c'
             if not os.path.exists(fifo_file):
                 os.mkfifo(fifo_file)
             with open(fifo_file) as f:
                 while True:
                     if 'reset' in f.readline():
                         print('Reset register "counterReg" and table "loadbal"')
                         self.controller.register_reset('counterReg')
                         self.controller.table_clear('loadbal')
                         for key in self.hot_objects:
                             self.hot_objects.pop(key)

             threading.Thread(target=_r_t, args=[self]).start()

    def test_update_loadbal_table(self):
        """
        Updates the loadbal table
        Maps the key(hash) to COLD(drop packet), WARM(hash-based lb) or HOT(tbd)
        """
        self.controller.table_add('loadbal', 'set_server_cold', ['15222'])  # In P4: Don't apply ECMP -> send to host h4
        #self.controller.table_modify_match('loadbal', 'set_server_warm', ['15222'])

    def routine_basic(self):
        global marker
        # Get current register entries as dict, sorted by request num ASC
        # Example: {12345: 50, 432: 60, 20000: 71}
        data = dict(enumerate(self.controller.register_read('counterReg')))
        data = dict(sorted(data.items(), key=lambda item: item[1]))
        alpha = 0.5
        counter = 0
        # Reset register
        self.controller.register_reset('counterReg')

        # Decrease populariy of old hot_objects
        to_pop = []
        for key in self.hot_objects:
            self.hot_objects[key] = int(self.hot_objects[key] * alpha)
            if self.hot_objects[key] == 0:
                to_pop.append(key)
        for key in to_pop:
            self.hot_objects.pop(key)

        # Add new hot objects to existing hot objects TODO
        n_hot_objects = N_HOT  # int(len(data.keys()) * 0.01)
        for key in list(data.keys())[-n_hot_objects:]:
            if data[key] == 0:
                continue
            if data[key] != 0:
                counter = counter + 1
            if key in self.hot_objects:
                self.hot_objects[key] += int(data[key] * (1-alpha))
            else:
                self.hot_objects[key] = int(data[key] * (1-aplha))

        #print("Counter = ", counter)
        #print("Marker = ", marker)

        if counter > 0:
            marker = 1
        elif counter == 0:
            if marker == 1:
                #python = sys.executable
                #os.execl(python, python, *sys.argv)
                print('Reset register "counterReg" and table "loadbal"')
                self.controller.register_reset('counterReg')
                self.controller.table_clear('loadbal')
                marker = 0

        print("Marker = ", marker)
        # Cut off hot objects list at 1.5*N_HOT objects
        stack1= []
        stack2= []
        hot_object = 0
        warm_object = 0
        self.hot_objects = dict(sorted(self.hot_objects.items(), key=lambda item: item[1]))
        max_n_hot_in_list = int(N_HOT) #1.5 * N_HOT
        if len(self.hot_objects) > max_n_hot_in_list:
            for key in list(self.hot_objects.keys())[-(len(self.hot_objects) - max_n_hot_in_list):]:
                self.hot_objects.pop(key)

        self.top_list = list(self.hot_objects.keys())[-100:]  # top 100 objects with the highest popularity

        self.controller.table_clear('loadbal')
        for key in self.hot_objects:
            if key in self.top_list: #key in list(self.hot_objects)[:500]: #[key] > THRESHOLD_HOT:
               self.controller.table_add('loadbal', 'set_server_hot', [str(key)])
               hot_object = hot_object + 1
                #print('table_add loadbal set_server_hot', key, '->', self.hot_objects[key])
            elif self.hot_objects[key] != 0:
                warm_object = warm_object + 1
                if sum(stack1) > sum(stack2):
                        stack2.append(self.hot_objects[key])
                        self.controller.table_add('loadbal', 'set_server_warm2', [str(key)])
                else:
                        stack1.append(self.hot_objects[key])
                        self.controller.table_add('loadbal', 'set_server_warm1', [str(key)])
                        #print('table_add loadbal set_server_warm', key, '->', self.hot_objects[key])
            else:
                continue
        print('Stack1:',sum(stack1))
        print('Stack2:',sum(stack2))
        print('Counter : ', counter)
        print("Hot Object :", hot_object)
        print("Warm Object :", warm_object)
        #print(self.hot_objects, '-', len(self.hot_objects))



if __name__ == '__main__':
    if len(sys.argv) != 2:
        print('Usage: ./controller.py <switch name>')
        exit(1)

    sw_name = sys.argv[1]
    #marker = 0
    lbc = LBController(sw_name)
    lbc.test_get_data_from_register()
    lbc.controller.register_reset('counterReg')
    lbc.test_update_loadbal_table()
    lbc.reset_thread()
    while True:
        print('---')
        lbc.routine_basic()
        time.sleep(INTERVAL_T)
