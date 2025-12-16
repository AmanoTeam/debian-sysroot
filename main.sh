#!/usr/bin/env bash

set -eu

declare -r workdir="${PWD}"
declare -r temporary_directory='/tmp/obggcc-sysroot'

[ -d "${temporary_directory}" ] || mkdir "${temporary_directory}"

cd "${temporary_directory}"

while read item; do
	declare distribution="$(jq --raw-output '.distribution' <<< "${item}")"
	declare distribution_version="$(jq '.distribution_version' <<< "${item}")"
	declare glibc_version="$(jq '.glibc_version' <<< "${item}")"
	declare linux_version="$(jq '.linux_version' <<< "${item}")"
	declare triplet="$(jq --raw-output '.triplet' <<< "${item}")"
	declare host=${triplet//-unknown/}
	declare packages="$(jq '.packages' <<< "${item}")"
	declare output_format="$(jq --raw-output '.output_format' <<< "${item}")"
	declare loader="$(jq --raw-output '.loader' <<< "${item}")"
	
	declare repository_url="$(jq --raw-output '.repository.url' <<< "${item}")"
	declare repository_release="$(jq --raw-output '.repository.release' <<< "${item}")"
	
	distribution_version=${distribution_version%.*}
	
	declare debian='0'
	declare ubuntu='0'
	declare centos='0'
	
	declare amd64='0'
	declare aarch64='0'
	
	wget --no-verbose --spider "${repository_url}dists/${repository_release}"
	
	if [ "${triplet}" = 'x86_64-unknown-linux-gnu' ]; then
		amd64='1'
	fi
	
	if [ "${triplet}" = 'aarch64-unknown-linux-gnu' ]; then
		aarch64='1'
	fi
	
	if [ "${distribution}" = 'debian' ]; then
		debian='1'
	fi
	
	if [ "${distribution}" = 'ubuntu' ]; then
		ubuntu='1'
	fi
	
	if [ "${distribution}" = 'centos' ]; then
		centos='1'
	fi
	
	if [ "${distribution_version}" = '2.2' ]; then
		distribution_version='2'
	fi
	
	declare sysroot_directory="${workdir}/${triplet}${glibc_version}"
	declare tarball_filename="${sysroot_directory}.tar.xz"
	
	echo "- Generating sysroot for ${triplet} (glibc = ${glibc_version}, linux = ${linux_version}, ${distribution} = ${distribution_version})"
	
	if [ -f "${tarball_filename}" ]; then
		echo "+ Already exists. Skip"
		continue
	fi
	
	[ -d "${sysroot_directory}" ] || mkdir "${sysroot_directory}"
	
	rm --force --recursive "${temporary_directory}/"*
	rm --force --recursive "${sysroot_directory}/"*
	
	while read package; do
		echo "- Fetching data from '${package}'"
		
		curl \
			--connect-timeout '10' \
			--retry '15' \
			--retry-all-errors \
			--fail \
			--silent \
			--show-error \
			--location \
			--remote-name \
			--url "${package}"
	done <<< "$(jq --raw-output --compact-output '.[]' <<< "${packages}")"
	
	if [ "${distribution}" = 'debian' ] || [ "${distribution}" = 'ubuntu' ]; then
		for file in *.deb; do
			ar x "${file}"
			
			if [ -f './data.tar.gz' ]; then
				declare filename='./data.tar.gz'
			elif [ -f './data.tar.zst' ]; then
				declare filename='./data.tar.zst'
			else
				declare filename='./data.tar.xz'
			fi
			
			if [[ "${filename}" = *'zst'* ]]; then
				tar --use-compress-program='unzstd' --extract --file="${filename}"
			else
				tar --extract --file="${filename}"
			fi
			
			unlink "${filename}"
		done
	else
		for file in *.rpm; do
			rpm2cpio "${file}" | cpio \
				--extract \
				--make-directories \
				--preserve-modification-time \
				--quiet
			unlink "${file}"
		done
	fi
	
	cp --recursive './usr/include' "${sysroot_directory}"
	
	if (( centos || ubuntu )) && [ -d './usr/lib64' ]; then
		mv './usr/lib64' "${sysroot_directory}/lib"
	else
		cp --recursive './usr/lib' "${sysroot_directory}"
	fi
	
	if (( centos )); then
		mv './lib'*'/'* "${sysroot_directory}/lib"
	fi
	
	[ -d "${sysroot_directory}/lib/${host}/gconv" ] && rm --recursive "${sysroot_directory}/lib/${host}/gconv"
	[ -d "${sysroot_directory}/lib/gconv" ] && rm --recursive "${sysroot_directory}/lib/gconv"
	[ -d "${sysroot_directory}/lib/rtkaio" ] && rm --recursive "${sysroot_directory}/lib/rtkaio"
	[ -d "${sysroot_directory}/lib/libc" ] && rm --recursive "${sysroot_directory}/lib/libc"
	
	if (( debian || ubuntu )); then
		if (( debian && distribution_version >= 7 )) || (( ubuntu )); then
			
			if (( debian || ( ubuntu && distribution_version < 24 ) )); then
				mv "./lib/${host}/"* "${sysroot_directory}/lib"
			fi
			
			if (( ubuntu )); then
				mv "./usr/lib/${host}/"* "${sysroot_directory}/lib"
			fi
		else
			mv "./lib/"* "${sysroot_directory}/lib"
		fi
		
		if (( debian && distribution_version >= 7 )) || (( ubuntu )); then
			if (( debian )); then
				cp --recursive "${sysroot_directory}/lib/${host}/"* "${sysroot_directory}/lib"
			fi
			
			cp --recursive "${sysroot_directory}/include/${host}/"* "${sysroot_directory}/include"
			
			if (( debian )); then
				rm --recursive "${sysroot_directory}/lib/${host}"
			fi
			
			rm --recursive "${sysroot_directory}/include/${host}"
		fi
	fi
	
	cd "${sysroot_directory}/lib"
	
	[ -d './nptl' ] && rm --recursive './nptl'
	[ -d './tls' ] && rm --recursive './tls'
	[ -d './audit' ] && rm --recursive './audit'
	[ -d './gconv' ] && rm --recursive './gconv'
	[ -d './libc' ] && rm --recursive './libc'
	[ -d "./${host}" ] && rm --recursive "./${host}"
	
	[ -f './pt_chown' ] && unlink './pt_chown'
	
	find . -type l | xargs ls -l | grep --perl-regexp '/lib(?:64)?/' | awk '{print "unlink $(basename "$9") && ln --symbolic ./$(basename "$11") ./$(basename "$9")"}' | bash
	
	if (( ubuntu )); then
		for source in lib*.so.*; do
			destination="$(awk -F  '.' '{print $1"."$2}' <<< "${source}")"
			[ -f "${destination}" ] && continue
			
			ln --symbolic "${source}" "${destination}"
		done
	fi
	
	if [ "${triplet}" == 'alpha-unknown-linux-gnu' ] || [ "${triplet}" == 'ia64-unknown-linux-gnu' ]; then
		echo -e "OUTPUT_FORMAT(${output_format})\nGROUP ( libc.so.6.1 libc_nonshared.a AS_NEEDED ( ${loader} ) )" > './libc.so'
	else
		echo -e "OUTPUT_FORMAT(${output_format})\nGROUP ( libc.so.6 libc_nonshared.a AS_NEEDED ( ${loader} ) )" > './libc.so'
	fi
	
	if (( ( debian || centos ) && distribution_version >= 4 && distribution_version <= 9 )) || (( ubuntu && distribution_version >= 12 && distribution_version <= 18 )); then
		echo -e "OUTPUT_FORMAT(${output_format})\nGROUP ( libpthread.so.0 libpthread_nonshared.a )" > './libpthread.so'
	fi
	
	if ( (( ubuntu && distribution_version >= 16 && distribution_version <= 18 )) || (( debian && distribution_version >= 9 && distribution_version <= 10 )) ) && [ "${triplet}" == 'x86_64-unknown-linux-gnu' ]; then
		echo -e "OUTPUT_FORMAT(${output_format})\nGROUP ( libm.so.6 AS_NEEDED ( libmvec_nonshared.a libmvec.so.1 ) )" > './libm.so'
	fi
	
	if ( (( debian && distribution_version >= 11 && amd64 )) || (( ubuntu && ( distribution_version >= 22 && amd64 || distribution_version >= 24 && aarch64 ) )) ); then
		echo -e "OUTPUT_FORMAT(${output_format})\nGROUP ( libm.so.6 AS_NEEDED ( libmvec.so.1 ) )" > './libm.so'
	fi
	
	if (( ubuntu && distribution_version >= 18 )) || (( debian && distribution_version >= 10 )); then
		declare source="$(ls 'libm-2.'*'.a' 2>/dev/null || echo 'not-found')"
		
		if [ -f "${source}" ]; then
			echo -e "OUTPUT_FORMAT(${output_format})\nGROUP ( ${source} libmvec.a )" > './libm.a'
		fi
	fi
	
	if [[ "${triplet}" == mips*-unknown-linux-gnu ]] || [ "${triplet}" == 'powerpc-unknown-linux-gnu' ] || [ "${triplet}" == 's390-unknown-linux-gnu' ] || [ "${triplet}" == 'sparc-unknown-linux-gnu' ]; then
		[ -f "${sysroot_directory}/include/linux/pim.h" ] && patch --directory="${sysroot_directory}" --strip='1' --input="${workdir}/patches/linux_pim.patch"
	fi
	
	if (( debian && distribution_version == 4 )); then
		while read file; do
			sed \
				--null-data \
				--in-place \
				--expression 's/extern inline /extern inline __attribute__((gnu_inline)) /g; s/extern __inline__ /extern __inline__ __attribute__((gnu_inline)) /g; s/extern __inline /extern __inline __attribute__((gnu_inline)) /g' \
				--expression 's/extern inline\n/extern inline __attribute__((gnu_inline))\n/g; s/extern __inline__\n/extern __inline__ __attribute__((gnu_inline))\n/g; s/extern __inline\n/extern __inline __attribute__((gnu_inline))\n/g' \
				"${file}"
		done <<< $(find "${sysroot_directory}/include" -type 'f')
	fi
	
	if (( debian && distribution_version <= 7 )) || (( ubuntu && distribution_version <= 12 )); then
		patch \
			--reject-file='/tmp/null' \
			--no-backup-if-mismatch \
			--directory="${sysroot_directory}/include" \
			--strip='1' \
			--input="${workdir}/patches/0001-Alias-static_assert-to-_Static_assert-in-C11-mode.patch" 2>/dev/null || true
	fi
	
	if [ "${triplet}" = 'aarch64-unknown-linux-gnu' ] && (( (( debian && distribution_version <= 8 )) || (( ubuntu && distribution_version <= 16 )) )); then
		patch \
			--reject-file='/tmp/null' \
			--no-backup-if-mismatch \
			--directory="${sysroot_directory}/include" \
			--strip='1' \
			--input="${workdir}/patches/0001-Backport-AArch64-HWCAP_-definitions-to-older-glibc-versions.patch" 2>/dev/null || true
	fi
	
	if [ "${triplet}" = 'x86_64-unknown-linux-gnu' ] && (( (( debian && distribution_version <= 9 )) || (( ubuntu && distribution_version <= 16 )) )); then
		patch \
			--reject-file='/tmp/null' \
			--no-backup-if-mismatch \
			--directory="${sysroot_directory}/include" \
			--strip='1' \
			--input="${workdir}/patches/ptrace/x86_64-unknown-linux-gnu${glibc_version}/0001-Backport-PTRACE_-definitions-from-glibc-2.27-to-older-glibc-releases.patch" 2>/dev/null || true
	fi
	
	if [ "${triplet}" = 'i386-unknown-linux-gnu' ] && (( ubuntu && distribution_version == 12 )); then
		rm "${sysroot_directory}/lib/libnss_db.so"*
	fi
	
	sed \
		--in-place \
		's/*__block/*___block/g' \
		"${sysroot_directory}/include/"*'.h'
	
	cd "${temporary_directory}"
	
	rm --force --recursive ./*
	
	echo "- Creating tarball at ${tarball_filename}"
	
	tar --directory="$(dirname "${sysroot_directory}")" --create --file=- "$(basename "${sysroot_directory}")" | xz --compress -9 > "${tarball_filename}"
	sha256sum "${tarball_filename}" | sed "s|$(dirname "${sysroot_directory}")/||" > "${tarball_filename}.sha256"
	
	rm --force --recursive "${sysroot_directory}"
done <<< "$(jq --compact-output '.[]' "${workdir}/dist.json")"
