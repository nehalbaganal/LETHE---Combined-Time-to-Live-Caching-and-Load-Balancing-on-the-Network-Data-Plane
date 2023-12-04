#!/usr/bin/env python3
# Evaluation of mcloadgen_static results csv file
# David Munstein @ NCS, March 2023

#from dataclasses import dataclass
from typing import List
import csv
import numpy as np
import sys

filename = sys.argv[1]
writefile = sys.argv[2]

RESULTS_FILE = filename #'./mclgs_results0.csv'


#@dataclass
class ResultsObject:
    """ Stores the test results. Multiple objects may be created for individual time intervals """
    num_requests = 0
    sum_response_time_us = 0
    num_hits = 0
    num_cold = 0
    num_warm1 = 0
    num_warm2 = 0
    num_hot = 0
    num_db_response = 0
    num_cache_2 = 0  # total no. requests sent to cache 2
    num_cache_3 = 0  # total no. requests sent to cache 2
    num_cache_2_miss = 0  # no. requests sent to cache 2, but responded by database
    num_cache_3_miss = 0  # no. requests sent to cache 3, but responded by database
    num_db_cold = 0
    num_db_noncold = 0
    min_response_time_us = 100000000
    max_response_time_us = 0


def parse_results() -> List[ResultsObject]:
    """ Parses the results and returns a List of ResultObject """
    results_per_second = {}

    f = open(RESULTS_FILE)
    f.readline()  # get rid of column headers
    for l in f.readlines():
        timestamp_us = int(l.split(',')[0])
        request_id = int(l.split(',')[1])
        response_time_us = int(l.split(',')[2])
        is_hit = bool(l.split(',')[3])
        hotness = int(l.split(',')[4])
        db_response = bool(int(l.split(',')[5]))
        cache_id = int(l.split(',')[6])

        second = int(timestamp_us / 1000000)
        r: ResultsObject = results_per_second.setdefault(second, ResultsObject())
        r.num_requests += 1
        r.sum_response_time_us += response_time_us
        r.num_hits += 1 if is_hit else 0
        if hotness == 0: r.num_cold += 1
        elif hotness == 1: r.num_warm1 += 1
        elif hotness == 2: r.num_hot += 1
        elif hotness == 3: r.num_warm2 += 1
        r.num_db_response += 1 if db_response else 0
        if cache_id == 2: r.num_cache_2 += 1
        elif cache_id == 3: r.num_cache_3 += 1
        if db_response and cache_id == 2: r.num_cache_2_miss += 1
        elif db_response and cache_id == 3: r.num_cache_3_miss += 1
        if db_response and hotness == 0: r.num_db_cold += 1
        if db_response and hotness != 0: r.num_db_noncold += 1
        r.min_response_time_us = min(r.min_response_time_us, response_time_us)
        r.max_response_time_us = max(r.max_response_time_us, response_time_us)

    return results_per_second


def plot_cache_utilization(results):
    import matplotlib.pyplot as plt
    import numpy as np

    x = np.arange(0, len(results), 1)
    dcy = []
    dhy = []
    c2y = []
    c3y = []
    for r in results.values():
        dcy.append(r.num_db_cold)
        dhy.append(r.num_db_noncold)
        c2y.append(r.num_cache_2)
        c3y.append(r.num_cache_3)
    y = np.vstack([dcy, dhy, c2y, c3y])

    fig, ax = plt.subplots()
    ax.stackplot(x, y, labels=['Database (COLD)', 'Database (non-COLD)', 'Cache 2', 'Cache 3']) # colors=['#4073FF', '#808080', '#FF9933', '#DB4035']
    ax.set_title('Origin of a response over time')
    ax.legend(title='Response Origin', loc='lower right')
    plt.show()


