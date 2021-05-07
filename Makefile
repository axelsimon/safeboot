VERSION ?= 0.8

GIT_DIRTY := $(shell if git status -s >/dev/null ; then echo dirty ; else echo clean ; fi)
GIT_HASH  := $(shell git rev-parse HEAD)

BINS += bin/sbsign.safeboot
BINS += bin/sign-efi-sig-list.safeboot
BINS += bin/tpm2-totp
BINS += bin/tpm2

all: $(BINS) update-certs

#
# sbsign needs to be built from a patched version to avoid a
# segfault when using the PKCS11 engine to talk to the Yubikey.
#
SUBMODULES += sbsigntools
bin/sbsign.safeboot: sbsigntools/Makefile
	$(MAKE) -C $(dir $<)
	mkdir -p $(dir $@)
	cp $(dir $<)src/sbsign $@
sbsigntools/Makefile: sbsigntools/autogen.sh
	cd $(dir $@) ; ./autogen.sh && ./configure
sbsigntools/autogen.sh:
	git submodule update --init --recursive --recommend-shallow sbsigntools

#
# sign-efi-sig-list needs to be built from source to have support for
# the PKCS11 engine to talk to the Yubikey.
#
SUBMODULES += efitools
bin/sign-efi-sig-list.safeboot: efitools/Makefile
	$(MAKE) -C $(dir $<) sign-efi-sig-list
	mkdir -p $(dir $@)
	cp $(dir $<)sign-efi-sig-list $@
efitools/Makefile:
	git submodule update --init --recursive --recommend-shallow efitools

#
# tpm2-tss is the library used by tpm2-tools
#
SUBMODULES += tpm2-tss

libtss2-mu = tpm2-tss/src/tss2-mu/.libs/libtss2-mu.a
libtss2-rc = tpm2-tss/src/tss2-rc/.libs/libtss2-rc.a
libtss2-sys = tpm2-tss/src/tss2-sys/.libs/libtss2-sys.a
libtss2-esys = tpm2-tss/src/tss2-esys/.libs/libtss2-esys.a
libtss2-tcti = tpm2-tss/src/tss2-tcti/.libs/libtss2-tctildr.a

$(libtss2-esys): tpm2-tss/Makefile
	$(MAKE) -C $(dir $<)
	mkdir -p $(dir $@)
tpm2-tss/bootstrap:
	git submodule update --init --recursive --recommend-shallow $(dir $@)
tpm2-tss/Makefile: tpm2-tss/bootstrap
	cd $(dir $@) ; ./bootstrap && ./configure \
		--disable-doxygen-doc \

#
# tpm2-tools is the head after bundling and ecc support built in
#
SUBMODULES += tpm2-tools

tpm2-tools/bootstrap:
	git submodule update --init --recursive --recommend-shallow $(dir $@)
tpm2-tools/Makefile: tpm2-tools/bootstrap $(libtss2-esys)
	cd $(dir $@) ; ./bootstrap \
	&& ./configure \
		TSS2_RC_CFLAGS=-I../tpm2-tss/include \
		TSS2_RC_LIBS="../$(libtss2-rc)" \
		TSS2_MU_CFLAGS=-I../tpm2-tss/include \
		TSS2_MU_LIBS="../$(libtss2-mu)" \
		TSS2_SYS_CFLAGS=-I../tpm2-tss/include \
		TSS2_SYS_LIBS="../$(libtss2-sys)" \
		TSS2_TCTILDR_CFLAGS=-I../tpm2-tss/include \
		TSS2_TCTILDR_LIBS="../$(libtss2-tcti)" \
		TSS2_ESYS_3_0_CFLAGS=-I../tpm2-tss/include \
		TSS2_ESYS_3_0_LIBS="../$(libtss2-esys) -ldl" \

tpm2-tools/tools/tpm2: tpm2-tools/Makefile
	$(MAKE) -C $(dir $<)

bin/tpm2: tpm2-tools/tools/tpm2
	cp $< $@


#
# tpm2-totp is build from a branch with hostname support
#
SUBMODULES += tpm2-totp
bin/tpm2-totp: tpm2-totp/Makefile $(libtss2-esys)
	$(MAKE) -C $(dir $<)
	mkdir -p $(dir $@)
	cp $(dir $<)/tpm2-totp $@
