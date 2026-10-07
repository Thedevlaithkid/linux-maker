.PHONY: all rootfs kernel run clean help

all:
	@chmod +x build.sh
	@./build.sh all

rootfs:
	@chmod +x build.sh
	@./build.sh rootfs

kernel:
	@chmod +x build.sh
	@./build.sh kernel

run:
	@chmod +x build.sh
	@./build.sh run

clean:
	@chmod +x build.sh
	@./build.sh clean

help:
	@chmod +x build.sh
	@./build.sh help
