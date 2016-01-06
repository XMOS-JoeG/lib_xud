#!/usr/bin/env python

import random
import xmostest
from  usb_packet import *
from usb_clock import Clock
from helpers import do_rx_test, packet_processing_time, get_dut_address
from helpers import choose_small_frame_size, check_received_packet, runall_rx

def do_test(arch, clk, phy, seed):
    
    rand = random.Random()
    rand.seed(seed)

    ep_loopback = 3
    ep_loopback_kill = 2

    # The inter-frame gap is to give the DUT time to print its output
    packets = []

    dataval = 0;
    data_pid = 0x3 #DATA0 

    for pkt_length in range(200, 204):
        
        AppendOutToken(packets, ep_loopback)
        packets.append(TxDataPacket(rand, data_start_val=dataval, length=pkt_length, pid=data_pid)) #DATA0
   
        #XXwas min IPG supported on iso loopback to not nak
        #This was 420, had to increase when moved to lib_xud (14.1.2 tools)
        AppendInToken(packets, ep_loopback, inter_pkt_gap=437)
        packets.append(RxDataPacket(rand, data_start_val=dataval, length=pkt_length, pid=data_pid, timeout=9)) #DATA0

        #No toggle for Iso

    pkt_length = 10

    #Loopback and die..
    AppendOutToken(packets, ep_loopback_kill)
    packets.append(TxDataPacket(rand, length=pkt_length, pid=3)) #DATA0
    packets.append(RxHandshakePacket())
   
    AppendInToken(packets, ep_loopback_kill, inter_pkt_gap=357)
    packets.append(RxDataPacket(rand, length=pkt_length, pid=3)) #DATA0
    packets.append(TxHandshakePacket())


    do_rx_test(arch, clk, phy, packets, __file__, seed,
               level='smoke', extra_tasks=[])

def runtest():
    random.seed(1)
    runall_rx(do_test)