tpm2-totp/bootstrap:
	git submodule update --init --recursive --recommend-shallow tpm2-totp
tpm2-totp/Makefile: tpm2-totp/bootstrap
	cd $(dir $@) ; ./bootstrap && ./configure \
		TSS2_MU_CFLAGS=-I../tpm2-tss/include \
		TSS2_MU_LIBS="../$(libtss2-mu)" \
		TSS2_TCTILDR_CFLAGS=-I../tpm2-tss/include \
		TSS2_TCTILDR_LIBS="../$(libtss2-tcti)" \
		TSS2_TCTI_DEVICE_LIBDIR="$(dir ../$(libtss2-tcti))" \
		TSS2_ESYS_CFLAGS=-I../tpm2-tss/include \
		TSS2_ESYS_LIBS="../$(libtss2-esys) ../$(libtss2-sys) -lssl -lcrypto -ldl" \

#
# swtpm and libtpms are used for simulating the qemu tpm2
#
SUBMODULES += libtpms
LIBTPMS_OUTPUT := libtpms/src/.libs/libtpms_tpm2.a
libtpms/autogen.sh:
	git submodule update --init --recursive --recommend-shallow $(dir $@)
libtpms/Makefile: libtpms/autogen.sh
	cd $(dir $@) ; ./autogen.sh --with-openssl --with-tpm2
$(LIBTPMS_OUTPUT): libtpms/Makefile
	$(MAKE) -C $(dir $<)

SUBMODULES += swtpm
SWTPM=swtpm/src/swtpm/swtpm
swtpm/autogen.sh:
	git submodule update --init --recursive --recommend-shallow $(dir $@)
swtpm/Makefile: swtpm/autogen.sh $(LIBTPMS_OUTPUT)
	cd $(dir $@) ; \
		LIBTPMS_LIBS="-L`pwd`/../libtpms/src/.libs -ltpms" \
		LIBTPMS_CFLAGS="-I`pwd`/../libtpms/include" \
		./autogen.sh \

$(SWTPM): swtpm/Makefile
	$(MAKE) -C $(dir $<)


#
# busybox for command line utilities
#
SUBMODULES += busybox
busybox/Makefile:
	git submodule update --init --recursive --recommend-shallow $(dir $@)
busybox/.configured: initramfs/busybox.config busybox/Makefile
	cp $< $(dir $@).config
	$(MAKE) -C $(dir $@) oldconfig
	touch $@
busybox/busybox: busybox/.configured
	$(MAKE) -C $(dir $<)
bin/busybox: busybox/busybox
	mkdir -p $(dir $@)
	cp $(dir $<)/busybox $@

#
# Linux kernel for the PXE boot image
#
LINUX		:= linux-5.10.35
LINUX_TAR	:= $(LINUX).tar.xz
LINUX_SIG	:= $(LINUX).tar.sign
LINUX_URL	:= https://cdn.kernel.org/pub/linux/kernel/v5.x/$(LINUX_TAR)

$(LINUX_TAR):
	[ -r $@.tmp ] || wget -O $@.tmp $(LINUX_URL)
	[ -r $(LINUX_SIG) ] || wget -nc $(dir $(LINUX_URL))/$(LINUX_SIG)
	#unxz -cd < $@.tmp | gpg2 --verify $(LINUX_SIG) -
	mv $@.tmp $@

$(LINUX): $(LINUX)/.patched
$(LINUX)/.patched: $(LINUX_TAR)
	tar xf $(LINUX_TAR)
	touch $@

build/vmlinuz: build/$(LINUX)/.config build/initrd.cpio
	$(MAKE) \
		KBUILD_HOST=safeboot \
		KBUILD_BUILD_USER=builder \
		KBUILD_BUILD_TIMESTAMP="$(GIT_HASH)" \
		KBUILD_BUILD_VERSION="$(GIT_DIRTY)" \
		-C $(dir $<)
	cp $(dir $<)/arch/x86/boot/bzImage $@

build/$(LINUX)/.config: initramfs/linux.config | $(LINUX)
	mkdir -p $(dir $@)
	cp $< $@
	$(MAKE) \
		-C $(LINUX) \
		O=$(PWD)/$(dir $@) \
		olddefconfig

