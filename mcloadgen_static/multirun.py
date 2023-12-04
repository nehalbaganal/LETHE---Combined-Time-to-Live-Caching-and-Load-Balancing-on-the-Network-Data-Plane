#!/usr/bin/env python3
# Run mcloadgen_static multiple times and combine the results
# David Munstein @ NCS, March 2023
import sys
import os
import csv
import time
from datetime import datetime

RUNS = 6
OUT = './big.csv'

if len(sys.argv) != 5:
    print(f'Usage: {sys.argv[0]} <controller_delay_bandwidth> <alpha, 99=0.99, 0=uniform> <num objects> <num total requests>')
    exit()

alpha = int(sys.argv[2])
num_objects = sys.argv[3]
num_requests = sys.argv[4]
alpha_str = ('Alpha' + str(alpha)) if alpha else 'Uniform'

date_str = datetime.now().strftime('%d%m%Y')
test_folder_name = f'Test{date_str}_{sys.argv[1]}_{alpha_str}_{num_objects}_{num_requests}'

if not os.path.isdir(f'test/{test_folder_name}'):
    os.mkdir(f'test/{test_folder_name}')

filename = f'test/{test_folder_name}/results.csv'
raw_csv = f'test/{test_folder_name}/raw_data.csv'

print('Alpha:', f'0.{alpha}' if alpha > 0 else 'Uniform')

header = ['avg_response_time','avg_num_requests_per_sec', 'avg_num_cold_per_sec', 'avg_num_warm1_per_sec', 'avg_num_warm2_per_sec', 'avg_num_hot_per_sec', 'avg_num_db_response_per_sec', 'avg_num_cache2_per_sec', 'avg_num_cache3_per_sec', 'ratio_rate_cache2', 'ratio_rate_cache3', 'cache2_hit_rate', 'cache3_hit_rate']
with open(filename, 'w') as f:
     writer = csv.writer(f)
     writer.writerow(header)

fraw = open(raw_csv, 'w')
fraw.write('timestamp_us,request_id,response_time_us,is_hit,hotness,db_response,cache_id\n')

for i in range(RUNS):
    if alpha == 0:
        EXE = f'../mcloadgen_static/mcloadgen_static 10.0.0.4 2 {num_objects} {num_requests} {i} 0'
    else:
        EXE = f'../mcloadgen_static/mcloadgen_static 10.0.0.4 1 {num_objects} {num_requests} {i} {alpha}'
    os.system(EXE)
    run_filename = f'test/mclgs_results' + str(i) + '.csv'
    with open(run_filename) as f:
        f.readline()
        fraw.write(f.read())
        fraw.write('\n')
    EVA = '../mcloadgen_static/mcloadgen_evaluate.py ' + run_filename + ' ' + filename
    os.system(EVA)

    time.sleep(3)

# create average from all runs
values = []
with open(filename) as f:
    i = 0
    values = [0.0 for i in range(len(header))]
    f.readline()
    for l in f.readlines():
        for j, v in enumerate(l.split(',')):
            values[j] += float(v)
        i += 1
    for j in range(len(values)):
        values[j] = values[j] / i

with open(filename, 'w') as f:
    f.seek(0)
    f.write(','.join(header))
    f.write('\n')
    f.write(','.join(str(x) for x in values))
