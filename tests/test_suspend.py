#!/usr/bin/env python
# Copyright 2016-2021 XMOS LIMITED.
# This Software is subject to the terms of the XMOS Public Licence: Version 1.

import xmostest
import usb_packet
from helpers import do_usb_test, RunUsbTest
from usb_session import UsbSession
from usb_transaction import UsbTransaction
from usb_signalling import UsbSuspend

def do_test(arch, clk, phy, data_valid_count, usb_speed, seed, verbose=False):
   
    ep = 1
    address = 1
    start_length = 10
    end_length = 12
    
    session = UsbSession(bus_speed=usb_speed, run_enumeration=False, device_address = address)
   
    pktLength = 10
    session.add_event(UsbTransaction(session, deviceAddress=address, endpointNumber=ep, endpointType="BULK", direction= "OUT", dataLength=pktLength, interEventDelay=0))
    session.add_event(UsbSuspend(500000000000))
    session.add_event(UsbResume())

    #for pktLength in range(start_length, end_length+1):
    
     #   if pktLength == start_length + 2:
     #       session.add_event(UsbSuspend(500000000000))


    do_usb_test(arch, clk, phy, usb_speed, [session], __file__, seed, level='smoke', extra_tasks=[], verbose=verbose)

def runtest():
    RunUsbTest(do_test)