linux-menuconfig: build/$(LINUX)/.config
	$(MAKE) -j1 -C $(dir $<) menuconfig savedefconfig
	cp $(dir $<)defconfig initramfs/linux.config

#
# Extra package building requirements
#
requirements:
	DEBIAN_FRONTEND=noninteractive \
	apt install -y \
		devscripts \
		debhelper \
		libqrencode-dev \
		efitools \
		gnu-efi \
		opensc \
		yubico-piv-tool \
		libengine-pkcs11-openssl \
		build-essential \
		binutils-dev \
		git \
		pkg-config \
		automake \
		autoconf \
		autoconf-archive \
		initramfs-tools \
		help2man \
		libssl-dev \
		uuid-dev \
		shellcheck \
		curl \
		libjson-c-dev \
		libcurl4-openssl-dev \
		expect \
		socat \
		libseccomp-dev \
		seccomp \
		gnutls-bin \
		libgnutls28-dev \
		libtasn1-6-dev \
		ncurses-dev \
		qemu-utils \
		qemu-system-x86 \
		gnupg2 \
		flex \
		bison \
		libelf-dev \


# Remove the temporary files
clean:
	rm -rf bin $(SUBMODULES)
	mkdir $(SUBMODULES)
	#git submodule update --init --recursive --recommend-shallow 

# Regenerate the source file
tar: clean
	tar zcvf ../safeboot_$(VERSION).orig.tar.gz \
		--exclude .git \
		--exclude debian \
		.

package: tar
	debuild -uc -us
	cp ../safeboot_$(VERSION)_amd64.deb safeboot-unstable.deb


