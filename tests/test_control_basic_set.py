#!/usr/bin/env python
# Copyright 2016-2021 XMOS LIMITED.
# This Software is subject to the terms of the XMOS Public Licence: Version 1.
from usb_packet import (
    TokenPacket,
    TxDataPacket,
    RxDataPacket,
    TxHandshakePacket,
    RxHandshakePacket,
    USB_PID,
)
from helpers import do_usb_test, RunUsbTest
from usb_session import UsbSession
from usb_transaction import UsbTransaction


def do_test(arch, clk, phy, usb_speed, seed, verbose=False):

    ep = 0
    address = 1
    ied = 500

    session = UsbSession(
        bus_speed=usb_speed, run_enumeration=False, device_address=address
    )

    # SETUP transaction
    session.add_event(
        TokenPacket(
            pid=USB_PID["SETUP"],
            address=address,
            endpoint=ep,
        )
    )
    session.add_event(
        TxDataPacket(
            dataPayload=session.getPayload_out(ep, 8),
            pid=USB_PID["DATA0"],
        )
    )
    session.add_event(RxHandshakePacket())

    # OUT transaction
    # Note, quite big gap to avoid nak
    session.add_event(
        TokenPacket(
            pid=USB_PID["OUT"],
            address=address,
            endpoint=ep,
            interEventDelay=10000,
        )
    )
    session.add_event(
        TxDataPacket(
            dataPayload=session.getPayload_out(ep, 10),
            pid=USB_PID["DATA1"],
        )
    )
    session.add_event(RxHandshakePacket())

    # Expect 0 length IN transaction
    session.add_event(
        TokenPacket(
            pid=USB_PID["IN"], address=address, endpoint=ep, interEventDelay=ied
        )
    )
    session.add_event(RxDataPacket(dataPayload=[], pid=USB_PID["DATA1"]))
    session.add_event(TxHandshakePacket())

    return do_usb_test(
        arch,
        clk,
        phy,
        usb_speed,
        [session],
        __file__,
        seed,
        level="smoke",
        extra_tasks=[],
    )


def test_control_basic_set():
    for result in RunUsbTest(do_test):
        assert result
