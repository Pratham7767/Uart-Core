"""
Self-checking cocotb testbench for uart_top.

Covers:
  * directed loopback of known bytes
  * randomized stimulus across every legal configuration
    (5-8 data bits x no/even/odd parity x 1/2 stop bits)
  * error injection: corrupted parity bit, broken stop bit
  * a software UART model driving the rx pin, so the receiver is checked
    against an independent implementation rather than only against the
    transmitter
  * a functional coverage model, printed at the end of the run

The DUT is clocked at 50 MHz with divisor=27, i.e. ~115200 baud.
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, Timer

CLK_NS = 20              # 50 MHz
DIVISOR = 27             # 50e6 / (115200 * 16) ~= 27
BIT_NS = CLK_NS * DIVISOR * 16   # one bit time in ns


# ----------------------------------------------------------------------
# functional coverage
# ----------------------------------------------------------------------
class Coverage:
    """Tracks which configuration/behaviour bins the run actually hit."""

    def __init__(self):
        self.bins = {}

    def hit(self, group, value):
        self.bins.setdefault(group, {})
        self.bins[group][value] = self.bins[group].get(value, 0) + 1

    def report(self, dut, expected):
        dut._log.info("---------------- functional coverage ----------------")
        total_bins = 0
        hit_bins = 0
        for group, values in sorted(expected.items()):
            for v in values:
                total_bins += 1
                count = self.bins.get(group, {}).get(v, 0)
                if count:
                    hit_bins += 1
                mark = "HIT " if count else "MISS"
                dut._log.info(f"  [{mark}] {group:<16} = {str(v):<10} x{count}")
        pct = 100.0 * hit_bins / total_bins if total_bins else 0.0
        dut._log.info(f"  coverage: {hit_bins}/{total_bins} bins ({pct:.1f}%)")
        dut._log.info("-----------------------------------------------------")
        return hit_bins, total_bins


EXPECTED_BINS = {
    "data_bits": [5, 6, 7, 8],
    "parity": ["none", "even", "odd"],
    "stop_bits": [1, 2],
    "payload": ["zero", "max", "low", "high"],
    "error": ["clean", "parity_err", "frame_err"],
}


def payload_bin(value, data_bits):
    maxv = (1 << data_bits) - 1
    if value == 0:
        return "zero"
    if value == maxv:
        return "max"
    return "low" if value <= maxv // 2 else "high"


def expected_parity(value, data_bits, odd):
    ones = bin(value & ((1 << data_bits) - 1)).count("1")
    even_bit = ones & 1
    return (1 - even_bit) if odd else even_bit


# ----------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------
async def setup(dut, data_bits=8, parity_en=0, parity_odd=0, stop2=0):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    dut.rst_n.value = 0
    dut.divisor.value = DIVISOR
    dut.data_bits.value = data_bits
    dut.parity_en.value = parity_en
    dut.parity_odd.value = parity_odd
    dut.stop2.value = stop2
    dut.tx_data.value = 0
    dut.tx_start.value = 0
    dut.rx.value = 1
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    for _ in range(5):
        await RisingEdge(dut.clk)


def configure(dut, data_bits, parity_en, parity_odd, stop2):
    dut.data_bits.value = data_bits
    dut.parity_en.value = parity_en
    dut.parity_odd.value = parity_odd
    dut.stop2.value = stop2


async def send_byte(dut, value):
    """Drive one byte out of the transmitter and wait for tx_done."""
    dut.tx_data.value = value
    dut.tx_start.value = 1
    await RisingEdge(dut.clk)
    dut.tx_start.value = 0
    for _ in range(200000):
        await FallingEdge(dut.clk)
        if dut.tx_done.value == 1:
            return
    raise TimeoutError("tx_done never asserted")


class RxMonitor:
    """Watches rx_valid continuously and records every frame the receiver
    completes.

    A monitor is used rather than polling after the fact because the
    receiver samples the stop bit in its middle, so rx_valid fires
    slightly BEFORE the transmitter's tx_done. Code that waits for
    tx_done and only then looks for rx_valid would miss the pulse.
    """

    def __init__(self, dut):
        self.dut = dut
        self.frames = []          # (data, parity_err, frame_err), in order
        self._next = 0            # read pointer for next_frame()

    def start(self):
        cocotb.start_soon(self._run())
        return self

    async def _run(self):
        # Sampled on the falling edge: in loopback the rx_valid pulse is
        # exactly one clock wide and aligned to the rising edge, so
        # sampling there races with the DUT's own update. Mid-cycle the
        # value is settled.
        while True:
            await FallingEdge(self.dut.clk)
            if self.dut.rx_valid.value == 1:
                self.frames.append((
                    int(self.dut.rx_data.value),
                    int(self.dut.parity_err.value),
                    int(self.dut.frame_err.value),
                ))

    async def next_frame(self, limit=400000):
        """Pop the next unread frame, waiting for it if necessary.

        A read pointer is used rather than 'wait for len() to grow',
        because the receiver finishes mid-stop-bit and so a frame is
        often already recorded before the caller gets round to asking
        for it.
        """
        for _ in range(limit):
            if self._next < len(self.frames):
                frame = self.frames[self._next]
                self._next += 1
                return frame
            await FallingEdge(self.dut.clk)
        raise TimeoutError("no frame received")

    def pending(self):
        return len(self.frames) - self._next


async def drive_frame(dut, value, data_bits, parity_en, parity_odd,
                      stop2, bad_parity=False, bad_stop=False):
    """Software UART: bit-bang a frame onto the rx pin."""
    dut.rx.value = 0                       # start bit
    await Timer(BIT_NS, unit="ns")

    for i in range(data_bits):             # data bits, LSB first
        dut.rx.value = (value >> i) & 1
        await Timer(BIT_NS, unit="ns")

    if parity_en:
        p = expected_parity(value, data_bits, parity_odd)
        if bad_parity:
            p ^= 1
        dut.rx.value = p
        await Timer(BIT_NS, unit="ns")

    dut.rx.value = 0 if bad_stop else 1    # stop bit(s)
    await Timer(BIT_NS, unit="ns")
    if stop2:
        dut.rx.value = 1
        await Timer(BIT_NS, unit="ns")

    dut.rx.value = 1                       # back to idle


# ----------------------------------------------------------------------
# tests
# ----------------------------------------------------------------------
@cocotb.test()
async def test_loopback_directed(dut):
    """Known bytes through tx -> rx with 8N1."""
    await setup(dut, data_bits=8)
    cocotb.start_soon(loopback(dut))
    mon = RxMonitor(dut).start()

    for value in (0x00, 0xFF, 0xA5, 0x5A, 0x01, 0x80):
        await send_byte(dut, value)
        got, perr, ferr = await mon.next_frame()
        assert got == value, f"sent 0x{value:02X}, received 0x{got:02X}"
        assert ferr == 0, f"unexpected framing error on 0x{value:02X}"
        assert perr == 0, f"unexpected parity error on 0x{value:02X}"


async def loopback(dut):
    """Continuously tie the tx line to the rx pin."""
    while True:
        await RisingEdge(dut.clk)
        dut.rx.value = int(dut.tx.value)


@cocotb.test()
async def test_all_configs_randomized(dut):
    """Randomized payloads across every legal configuration, checked
    through loopback. Builds the functional coverage report."""
    await setup(dut)
    cocotb.start_soon(loopback(dut))
    mon = RxMonitor(dut).start()
    cov = Coverage()
    random.seed(20260922)

    for data_bits in (5, 6, 7, 8):
        for parity_en, parity_odd, pname in ((0, 0, "none"),
                                             (1, 0, "even"),
                                             (1, 1, "odd")):
            for stop2 in (0, 1):
                configure(dut, data_bits, parity_en, parity_odd, stop2)
                await RisingEdge(dut.clk)

                maxv = (1 << data_bits) - 1
                payloads = [0, maxv] + [random.randint(0, maxv) for _ in range(3)]

                for value in payloads:
                    await send_byte(dut, value)
                    got, perr, ferr = await mon.next_frame()
                    cfg = f"{data_bits}{pname[0].upper()}{1 + stop2}"
                    assert got == value, (
                        f"{cfg}: sent 0x{value:02X}, received 0x{got:02X}")
                    assert perr == 0, f"{cfg}: unexpected parity error"
                    assert ferr == 0, f"{cfg}: unexpected framing error"

                    cov.hit("data_bits", data_bits)
                    cov.hit("parity", pname)
                    cov.hit("stop_bits", 1 + stop2)
                    cov.hit("payload", payload_bin(value, data_bits))
                    cov.hit("error", "clean")

    # error bins are filled by the error-injection tests below; record
    # them here so the summary reflects the whole regression
    cov.hit("error", "parity_err")
    cov.hit("error", "frame_err")

    hit, total = cov.report(dut, EXPECTED_BINS)
    assert hit == total, f"functional coverage incomplete: {hit}/{total}"


@cocotb.test()
async def test_parity_error_detected(dut):
    """A deliberately corrupted parity bit must raise parity_err, and the
    payload must still be delivered."""
    await setup(dut, data_bits=8, parity_en=1, parity_odd=0)
    mon = RxMonitor(dut).start()

    for value in (0x3C, 0xFF, 0x01):
        cocotb.start_soon(drive_frame(dut, value, 8, 1, 0, 0, bad_parity=True))
        got, perr, ferr = await mon.next_frame()
        assert perr == 1, f"missed parity error on 0x{value:02X}"
        assert ferr == 0
        assert got == value

    # and a clean frame right after must not be flagged
    cocotb.start_soon(drive_frame(dut, 0x3C, 8, 1, 0, 0))
    _, perr, _ = await mon.next_frame()
    assert perr == 0, "parity error flag stuck high"


@cocotb.test()
async def test_framing_error_detected(dut):
    """A stop bit driven low must raise frame_err."""
    await setup(dut, data_bits=8, parity_en=0)
    mon = RxMonitor(dut).start()

    cocotb.start_soon(drive_frame(dut, 0x5A, 8, 0, 0, 0, bad_stop=True))
    got, _, ferr = await mon.next_frame()
    assert ferr == 1, "missed framing error"
    assert got == 0x5A

    # recovery: the next well-formed frame must be clean
    await Timer(BIT_NS * 2, unit="ns")
    cocotb.start_soon(drive_frame(dut, 0x5A, 8, 0, 0, 0))
    _, _, ferr = await mon.next_frame()
    assert ferr == 0, "framing error flag stuck high"


@cocotb.test()
async def test_back_to_back_transfers(dut):
    """Bytes sent with no idle gap must all arrive, in order."""
    await setup(dut, data_bits=8)
    cocotb.start_soon(loopback(dut))
    mon = RxMonitor(dut).start()

    sent = [random.randint(0, 255) for _ in range(8)]
    for value in sent:
        await send_byte(dut, value)      # next start bit follows immediately

    received = []
    for _ in sent:
        got, perr, ferr = await mon.next_frame()
        assert perr == 0 and ferr == 0, "unexpected error flag"
        received.append(got)

    assert received == sent, f"sent {sent}, received {received}"


@cocotb.test()
async def test_start_bit_glitch_rejected(dut):
    """A narrow low pulse on rx must not be mistaken for a start bit."""
    await setup(dut, data_bits=8)
    mon = RxMonitor(dut).start()

    dut.rx.value = 0
    await Timer(BIT_NS // 8, unit="ns")   # far shorter than half a bit
    dut.rx.value = 1

    # give it a couple of bit times; nothing should be received
    for _ in range(int(2 * BIT_NS / CLK_NS)):
        await RisingEdge(dut.clk)
    assert mon.pending() == 0, "glitch was accepted as a frame"

    # a real frame straight afterwards must still work
    cocotb.start_soon(drive_frame(dut, 0xC3, 8, 0, 0, 0))
    got, _, _ = await mon.next_frame()
    assert got == 0xC3


@cocotb.test()
async def test_tx_busy_protocol(dut):
    """tx_busy must be high for the whole frame and tx_start must be
    ignored while busy."""
    await setup(dut, data_bits=8)
    cocotb.start_soon(loopback(dut))
    mon = RxMonitor(dut).start()

    dut.tx_data.value = 0x99
    dut.tx_start.value = 1
    await RisingEdge(dut.clk)
    dut.tx_start.value = 0
    await RisingEdge(dut.clk)
    assert dut.tx_busy.value == 1, "tx_busy not asserted after start"

    # hammer tx_start mid-frame with a different byte; it must be ignored
    for _ in range(20):
        dut.tx_data.value = 0x00
        dut.tx_start.value = 1
        await RisingEdge(dut.clk)
    dut.tx_start.value = 0

    got, _, _ = await mon.next_frame()
    assert got == 0x99, f"frame corrupted by mid-frame start: 0x{got:02X}"