# Run shellcheck on the scripts
shellcheck:
	for file in \
		sbin/safeboot* \
		sbin/tpm2-attest \
		initramfs/*/* \
		functions.sh \
	; do \
		shellcheck $$file ; \
	done

# Fetch several of the TPM certs and make them usable
# by the openssl verify tool.
# CAB file from Microsoft has all the TPM certs in DER
# format.  openssl x509 -inform DER -in file.crt -out file.pem
# https://docs.microsoft.com/en-us/windows-server/security/guarded-fabric-shielded-vm/guarded-fabric-install-trusted-tpm-root-certificates
# However, the STM certs in the cab are corrupted? so fetch them
# separately
update-certs:
	#./refresh-certs
	c_rehash certs

# Fake an overlay mount to replace files in /etc/safeboot with these
fake-mount:
	mount --bind `pwd`/safeboot.conf /etc/safeboot/safeboot.conf
	mount --bind `pwd`/functions.sh /etc/safeboot/functions.sh
	mount --bind `pwd`/sbin/safeboot /sbin/safeboot
	mount --bind `pwd`/sbin/safeboot-tpm-unseal /sbin/safeboot-tpm-unseal
	mount --bind `pwd`/sbin/tpm2-attest /sbin/tpm2-attest
	mount --bind `pwd`/initramfs/scripts/safeboot-bootmode /etc/initramfs-tools/scripts/init-top/safeboot-bootmode
fake-unmount:
	mount | awk '/safeboot/ { print $$3 }' | xargs umount


#
# Build a safeboot initrd.cpio
#
build/initrd/gitstatus: initramfs/files.txt bin/busybox bin/tpm2 initramfs/init
	rm -rf "$(dir $@)"
	mkdir -p "$(dir $@)"
	./sbin/populate "$(dir $@)" "$<"
	git status -s > "$@"

build/initrd.cpio: build/initrd/gitstatus
	( cd $(dir $<) ; \
		find . -print0 \
		| cpio \
			-0 \
			-o \
			-H newc \
	) \
	| ./sbin/cpio-clean \
		initramfs/dev.cpio \
		- \
	> $@
	sha256sum $@

build/initrd.cpio.xz: build/initrd.cpio
	xz \
		--check=crc32 \
		--lzma2=dict=1MiB \
		--threads 0 \
		< "$<" \
	| dd bs=512 conv=sync status=none > "$@.tmp"
	@if ! cmp --quiet "$@.tmp" "$@" ; then \
		mv "$@.tmp" "$@" ; \
	else \
		echo "$@: unchanged" ; \
		rm "$@.tmp" ; \
	fi
	sha256sum $@

build/signing.key:
	openssl req \
		-new \
		-x509 \
		-newkey "rsa:2048" \
		-nodes \
		-subj "/CN=safeboot.dev/" \
		-outform "PEM" \
		-keyout "$@" \
		-out "$(basename $@).crt" \
		-days "3650" \
		-sha256 \


BOOTX64=build/boot/EFI/BOOT/BOOTX64.EFI
$(BOOTX64): build/vmlinuz initramfs/cmdline.txt bin/sbsign.safeboot build/signing.key
	mkdir -p "$(dir $@)"
#	DIR=. \
#	./sbin/safeboot unify-kernel \
#		"/tmp/kernel.tmp" \
#		linux=build/vmlinuz \
#		initrd=build/initrd.cpio.xz \
#		cmdline=initramfs/cmdline.txt \

	./bin/sbsign.safeboot \
		--output "$@" \
		--key build/signing.key \
		--cert build/signing.crt \
		$<

	sha256sum "$@"

build/boot/PK.auth: signing.crt
	-./sbin/safeboot uefi-sign-keys
	cp signing.crt PK.auth KEK.auth db.auth "$(dir $@)"

build/esp.bin: $(BOOTX64) build/boot/PK.auth
	./sbin/mkfat "$@" build/boot

build/hda.bin: build/esp.bin build/luks.bin
	./sbin/mkgpt "$@" $^

build/key.bin:
	echo -n "abcd1234" > "$@"

build/luks.bin: build/key.bin
	fallocate -l 512M "$@.tmp"
	cryptsetup \
		-y luksFormat \
		--pbkdf pbkdf2 \
		"$@.tmp" \
		"build/key.bin"
	cryptsetup luksOpen \
		--key-file "build/key.bin" \
		"$@.tmp" \
		test-luks
	#mkfs.ext4 /dev/mapper/test-luks
	cat root.squashfs > /dev/mapper/test-luks
	cryptsetup luksClose test-luks
	mv "$@.tmp" "$@"

TPMDIR=build/vtpm
TPMSTATE=$(TPMDIR)/tpm2-00.permall
TPMSOCK=$(TPMDIR)/sock
$(TPMSTATE): | $(SWTPM)
	mkdir -p build/vtpm
	PATH=$(dir $(SWTPM)):$(PATH) \
	swtpm/src/swtpm_setup/swtpm_setup \
		--tpm2 \
		--createek \
		--display \
		--tpmstate "$(dir $@)" \
		--config /dev/null \

# Extract the EK from a tpm state; wish swtpm_setup had a way
# to do this instead of requiring this many hoops
$(TPMDIR)/ek.pub: $(TPMSTATE) | bin/tpm2
	$(SWTPM) socket \
		--tpm2 \
		--flags startup-clear \
		--tpmstate dir="$(TPMDIR)" \
		--server type=tcp,port=9998 \
		--ctrl type=tcp,port=9999 \
		--pid file="$(TPMDIR)/swtpm-ek.pid" &
	sleep 1
	
	TPM2TOOLS_TCTI=swtpm:host=localhost,port=9998 \
	LD_LIBRARY_PATH=./tpm2-tss/src/tss2-tcti/.libs/ \
	./bin/tpm2 \
		createek \
		-c $(TPMDIR)/ek.ctx \
		-u $@

	kill `cat "$(TPMDIR)/swtpm-ek.pid"`
	@-$(RM) "$(TPMDIR)/swtpm-ek.pid"

# Convert an EK PEM formatted public key into the hash of the modulus,
# which is used by the quote and attestation server to identify the machine
# none of the tools output this easily, so do lots of text manipulation to make it
$(TPMDIR)/ek.hash: $(TPMDIR)/ek.pub
	sha256sum $< \
	| cut -d\  -f1 \
	> $@

# Register the virtual TPM in the attestation server logs with the
# expected value for the kernel that will be booted
# QEMU runs a few programs along the way before finally jumping to
# the actual kernel that has been received with pxe
PCR_CALL_BOOT:=3d6772b4f84ed47595d72a2c4c5ffd15f5bb72c7507fe26f2aaee2c69d5633ba
PCR_SEPARATOR:=df3f619804a92fdb4057192dc43dd748ea778adc52bc498ce80524c014b81119
PCR_RETURNING:=7044f06303e54fa96c3fcd1a0f11047c03d209074470b1fd60460c9f007e28a6
$(TPMDIR)/secrets.yaml: $(TPMDIR)/ek.hash $(BOOTX64)
	echo >  $@.tmp "`cat $<`:"
	echo >> $@.tmp "  device: 'qemu-server'"
	echo >> $@.tmp "  secret: 'magicwords'"
	echo >> $@.tmp "  pcrs:"
	echo >> $@.tmp -n "    4: "
	./sbin/predictpcr >> $@.tmp \
		$(PCR_CALL_BOOT) \
		$(PCR_SEPARATOR) \
		$(PCR_RETURNING) \
		$(PCR_CALL_BOOT) \
		$(PCR_RETURNING) \
		$(PCR_CALL_BOOT) \
		`./bin/sbsign.safeboot --hash-only $(BOOTX64)`
	mv $@.tmp $@


# uefi firmware from https://packages.debian.org/buster-backports/all/ovmf/download
qemu: build/hda.bin $(SWTPM) $(TPMSTATE)
	$(SWTPM) socket \
		--daemon \
		--terminate \
		--tpm2 \
		--tpmstate dir="$(TPMDIR)" \
		--pid file="$(TPMDIR)/swtpm.pid" \
		--ctrl type=unixio,path="$(TPMSOCK)" \


	#cp /usr/share/OVMF/OVMF_VARS.fd build

	-qemu-system-x86_64 \
		-M q35,accel=kvm \
		-m 4G \
		-drive if=pflash,format=raw,readonly,file=/usr/share/OVMF/OVMF_CODE.fd \
		-drive if=pflash,format=raw,file=build/OVMF_VARS.fd \
		-serial stdio \
		-netdev user,id=eth0 \
		-device e1000,netdev=eth0 \
		-chardev socket,id=chrtpm,path="$(TPMSOCK)" \
		-tpmdev emulator,id=tpm0,chardev=chrtpm \
		-device tpm-tis,tpmdev=tpm0 \
		-drive "file=$<,format=raw" \
		-boot c \

	stty sane
	-kill `cat $(TPMDIR)/swtpm.pid`
	@-$(RM) "$(TPMDIR)/swtpm.pid"

server-hda.bin:
	qemu-img create -f qcow2 $@ 1G
build/OVMF_VARS.fd:
	cp /usr/share/OVMF/OVMF_VARS.fd $@

qemu-server: \
		server-hda.bin \
		build/OVMF_VARS.fd \
		$(BOOTX64) \
		$(SWTPM) \
		$(TPMSTATE) \
		$(TPMDIR)/secrets.yaml \

	# start the TPM simulator
	-$(RM) "$(TPMSOCK)"
	$(SWTPM) socket \
		--tpm2 \
		--tpmstate dir="$(TPMDIR)" \
		--pid file="$(TPMDIR)/swtpm.pid" \
		--ctrl type=unixio,path="$(TPMSOCK)" \
		&

	sleep 1

	# start the attestation server on the new secrets files
	PATH=./bin:./sbin:$(PATH) DIR=. \
	./sbin/attest-server $(TPMDIR)/secrets.yaml 8080 $(TPMDIR)/attest.pid &

	-qemu-system-x86_64 \
		-M q35,accel=kvm \
		-m 1G \
		-drive if=pflash,format=raw,readonly,file=/usr/share/OVMF/OVMF_CODE.fd \
		-drive if=pflash,format=raw,file=build/OVMF_VARS.fd \
		-serial stdio \
		-netdev user,id=eth0,tftp=.,bootfile=$(BOOTX64) \
		-device e1000,netdev=eth0 \
		-chardev socket,id=chrtpm,path="$(dir $(TPMSTATE))sock" \
		-tpmdev emulator,id=tpm0,chardev=chrtpm \
		-device tpm-tis,tpmdev=tpm0 \
		-drive "file=$<,format=raw" \
		-boot n \

	stty sane
	-kill `cat $(TPMDIR)/swtpm.pid $(TPMDIR)/attest.pid`
	@-$(RM) "$(TPMDIR)/swtpm.pid" "$(TPMSOCK)" "$(TPMDIR)/attest.pid"


