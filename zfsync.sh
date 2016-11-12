#!/usr/bin/env bash

mode="${1}"

case "${1}" in
	dryinit)
		src="${2}"
		dsthost="${3}"
		dst="${4}"
		hash=$(echo "${src}:${dsthost}:${dst}" | md5 | head -c 16)
		srctmp="${src}@repl:${hash}:tmp"
		#srccur="${src}@repl:${hash}:cur"
		dsttmp="${dst}@repl:${hash}:tmp"
		dstcur="${dst}@repl:${hash}:cur"
		srcbm="${src}#repl:${hash}:cur"
		replremotes=$(echo "${hash} ${dsthost} ${dst}" | base64 -e | tr -d '\n')

		echo "src=${src}"
		echo "dsthost=${dsthost}"
		echo "dst=${dst}"
		echo "hash=${hash}"
		echo "srctmp=${srctmp}"
		#echo "srccur=${srccur}"
		echo "dsttmp=${dsttmp}"
		echo "dstcur=${dstcur}"
		echo "srcbm=${srcbm}"
		echo "repl:remotes=${replremotes}"
	;;
	init)
		src="${2}"
		dsthost="${3}"
		dst="${4}"
		hash=$(echo "${src}:${dsthost}:${dst}" | md5 | head -c 16)
		srctmp="${src}@repl:${hash}:tmp"
		#srccur="${src}@repl:${hash}:cur"
		dsttmp="${dst}@repl:${hash}:tmp"
		dstcur="${dst}@repl:${hash}:cur"
		srcbm="${src}#repl:${hash}:cur"

		zfs snapshot "${srctmp}"
		if [ "x${?}" != "x0" ]; then
			echo "Failed to create snapshot, aborting..."
			exit 1
		fi
		size=$(zfs send -nPp "${srctmp}" 2>&1 | awk '$1 == "size" {print $2}')
		zfs send -p "${srctmp}" | pv -fcN 'local ' -s "${size}" | pigz -c9 | ssh "${dsthost}" "pigz -d | pv -fcN 'remote' -s ${size} -w $(tput cols) -H $(tput lines) | zfs recv ${dst}"
		if [ "x${?}" != "x0" ]; then
			echo "Failed to sync snapshot, aborting..."
			zfs destroy "${srctmp}"
			exit 1
		fi
		if ! zfs get -Hosource repl:remotes "${src}" | grep -qE '^local$'; then
			zfs set repl:remotes=Cg== "${src}"
		fi
		zfs set repl:remotes=$(echo "$(zfs get -Hovalue repl:remotes ${src} | base64 -d)
${hash} ${dsthost} ${dst}" | sort | uniq | grep -vE '^$' | base64 -e | tr -d '\n') "${src}"
		zfs destroy "${srcbm}" > /dev/null 2> /dev/null
		zfs bookmark "${srctmp}" "${srcbm}"
		zfs destroy "${srctmp}"
		ssh -n "${dsthost}" "zfs rename ${dsttmp} ${dstcur}"
	;;
	slowinit)
		src="${2}"
		dsthost="${3}"
		dst="${4}"
		hash=$(echo "${src}:${dsthost}:${dst}" | md5 | head -c 16)
		srctmp="${src}@repl:${hash}:tmp"
		#srccur="${src}@repl:${hash}:cur"
		dsttmp="${dst}@repl:${hash}:tmp"
		dstcur="${dst}@repl:${hash}:cur"
		srcbm="${src}#repl:${hash}:cur"
		tmphash=$(head -c 8192 /dev/urandom | md5)
		#ltmpzfs="data/tmp/${tmphash}"
		ltmpzfs=$(dirname "${src}")"/synctmp_${tmphash}"
		rtmpzfs=$(dirname "${dst}")"/synctmp_${tmphash}"

		zfs snapshot "${srctmp}"
		if [ "x${?}" != "x0" ]; then
			echo "Failed to create snapshot, aborting..."
			exit 1
		fi
		size=$(zfs send -nPp "${srctmp}" 2>&1 | awk '$1 == "size" {print $2}')
		
		zfs create "${ltmpzfs}"
		if [ "x${?}" != "x0" ]; then
			echo "Failed to create local temp syncdir, aborting..."
			zfs destroy "${srctmp}"
			exit 1
		fi
		ssh "${dsthost}" "zfs create ${rtmpzfs}"
		if [ "x${?}" != "x0" ]; then
			echo "Failed to create remote temp syncdir, aborting..."
			zfs destroy -r "${ltmpzfs}"
			zfs destroy "${srctmp}"
			exit 1
		fi
		cd "/${ltmpzfs}"
		echo "Exporting & splitting ${srctmp} to /${ltmpzfs}"
		zfs send -p "${srctmp}" | pv -fcN 'local ' -s "${size}" | pigz -c9 | split -db 10M -a 12 - ''
		while true; do
			echo "Rechecking all files ..."
			neededresync=0
			filecount=$(ls -1 | wc -l)
			for i in *; do
				rchksum=$(ssh "${dsthost}" "test -f /${rtmpzfs}/${i} && md5 -q /${rtmpzfs}/${i}")
				if [ "x${rchksum}" == "x" ]; then
					lchksum="x"
				else
					lchksum=$(md5 -q "/${ltmpzfs}/${i}")
				fi
				if [ "x${lchksum}" != "x${rchksum}" ]; then
					neededresync=1
					#echo "$lchksum != $rchksum" 1>&2
					#echo "Resyncing /${ltmpzfs}/${i} > /${rtmpzfs}/${i} ..." 1>&2
					pv -cN"${i}" "/${ltmpzfs}/${i}" | ssh "${dsthost}" "cat > /${rtmpzfs}/${i}"
				fi
				echo -n .
			done | pv -cs"${filecount}" -N"total" > /dev/null
			if [ "x${neededresync}" == "x0" ]; then
				echo "No resync needed (neededresync=${neededresync})"
				break
			fi
		done
