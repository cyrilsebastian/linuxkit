.PHONY: default all
default: bin/moby bin/linuxkit 
all: default

VERSION="0.0" # dummy for now
GIT_COMMIT=$(shell git rev-list -1 HEAD)

GO_COMPILE=linuxkit/go-compile:5bf17af781df44f07906099402680b9a661f999b

MOBY?=bin/moby
LINUXKIT?=bin/linuxkit
GOOS=$(shell uname -s | tr '[:upper:]' '[:lower:]')
GOARCH=amd64
ifneq ($(GOOS),linux)
CROSS=-e GOOS=$(GOOS) -e GOARCH=$(GOARCH)
endif

PREFIX?=/usr/local/

MOBY_COMMIT=d504afe4795528920ef06af611efd27b74098d5e
bin/moby: | bin
	docker run --rm --log-driver=none $(CROSS) $(GO_COMPILE) --clone-path github.com/moby/tool --clone https://github.com/moby/tool.git --commit $(MOBY_COMMIT) --package github.com/moby/tool/cmd/moby --ldflags "-X main.GitCommit=$(GIT_COMMIT) -X main.Version=$(VERSION)" -o $@ > tmp_moby_bin.tar
	tar xf tmp_moby_bin.tar > $@
	rm tmp_moby_bin.tar
	touch $@

LINUXKIT_DEPS=$(wildcard src/cmd/linuxkit/*.go) Makefile vendor.conf
bin/linuxkit: $(LINUXKIT_DEPS) | bin
	tar cf - vendor -C src/cmd/linuxkit . | docker run --rm --net=none --log-driver=none -i $(CROSS) $(GO_COMPILE) --package github.com/linuxkit/linuxkit --ldflags "-X main.GitCommit=$(GIT_COMMIT) -X main.Version=$(VERSION)" -o $@ > tmp_linuxkit_bin.tar
	tar xf tmp_linuxkit_bin.tar > $@
	rm tmp_linuxkit_bin.tar
	touch $@

test-initrd.img: $(MOBY) test/test.yml
	$(MOBY) build --pull test/test.yml

test-bzImage: test-initrd.img

.PHONY: test-qemu-efi
test-qemu-efi: $(LINUXKIT) test-efi.iso
	$(LINUXKIT) run qemu test | tee test-efi.log
	$(call check_test_log, test-efi.log)

bin:
	mkdir -p $@

install:
	cp -R ./bin/* $(PREFIX)/bin

define check_test_log
	@cat $1 |grep -q 'test suite PASSED'
endef

.PHONY: test-hyperkit
test-hyperkit: $(LINUXKIT) test-initrd.img test-bzImage test-cmdline
	rm -f disk.img
	$(LINUXKIT) run hyperkit test | tee test.log
	$(call check_test_log, test.log)

.PHONY: test-gcp
test-gcp: export CLOUDSDK_IMAGE_NAME?=test
test-gcp: $(LINUXKIT) test.img.tar.gz
	$(LINUXKIT) push gcp test.img.tar.gz
	$(LINUXKIT) run gcp $(CLOUDSDK_IMAGE_NAME) | tee test-gcp.log
	$(call check_test_log, test-gcp.log)

.PHONY: test
test: $(LINUXKIT) test-initrd.img test-bzImage test-cmdline
	$(LINUXKIT) run test | tee test.log
	$(call check_test_log, test.log)

test-ltp.img.tar.gz: $(MOBY) test/ltp/test-ltp.yml
	$(MOBY) build --pull test/ltp/test-ltp.yml

.PHONY: test-ltp
test-ltp: export CLOUDSDK_IMAGE_NAME?=test-ltp
test-ltp: $(LINUXKIT) artifacts/test-ltp.img.tar.gz
	$(LINUXKIT) push gcp artifacts/test-ltp.img.tar.gz
	$(LINUXKIT) run gcp -skip-cleanup -machine n1-highcpu-4 $(CLOUDSDK_IMAGE_NAME) | tee test-ltp.log
	$(call check_test_log, test-ltp.log)

artifacts:
	mkdir -p $@

artifacts/test.img.tar.gz: test.img.tar.gz | artifacts
	cp test.img.tar.gz artifacts/

artifacts/test-ltp.img.tar.gz: test-ltp.img.tar.gz | artifacts
	cp test-ltp.img.tar.gz artifacts/

.PHONY: collect-artifacts
collect-artifacts: artifacts/test.img.tar.gz artifacts/test-ltp.img.tar.gz

.PHONY: ci ci-tag ci-pr
ci:
	$(MAKE) clean
	$(MAKE)
	$(MAKE) test
	$(MAKE) collect-artifacts
	$(MAKE) test-ltp

ci-tag:
	$(MAKE) clean
	$(MAKE)
	$(MAKE) test
	$(MAKE) collect-artifacts
	$(MAKE) test-ltp

ci-pr:
	$(MAKE) clean
	$(MAKE)
	$(MAKE) test
	$(MAKE) artifacts/test.img.tar.gz

.PHONY: clean
clean:
	rm -rf bin *.log *-kernel *-cmdline *.img *.iso *.tar.gz *.qcow2 *.vhd *.vmx *.vmdk
