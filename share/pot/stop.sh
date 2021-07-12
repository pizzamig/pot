#!/bin/sh
:
# shellcheck disable=SC3033
stop-help()
{
	echo "pot stop [-hv] [-p] potname"
	echo '  -h print this help'
	echo '  -v verbose'
	echo '  potname : the pot that has to stop'
}

_js_cpu_rebalance()
{
	if ! _tmpfile=$(mktemp -t "${POT_TMP:-/tmp}/potcpu.XXXXXX") ; then
		_error "not able to create temporary file - umount failed"
		return
	fi
	potcpu rebalance > "$_tmpfile"
	while read -r cpuset_cmd ; do
		eval "$cpuset_cmd"
	done < "$_tmpfile"
}

# $1 pot name
_js_stop()
{
	# shellcheck disable=SC3043
	local _pname _pdir _epair _ip _aname
	_pname="$1"
	_pdir="${POT_FS_ROOT}/jails/$_pname"
	_epair=
	_network_type=$( _get_pot_network_type "$_pname" )
	if _is_pot_running "$_pname" ; then
		if _is_pot_vnet "$_pname" ; then
			_epair=$(jexec "$_pname" ifconfig | grep ^epair | cut -d':' -f1)
		fi

		if [ -x "$_pdir/conf/prestop.sh" ]; then
			_info "Executing the pre-stop script for the pot $_pname"
			(
				# shellcheck disable=SC2086,2046
				eval $( pot info -E -p "$_pname" )
				"$_pdir"/conf/prestop.sh
			)
		fi
		_debug "Stop the pot $_pname"
		touch "${POT_TMP:-/tmp}/pot_stopped_${_pname}"
		jail -q -r "$_pname"
		if [ -n "$_epair" ]; then
			_debug "Remove ${_epair%b}[a|b] network interfaces"
			sleep 1 # try to avoid a race condition in the epair driver, potentially causing a kernel panic
			ifconfig "${_epair%b}"a destroy
		else
			if [ "$_network_type" = "alias" ]; then
				_ip=$( _get_ip_var "$_pname" )
				_debug "Remove $_ip aliases"

				for _i in $_ip ; do
					if echo "$_i" | grep -qF '|' ; then
						_nic="$( echo "$_i" | cut -f 1 -d '|' )"
						_ipaddr="$( echo "$_i" | cut -f 2 -d '|' )"
					else
						_nic="$POT_EXTIF"
						_ipaddr="$_i"
					fi
					if potnet ip4check -H "$_ipaddr" ; then
						if ifconfig "${_nic}" | grep -q "inet $_ipaddr " ; then
							ifconfig "${_nic}" inet "$_ipaddr" -alias
						fi
					else
						if ifconfig "${_nic}" | grep -q "inet6 $_ipaddr " ; then
							ifconfig "${_nic}" inet6 "$_ipaddr" -alias
						fi
					fi
				done
			fi
		fi
	fi
	if [ -c "/dev/pf" ]; then
		_aname="$( _get_pot_rdr_anchor_name "$_pname" )"
		pfctl -a "pot-rdr/$_aname" -F nat -q
	fi

	_ports="$( _get_pot_export_ports "$_pname" )"
	if [ -n "$_ports" ]; then
		for _port in $_ports ; do
			_pot_port="$( echo "${_port}" | cut -d':' -f 1)"
			if [ -r "$_pdir/ncat-$_pot_port.pid" ]; then
				pkill -F "$_pdir/ncat-$_pot_port.pid" -f "ncat-$_pname-$_pot_port"
				rm -f "$_pdir/ncat-$_pot_port.pid"
			elif pgrep -q -f "$_pdir/ncat-$_pname-$_pot_port" ; then
				pkill -f "$_pdir/ncat-$_pname-$_pot_port"
			fi
		done
	fi
	# For compatibility reason with the previous implementations
	if [ -r "$_pdir/ncat.pid" ]; then
		pkill -F "$_pdir/ncat.pid" -f "ncat-$_pname"
		rm -f "$_pdir/ncat.pid"
	elif pgrep -q -f "$_pdir/ncat-$_pname" ; then
		pkill -f "$_pdir/ncat-$_pname"
	fi

	# Garbage collect POSIX shared memory
	if command -v posixshmcontrol >/dev/null; then
		_shm_paths=$( posixshmcontrol ls | cut -f 5 | grep "^$_pdir/" )
		for _shm_path in $_shm_paths ; do
			posixshmcontrol rm "$_shm_path"
		done
	fi

	if [ -x "$_pdir/conf/poststop.sh" ]; then
		_info "Executing the post-stop script for the pot $_pname"
		(
			# shellcheck disable=SC2086,2046
			eval $( pot info -E -p "$_pname" )
			"${_pdir}"/conf/poststop.sh
		)
	fi
	rm -f "${POT_TMP:-/tmp}/pot_pfrules_${_pname}*"
	rm -f "${POT_TMP:-/tmp}/pot_environment_${_pname}*.sh"
	return 0 # true
}

# $1 pot name
_js_rm_resolv()
{
	# shellcheck disable=SC3043
	local _pname _jdir _dns
	_pname="$1"
	_jdir="${POT_FS_ROOT}/jails/$_pname"
	if [ -f "$_jdir/m/etc/resolv.conf" ]; then
		_dns="$(_get_conf_var "$_pname" pot.dns)"
		if [ "$_dns" != "off" ]; then
			rm -f "$_jdir/m/etc/resolv.conf"
		fi
	fi
}

_epair_cleanup()
{
	# shellcheck disable=SC3043
	local _epairs_a _epairs_b
	_epairs_b="$(ifconfig | grep '^epair[0-9][0-9]*b' | sed 's/:.*$//' | sort)"
	_epairs_a="$(ifconfig | grep '^epair[0-9][0-9]*a' | sed 's/:.*$//' | sort)"
	for _e in $_epairs_b ; do
		# shellcheck disable=SC2086
		if _is_in_list "${_e%b}a" $_epairs_a ; then
			ifconfig "$_e" destroy
		fi
	done
}

# shellcheck disable=SC3033
pot-stop()
{
	# shellcheck disable=SC3043
	local _pname
	_pname=

	OPTIND=1
	while getopts "hvp:" _o; do
		case "$_o" in
		h)
			stop-help
			${EXIT} 0
			;;
		v)
			_POT_VERBOSITY=$(( _POT_VERBOSITY + 1))
			;;
		p)
			_pname="$OPTARG"
			;;
		?)
			stop-help
			${EXIT} 1
			;;
		esac
	done
	if [ -z "$_pname" ]; then
		_pname="$( eval echo \$$OPTIND)"
	fi
	if [ -z "$_pname" ]; then
		_error "A pot name is mandatory"
		stop-help
		${EXIT} 1
	fi
	if ! _is_pot "$_pname" quiet ; then
		_error "The pot $_pname is not a valid pot"
		${EXIT} 0
	fi
	if ! _is_uid0 ; then
		${EXIT} 1
	fi

	if ! _js_stop "$_pname" ; then
		_error "Stop the pot $_pname failed"
		${EXIT} 1
	fi
	_js_rm_resolv "$_pname"
	_pot_umount "$_pname"
	_epair_cleanup
}
