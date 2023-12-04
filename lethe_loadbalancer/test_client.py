#!/bin/env python3
# Memcached Lethe Mk1 Load Balancer - Test Client
# Tests whether Lethe is working properly. The two keys should be forwarded to different caches.

import memcached_udp

HASH0_H2 = 'bbb2345bbbb356bbbbbbbbbbbbbbbbbbbbbbbbbbabaa'  # Hash: 0 -> Host h2
HASH1_H3 = 'bbb23454bbb356bbbbbbbbbbbbbbbbbbbbbbbbbbabaa'  # Hash: 1 -> Host h3

if __name__ == '__main__':
    c = memcached_udp.Client([('10.0.0.4',11212)])

    r = c.set(HASH0_H2, 'testvalue')
    r = c.get(HASH0_H2)
    print('Response using hash 0 (host 2): testvalue=', r)

    r = c.set(HASH1_H3, 'testvalue')
    r = c.get(HASH1_H3)
    print('Response using hash 1 (host 3): testvalue=', r)
