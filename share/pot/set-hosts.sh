#!/bin/sh
:

# shellcheck disable=SC3033
set-hosts-help() {
	echo "pot set-hosts [-hv] -p pot -H env"
	echo '  -h print this help'
	echo '  -v verbose'
	echo '  -p pot : the working pot'
	echo '  -H hostname:IP : the hostname and the ip to be added in the /etc/hosts'
	echo '     this option can be repeated more than once'
}

# $1 pot
# $2 hostfile
_set_hosts()
{
	# shellcheck disable=SC3043
	local _pname _tmpfile _cfile
	_pname="$1"
	_tmpfile="$2"
	_cfile=$POT_FS_ROOT/jails/$_pname/conf/pot.conf
	${SED} -i '' -e "/^pot.hosts=.*/d" "$_cfile"
	sed 's/.*/pot.hosts=&/g' "$_tmpfile" >> "$_cfile"
}

# shellcheck disable=SC3033
pot-set-hosts()
{
	# shellcheck disable=SC3043
	local _pname _tmpfile _ip _hostname
	_pname=
	if ! _is_pot_tmp_dir ; then
		_error "Failed to create the POT_TMP directory"
		return 1
	fi
	_tmpfile="$(mktemp "${POT_TMP:-/tmp}/pot-set-hosts${POT_MKTMP_SUFFIX}")" || exit 1
	OPTIND=1
	while getopts "hvp:H:" _o ; do
		case "$_o" in
		h)
			set-hosts-help
			return 0
			;;
		v)
			_POT_VERBOSITY=$(( _POT_VERBOSITY + 1))
			;;
		H)
			if [ "$OPTARG" = "${OPTARG#*:}" ]; then
				# the argument doesn't have an equal sign
				_error "$OPTARG not in a valid form"
				_error "hostname:IP is accepted"
				set-hosts-help
				return 1
			fi
			# validate IP address
			_ip="${OPTARG#*:}"
			_hostname="${OPTARG%%:*}"
			if [ -z "$_ip" ] || [ -z "$_hostname" ]; then
				_error "Submitted ip or hostname are empty"
				set-hosts-help
				return 1
			fi
			if ! potnet ipcheck -H "$_ip" ; then
				_error "Submitted ip $_ip is not a valid one"
				set-hosts-help
				return 1
			fi
			echo "$_ip $_hostname" >> "$_tmpfile"
			;;
		p)
			_pname="$OPTARG"
			;;
		?)
			set-hosts-help
			return 1
		esac
	done

	if [ -z "$_pname" ]; then
		_error "A pot name is mandatory"
		set-hosts-help
		return 1
	fi
	if ! _is_pot "$_pname" ; then
		_error "pot $_pname is not valid"
		set-hosts-help
		return 1
	fi
	if ! _is_uid0 ; then
		return 1
	fi
	_set_hosts "$_pname" "$_tmpfile"
	rm -f "$_tmpfile"
}