if __name__ == '__main__':
    results = parse_results()
    num_requests = []
    num_cold = []
    num_warm1 = []
    num_warm2 = []
    num_hot = []
    num_db_response = []
    num_cache2 = []
    num_cache3 = []
    response_time = []

    avg_num_requests = 0
    avg_num_cold = 0
    avg_num_warm1 = 0
    avg_num_warm2 = 0
    avg_num_hot = 0
    avg_num_db_response = 0
    avg_num_cache2 = 0
    avg_num_cache3 = 0
    cache2_num_requests = 0
    cache3_num_requests = 0
    cache2_num_misses = 0
    cache3_num_misses = 0
    cache2_hit_rate = 0
    cache3_hit_rate = 0
    rate_cache2 = 0
    rate_cache3 = 0
    avg_response_time = 0
    results.pop(0) # to eliminate first two update intervals from the results as the it will only have results from database 
    results.pop(1)
    print('Req.\tCold\tWarm1\tWarm2\tHot\tDB\tCache2\tCache3\tC2Miss\tC3Miss\tTrsMin\tTrsMax')

    for r in results.values():
        print(r.num_requests, r.num_cold, r.num_warm1, r.num_warm2, r.num_hot, r.num_db_response, r.num_cache_2, r.num_cache_3, r.num_cache_2_miss, r.num_cache_3_miss, r.min_response_time_us, r.max_response_time_us, sep='\t')
        response_time.append(r.sum_response_time_us)
        num_requests.append(r.num_requests)
        num_cold.append(r.num_cold)
        num_warm1.append(r.num_warm1)
        num_warm2.append(r.num_warm2)
        num_hot.append(r.num_hot)
        num_db_response.append(r.num_db_response)
        num_cache2.append(r.num_cache_2)
        num_cache3.append(r.num_cache_3)
        cache2_num_requests += r.num_cache_2
        cache3_num_requests += r.num_cache_3
        cache2_num_misses += r.num_cache_2_miss
        cache3_num_misses += r.num_cache_3_miss

    avg_response_time = sum(response_time) / sum(num_requests)
    avg_num_requests = sum(num_requests) / len(num_requests)
    avg_num_cold = sum(num_cold) / len(num_cold)
    avg_num_warm1 = sum(num_warm1) / len(num_warm1)
    avg_num_warm2 = sum(num_warm2) / len(num_warm2)
    avg_num_hot = sum(num_hot) / len(num_hot)
    avg_num_db_response = sum(num_db_response) / len(num_db_response)
    avg_num_cache2 = sum(num_cache2) / len(num_cache2)
    avg_num_cache3 = sum(num_cache3) / len(num_cache3)
    ratio_rate_cache2 = (avg_num_cache2) / (avg_num_requests)
    ratio_rate_cache3 = avg_num_cache3 / (avg_num_requests)
    cache2_hit_rate = 0 if not cache2_num_requests else (cache2_num_requests - cache2_num_misses) / cache2_num_requests
    cache3_hit_rate = 0 if not cache3_num_requests else (cache3_num_requests - cache3_num_misses) / cache3_num_requests
    print("Average Num Requests = ", avg_num_requests)
    print("Average Num Cold = ", avg_num_cold)
    print("Average Num Warm1 = ", avg_num_warm1)
    print("Average Num Warm2 = ", avg_num_warm2)
    print("Average Num Hot = ", avg_num_hot)
    print("Average Num Cache 2 = ", avg_num_cache2)
    print("R2 = ", ratio_rate_cache2)
    print("R3 = ", ratio_rate_cache3)
    print("Hitrate Cache 2 = ", cache2_hit_rate)
    print("Hitrate Cache 3 = ", cache3_hit_rate)
    print("Average Response Time (us) = ", avg_response_time)

    data = [avg_response_time,avg_num_requests, avg_num_cold, avg_num_warm1, avg_num_warm2, avg_num_hot, avg_num_db_response, avg_num_cache2, avg_num_cache3, ratio_rate_cache2, ratio_rate_cache3, cache2_hit_rate, cache3_hit_rate]

    with open(writefile, 'a') as f:
        writer = csv.writer(f)
        writer.writerow(data)
