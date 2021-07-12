#!/bin/sh
:
# shellcheck disable=SC3033
vnet-start-help()
{
	echo 'pot vnet-start [-h][-v]'
	echo '  -h -- print this help'
	echo '  -v verbose'
	echo '  -B bridge-name (opional)'
}

_public_bridge_start()
{
	# shellcheck disable=SC3043
	local _bridge
	_bridge=$(_pot_bridge)
	if [ -z "$_bridge" ]; then
		if _bridge=$(ifconfig bridge create) ; then
			_debug "Bridge created $_bridge"
		else
			_error "Bridge not created"
		fi
		if ! ifconfig "$_bridge" inet "$POT_GATEWAY" netmask "$POT_NETMASK" ; then
			_error "Error during bridge configuration ($_bridge)"
		else
			_debug "Bridge $_bridge configured with IP $POT_GATEWAY netmask $POT_NETMASK"
		fi
	else
		_debug "Bridge $_bridge already present"
	fi
}

# $1 bridge_name
_private_bridge_start()
{
	# shellcheck disable=SC3043
	local _bridge_name _bridge _gateway _bridge_net
	_bridge_name="$1"
	_bridge=$(_private_bridge "$_bridge_name")
	if [ -z "$_bridge" ]; then
		if _bridge=$(ifconfig bridge create) ; then
			_debug "Bridge created $_bridge"
		else
			_error "Bridge not created"
		fi
		_gateway="$(_get_bridge_var "$_bridge_name" gateway)"
		_bridge_net="$(_get_bridge_var "$_bridge_name" net)"
		_bridge_net="${_bridge_net##*/}"
		if ! ifconfig "$_bridge" inet "${_gateway}/${_bridge_net}" ; then
			_error "Error during bridge configuration ($_bridge)"
		else
			_debug "Bridge $_bridge configured with IP ${_gateway}/${_bridge_net}"
		fi
	else
		_debug "Bridge $_bridge already present"
	fi
}

_ipv4_start()
{
	# shellcheck disable=SC3043
	local _bridge_name pf_file _nat_rules _ext_addr
	_bridge_name="$1"
	# activate ip forwarding
	if _is_verbose ; then
		sysctl net.inet.ip.forwarding=1
	else
		sysctl -qn net.inet.ip.forwarding=1 > /dev/null
	fi
	if [ -z "$_bridge_name" ]; then
		_public_bridge_start
	elif _is_bridge "$_bridge_name" quiet ; then
		_private_bridge_start "$_bridge_name"
	else
		_error "$_bridge_name is not a valid bridge"
		return
	fi

	# load pf module
	kldload -n pf
	pf_file="$(sysrc -n pf_rules)"
	# check anchors
	if ! pfctl -s Anchors | grep -q '^[ \t]*pot-nat$' ||
		! pfctl -s Anchors | grep -q '^[ \t]*pot-rdr$' ; then
		_debug "Pot anchors are missing - load $pf_file"
		pfctl -f "$pf_file"
	fi
	_nat_rules="${POT_TMP:-/tmp}/pot_pf_nat_rules"
	if [ -w "$_nat_rules" ]; then
		rm -f "$_nat_rules"
	fi
	if [ -n "$POT_EXTIF_ADDR" ]; then
		if ! potnet ip4check --host "$POT_EXTIF_ADDR" ; then
			_info "The value $POT_EXTIF_ADDR [POT_EXTIF_ADDR] is not a valid IPv4 address - ignoring"
			_ext_addr=
		elif ! _is_valid_extif_addr "$POT_EXTIF" "$POT_EXTIF_ADDR" ; then
            _info "The IP address $POT_EXTIF_ADDR [POT_EXTIF_ADDR] is not available on the network interface $POT_EXTIF [POT_EXTIF]    "
			_ext_addr=
		else
			_ext_addr=$POT_EXTIF_ADDR
        fi
    fi
	# NAT rules
	(
		echo "ext_if = \"${POT_EXTIF}\""
		echo "localnet = \"${POT_NETWORK}\""
		if [ -n "$_ext_addr" ]; then
			echo "ext_addr = \"${_ext_addr}\""
			echo "nat on \$ext_if from \$localnet to any -> \$ext_addr"
		else
			echo "nat on \$ext_if from \$localnet to any -> (\$ext_if:0)"
		fi
	) > "$_nat_rules"

	# EXTRA_EXTIF NAT rules
	if [ -n "$POT_EXTRA_EXTIF" ]; then
		for extra_netif in $POT_EXTRA_EXTIF ; do
			eval extra_net="\$POT_NETWORK_$extra_netif"
			# shellcheck disable=SC2154
			if [ -n "$extra_net" ]; then
				echo "nat on $extra_netif from \$localnet to $extra_net -> ($extra_netif:0)" >> "$_nat_rules"
			fi
		done
	fi
	# VPN NAT rules
	if [ -n "$POT_VPN_EXTIF" ] && [ -n "$POT_VPN_NETWORKS" ]; then
		for net in $POT_VPN_NETWORKS ; do
			echo "nat on $POT_VPN_EXTIF from \$localnet to $net -> ($POT_VPN_EXTIF:0)" >> "$_nat_rules"
		done
	fi

	pfctl -a pot-nat -f "$_nat_rules"
	rm -f "$_nat_rules"
	# load the rules
	if _is_verbose ; then
		pfctl -s nat -a pot-nat
	fi
	pfctl -e
}

_ipv6_bridge_start()
{
	# shellcheck disable=SC3043
	local _bridge
	_bridge=$(_pot_bridge_ipv6)

	if [ -z "$_bridge" ]; then
		if _bridge=$(ifconfig bridge create) ; then
			_debug "Bridge created $_bridge"
		else
			_error "Bridge not created"
		fi
		if ! ifconfig "$_bridge" inet6 up ; then
			_error "Error during bridge configuration ($_bridge)"
		else
			_debug "Bridge $_bridge inet6 up"
		fi
		if ! ifconfig "$_bridge" addm "$POT_EXTIF" ; then
			_error "Error while adding $POT_EXTIF to the bridge ($_bridge)"
		else
			_debug "Bridge $_bridge addm $POT_EXTIF"
		fi
	else
		_debug "Bridge $_bridge already present"
	fi
}

_ipv6_start()
{
	_ipv6_bridge_start
}

# shellcheck disable=SC3033
pot-vnet-start()
{
	# shellcheck disable=SC3043
	local _bridge_name
	OPTIND=1
	while getopts "hvB:" _o ; do
		case "$_o" in
		h)
			vnet-start-help
			${EXIT} 0
			;;
		v)
			_POT_VERBOSITY=$(( _POT_VERBOSITY + 1))
			;;
		B)
			_bridge_name="$OPTARG"
			;;
		?)
			break
			;;
		esac
	done

	# Check configuration
	if [ -z "${POT_NETWORK}" ] || [ -z "${POT_GATEWAY}" ]; then
		_error "No network or gateway defined"
		exit 1
	fi
	if [ -z "${POT_EXTIF}" ]; then
		_error "No external interface defined"
		exit 1
	fi
	if ! _is_uid0 ; then
		${EXIT} 1
	fi
	if ! _is_pot_tmp_dir ; then
		_error "The POT_TMP directory is not available - aborting"
		${EXIT} 1
	fi

	case "$( _get_network_stack )" in
		ipv4)
			_ipv4_start "$_bridge_name"
			;;
		dual)
			_ipv4_start "$_bridge_name"
			_ipv6_start
			;;
		ipv6)
			_ipv6_start
			;;
	esac
}
