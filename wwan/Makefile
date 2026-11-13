# Out-of-tree build for the WWAN core module (wwan.ko)
# Usage:
#   make            # build wwan.ko
#   sudo make install
#   sudo modprobe wwan
#   make clean

obj-m := wwan.o
wwan-objs := wwan_core.o

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

install: all
	install -d /lib/modules/$(shell uname -r)/kernel/drivers/net/wwan
	install -m 644 wwan.ko /lib/modules/$(shell uname -r)/kernel/drivers/net/wwan/wwan.ko
	depmod -a

.PHONY: all clean install
