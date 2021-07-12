#!/bin/sh
:

# shellcheck disable=SC3033
set-env-help() {
	echo "pot set-env [-hv] -p pot -E env"
	echo '  -h print this help'
	echo '  -v verbose'
	echo '  -p pot : the working pot'
	echo '  -E var=value : the variable and the value to be added'
	echo '     this option can be repeated more than once'
}

# $1 pot
# $2 env
_set_environment()
{
	# shellcheck disable=SC3043
	local _pname _tmpfile _cfile
	_pname="$1"
	_tmpfile="$2"
	_cfile=$POT_FS_ROOT/jails/$_pname/conf/pot.conf
	${SED} -i '' -e "/^pot.env=.*/d" "$_cfile"
	sed 's/.*/pot.env=&/g' "$_tmpfile" >> "$_cfile"
}

# shellcheck disable=SC3033
pot-set-env()
{
	# shellcheck disable=SC3043
	local _pname _env _tmpfile
	_env=
	_pname=
	if ! _is_pot_tmp_dir ; then
		_error "Failed to create the POT_TMP directory"
		return 1
	fi
	_tmpfile="$(mktemp "${POT_TMP:-/tmp}/pot-set-env${POT_MKTEMP_SUFFIX}")" || exit 1
	OPTIND=1
	while getopts "hvp:E:" _o ; do
		case "$_o" in
		h)
			set-env-help
			return 0
			;;
		v)
			_POT_VERBOSITY=$(( _POT_VERBOSITY + 1))
			;;
		E)
			if [ "$OPTARG" = "${OPTARG#*=}" ]; then
				# the argument doesn't have an equal sign
				_error "$OPTARG not in a valid form"
				_error "VARIABLE=value is accetped"
				set-env-help
				return 1
			fi
			_tmp="$( echo "$OPTARG" | sed 's%"%\\"%g' )"
			echo "\"$_tmp\"" >> "$_tmpfile"
			_env=1
			;;
		p)
			_pname="$OPTARG"
			;;
		?)
			set-env-help
			return 1
		esac
	done

	if [ -z "$_pname" ]; then
		_error "A pot name is mandatory"
		set-env-help
		return 1
	fi
	if [ -z "$_env" ]; then
		_error "A command is mandatory"
		set-env-help
		return 1
	fi
	if ! _is_pot "$_pname" ; then
		_error "pot $_pname is not valid"
		set-env-help
		return 1
	fi
	if ! _is_uid0 ; then
		return 1
	fi
	_set_environment "$_pname" "$_tmpfile"
	rm -f "$_tmpfile"
}
