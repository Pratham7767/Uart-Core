SIM ?= icarus
TOPLEVEL_LANG ?= verilog

VERILOG_SOURCES += $(PWD)/../rtl/baud_gen.v
VERILOG_SOURCES += $(PWD)/../rtl/uart_tx.v
VERILOG_SOURCES += $(PWD)/../rtl/uart_rx.v
VERILOG_SOURCES += $(PWD)/../rtl/uart_top.v

TOPLEVEL = uart_top
MODULE   = test_uart

include $(shell cocotb-config --makefiles)/Makefile.sim