#		if [ "x${?}" != "x0" ]; then
#			echo "Failed to sync snapshot, aborting..."
#			zfs destroy -r "${ltmpzfs}"
#			ssh "${dsthost}" "zfs destroy -r ${rtmpzfs}"
#			zfs destroy "${srctmp}"
#			exit 1
#		fi
		cd /
		zfs destroy -r "${ltmpzfs}"
		echo "Importing synced chunks ..."
		ssh "${dsthost}" "find /${rtmpzfs}/ -type f | sort -t / | xargs -n1 -I% sh -c 'pv -f -N% -w $(tput cols) -H $(tput lines) %' | pigz -d | zfs recv ${dst}"
		
		if [ "x${?}" != "x0" ]; then
			echo "Failed to sync snapshot, aborting..."
			ssh "${dsthost}" "zfs destroy -r ${rtmpzfs}"
			zfs destroy "${srctmp}"
			exit 1
		fi
		echo "Finalizing ..."
		ssh "${dsthost}" "zfs destroy -r ${rtmpzfs}"
		if ! zfs get -Hosource repl:remotes "${src}" | grep -qE '^local$'; then
			zfs set repl:remotes=Cg== "${src}"
		fi
		zfs set repl:remotes=$(echo "$(zfs get -Hovalue repl:remotes ${src} | base64 -d)
${hash} ${dsthost} ${dst}" | sort | uniq | grep -vE '^$' | base64 -e | tr -d '\n') "${src}"
		zfs destroy "${srcbm}" > /dev/null 2> /dev/null
		zfs bookmark "${srctmp}" "${srcbm}"
		zfs destroy "${srctmp}"
		ssh -n "${dsthost}" "zfs rename ${dsttmp} ${dstcur}"
	;;
	sync)
		src="${2}"

		zfs get -Hovalue repl:remotes "${src}" | base64 -d | sort | uniq | while read hash dsthost dst; do
			#echo "test"
			if [ "x${dsthost}" == "x10.88.69.2" ]; then
				continue
			fi
			if [ "x${dsthost}" == "x78.46.187.209" ]; then
				continue
			fi
			if [ "x${hash}" == "x" -o "x${dsthost}" == "x" -o "x${dst}" == "x" ]; then
				#echo "Something is wrong here O_o (hash=$hash;dsthost=$dsthost;dst=$dst"
				continue
			fi
			echo "$src -> $dsthost ($dst)"
			srctmp="${src}@repl:${hash}:tmp"
			#srccur="${src}@repl:${hash}:cur"
			dsttmp="${dst}@repl:${hash}:tmp"
			dstcur="${dst}@repl:${hash}:cur"
			srcbm="${src}#repl:${hash}:cur"

			zfs snapshot "${srctmp}"
			if [ "x${?}" != "x0" ]; then
				echo "Failed to create snapshot, aborting..."
				continue
			fi
			if [ "x${size}" != "x-0" ]; then
#				zfs send -i "${srcbm}" "${srctmp}" | pv -fcN 'local ' | pigz -c9 | ssh "${dsthost}" "pigz -d | pv -fcN 'remote' -w $(tput cols) -H $(tput lines) | zfs recv ${dst}"
				zfs send -i "${srcbm}" "${srctmp}" | pigz -c9 | ssh "${dsthost}" "pigz -d | zfs recv ${dst}"
				if [ "x${?}" != "x0" ]; then
					echo "Failed to sync snapshot, aborting..."
					zfs destroy "${srctmp}"
					continue
				fi
				if ! ssh -n "${dsthost}" "zfs list -Honame ${dsttmp}" > /dev/null 2> /dev/null; then
					echo "Snapshot did not arrive at the destination, aborting..."
					zfs destroy "${srctmp}"
					continue
				fi
				zfs destroy "${srcbm}"
				zfs bookmark "${srctmp}" "${srcbm}"
				zfs destroy "${srctmp}"
				ssh -n "${dsthost}" "zfs destroy ${dstcur}"
				ssh -n "${dsthost}" "zfs rename ${dsttmp} ${dstcur}"
			else
				zfs destroy "${srctmp}"
			fi
			#echo "done"
		done
	;;
	syncall)
		for store in $(zfs get -Honame,source repl:remotes | grep -vF "/._RO_." | awk '$2 == "local" {print $1}'); do
			echo "${store}"
			/usr/bin/env bash "${0}" sync "${store}"
		done
	;;
	loop)
		count=0
		while true; do
			echo "Loop ${count}"
			/usr/bin/env bash "${0}" syncall
			echo ""
			count=$((${count}+1))
		done
	;;
esac
