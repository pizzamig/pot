#!/bin/sh
:

# TODO
# check the return code of all commands

# shellcheck disable=SC3033
init-help()
{
	echo 'pot init [-h][-v]'
	echo '  -h print this help'
	echo '  -v verbose'
}

# shellcheck disable=SC3033
pot-init()
{
	# shellcheck disable=SC3043
	local pf_file
	OPTIND=1
	while getopts "hv" _o ; do
		case "$_o" in
		h)
			init-help
			${EXIT} 0
			;;
		v)
			_POT_VERBOSITY=$(( _POT_VERBOSITY + 1))
			;;
		*)
			init-help
			${EXIT} 1
		esac
	done

	if ! _is_uid0 ; then
		${EXIT} 1
	fi

	if ! _zfs_exist "${POT_ZFS_ROOT}" "${POT_FS_ROOT}" ; then
		if _zfs_dataset_valid "${POT_ZFS_ROOT}" ; then
			_error "${POT_ZFS_ROOT} is an invalid POT root"
			return 1 # false
		fi
		# create the pot root
		_debug "creating ${POT_ZFS_ROOT} file system (mountpoint ${POT_FS_ROOT}"
		zfs create -o mountpoint="${POT_FS_ROOT}" -o canmount=off -o compression=lz4 -o atime=off "${POT_ZFS_ROOT}"
	else
		_info "${POT_ZFS_ROOT} already present"
	fi

	# create the root directory
	if [ ! -d "${POT_FS_ROOT}" ]; then
		mkdir -p "${POT_FS_ROOT}"
		if [ ! -d "${POT_FS_ROOT}" ]; then
			_error "Not able to create the dir ${POT_FS_ROOT}"
			return 1 # false
		fi
	fi

	# create mandatory datasets
	if ! _zfs_dataset_valid "${POT_ZFS_ROOT}/bases" ; then
		_debug "creating ${POT_ZFS_ROOT}/bases"
		zfs create "${POT_ZFS_ROOT}/bases"
	fi
	if ! _zfs_dataset_valid "${POT_ZFS_ROOT}/jails" ; then
		_debug "creating ${POT_ZFS_ROOT}/jails"
		zfs create "${POT_ZFS_ROOT}/jails"
	fi
	if ! _zfs_dataset_valid "${POT_ZFS_ROOT}/fscomp" ; then
		_debug "creating ${POT_ZFS_ROOT}/fscomp"
		zfs create "${POT_ZFS_ROOT}/fscomp"
	fi
	if ! _zfs_exist "${POT_ZFS_ROOT}/cache" "${POT_CACHE}" ; then
		_debug "creating ${POT_ZFS_ROOT}/cache mounted as ${POT_CACHE}"
		if ! _zfs_dataset_valid "${POT_ZFS_ROOT}/cache" ; then
			zfs create -o mountpoint="${POT_CACHE}" -o compression=off "${POT_ZFS_ROOT}/cache"
		fi
	fi
	# create the bridges folder
	mkdir -p "${POT_FS_ROOT}/bridges"
	# create mandatory directories for logs
	mkdir -p /usr/local/etc/syslog.d
	mkdir -p /usr/local/etc/newsyslog.conf.d
	mkdir -p /var/log/pot

	if ! _is_pot_tmp_dir ; then
		_error "The POT_TMP directory has not been created - aborting"
		${EXIT} 1
	fi

	if ! potnet config-check ; then
		_error "The network configuration in the pot configuration file is not valid"
		${EXIT} 1
	fi
	if ! _is_valid_netif "$POT_EXTIF" ; then
		_error "The network interface $POT_EXTIF seems not valid [POT_EXTIF]"
		${EXIT} 1
	fi
	if [ -n "$POT_EXTIF_ADDR" ]; then
		if ! potnet ip4check --host "$POT_EXTIF_ADDR" ; then
			_error "The value $POT_EXTIF_ADDR [POT_EXTIF_ADDR] is not a valid IPv4 address"
			${EXIT} 1
		fi
		if ! _is_valid_extif_addr "$POT_EXTIF" "$POT_EXTIF_ADDR" ; then
			_error "The IP address $POT_EXTIF_ADDR [POT_EXTIF_ADDR] is not available on the network interface $POT_EXTIF [POT_EXTIF]"
			${EXIT} 1
		fi
	fi

	for extra_netif in $POT_EXTRA_EXTIF ; do
		if ! _is_valid_netif "$extra_netif" ; then
			_error "The network interface $extra_netif seems not valid [POT_EXTRA_EXTIF]"
			${EXIT} 1
		fi
	done

	if [ -w /etc/rc.conf ]; then
		echo "Creating a backup of your /etc/rc.conf"
		cp -v /etc/rc.conf /etc/rc.conf.bkp-pot
	fi
	# add proper syslogd flags and restart it
	sysrc -q syslogd_flags="-b 127.0.0.1 -b $POT_GATEWAY -a $POT_NETWORK"
	# service syslogd restart

	# Add pot anchors if needed
	pf_file="$(sysrc -n pf_rules)"
	if [ -r "$pf_file" ] && [ "$(grep -c '^nat-anchor pot-nat$' "$pf_file" )" -eq 1 ] && [ "$(grep -c '^rdr-anchor "pot-rdr/\*"$' "$pf_file" )" -eq 1 ] ; then
		_debug "pf alredy properly configured"
	else
		if [ -w "$pf_file" ]; then
			echo "Creating a backup of your $pf_file"
			cp -v "$pf_file" "$pf_file".bkp-pot
			# delete incomplete/broken ancory entries - just in case
			sed -i '' '/^nat-anchor pot-nat$/d' "$pf_file"
			sed -i '' '/^rdr-anchor "pot-rdr\/\*"$/d' "$pf_file"
		else
			touch "$pf_file"
		fi
		echo "auto-magically editing your $pf_file"
		printf "%s\n" 0a "nat-anchor pot-nat" "rdr-anchor \"pot-rdr/*\"" . x | ex "$pf_file"
		echo "Please, check that your PF configuration file $pf_file is still valid!"
	fi
}
