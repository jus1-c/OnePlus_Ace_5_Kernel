CC ?= gcc
CFLAGS ?= -Wall -O2 -static
TARGET = nci_raw_tool

all: $(TARGET)

$(TARGET): nci_raw_tool.c
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f $(TARGET)

.PHONY: all clean
