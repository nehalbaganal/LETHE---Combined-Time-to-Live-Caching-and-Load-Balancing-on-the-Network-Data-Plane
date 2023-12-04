#!/usr/bin/env python3
# Memcached Lethe Mk1 Load Balancer - Network init script

from p4utils.mininetlib.network_API import NetworkAPI

DELAY = 0
BW_CLIENT = 0
BW_CACHE = 0
BW_DATABASE = 0
MEMCACHED_EXE = '/home/sdnlab/Desktop/memcached/memcached -p 11211 -U 11212 -u sdnlab -vv'

net = NetworkAPI()

net.setLogLevel('info')
net.enableCli()

net.addP4Switch('s1', cli_input='s1-commands.txt')
net.setP4Source('s1', './p4src/mcdslb.p4')

net.addHost('h1')
net.addHost('h2')
net.addHost('h3')
net.addHost('h4')
net.addHost('h5')

net.addTask('h2', MEMCACHED_EXE)
net.addTask('h3', MEMCACHED_EXE)
net.addTask('h4', MEMCACHED_EXE)

net.addTask('s1', 'python3 ./controller.py s1')

net.addLink('s1', 'h1')
net.addLink('s1', 'h2')
net.addLink('s1', 'h3')
net.addLink('s1', 'h4')
net.addLink('s1', 'h5')

if BW_CLIENT:
    net.setBw('s1', 'h1', BW_CLIENT)
    net.setBw('s1', 'h5', BW_CLIENT)
if BW_CACHE:
    net.setBw('s1', 'h2', BW_CACHE)
    net.setBw('s1', 'h3', BW_CACHE)
if BW_DATABASE:
    net.setBw('s1', 'h4', BW_DATABASE)

if DELAY:
    net.setDelay('s1', 'h4', DELAY)

net.l2()

net.enableCpuPortAll()
net.enablePcapDumpAll()
net.enableLogAll()

net.startNetwork()
