#!/bin/bash

# see https://github.com/docker-library/mongo/issues/147 (mongod is picky about duplicated arguments)
_mongod_hack_have_arg() {
	local checkArg="$1"; shift
	for arg; do
		case "$arg" in
			"$checkArg"|"$checkArg"=*)
				return 0
				;;
		esac
	done
	return 1
}
declare -a mongodHackedArgs
# _mongod_hack_ensure_arg '--some-arg' "$@"
# set -- "${mongodHackedArgs[@]}"
_mongod_hack_ensure_arg() {
	local ensureArg="$1"; shift
	mongodHackedArgs=( "$@" )
	if ! _mongod_hack_have_arg "$ensureArg" "$@"; then
		mongodHackedArgs+=( "$ensureArg" )
	fi
}
# _mongod_hack_ensure_arg_val '--some-arg' 'some-val' "$@"
# set -- "${mongodHackedArgs[@]}"
_mongod_hack_ensure_arg_val() {
	local ensureArg="$1"; shift
	local ensureVal="$1"; shift
	mongodHackedArgs=()
	while [ "$#" -gt 0 ]; do
		arg="$1"; shift
		case "$arg" in
			"$ensureArg")
				shift # also skip the value
				continue
				;;
			"$ensureArg"=*)
				# value is already included
				continue
				;;
		esac
		mongodHackedArgs+=( "$arg" )
	done
	mongodHackedArgs+=( "$ensureArg" "$ensureVal" )
}
# TODO what do to about "--config" ? :(

if [ "$USERNAME" ] && [ "$PASSWORD" ]; then
	_mongod_hack_ensure_arg '--auth' "$@"
	set -- "${mongodHackedArgs[@]}"

	# check for a few known paths (to determine whether we've already initialized and should thus skip our initdb scripts)
	definitelyAlreadyInitialized=
	for path in \
		/data/db/WiredTiger \
		/data/db/journal \
		/data/db/local.0 \
		/data/db/storage.bson \
	; do
		if [ -e "$path" ]; then
			definitelyAlreadyInitialized="$path"
			break
		fi
	done

	if [ -z "$definitelyAlreadyInitialized" ]; then
		if _mongod_hack_have_arg --config "$@"; then
			echo >&2
			echo >&2 'warning: database is not yet initialized, and "--config" is specified'
			echo >&2 '  the initdb database startup might fail as a result!'
			echo >&2
		fi

		pidfile="$(mktemp)"
		trap "rm -f '$pidfile'" EXIT

		_mongod_hack_ensure_arg_val --bind_ip 127.0.0.1 "$@"
		_mongod_hack_ensure_arg_val --port 27017 "${mongodHackedArgs[@]}"

		sslMode="$(_mongod_hack_have_arg '--sslPEMKeyFile' "$@" && echo 'allowSSL' || echo 'disabled')" # "BadValue: need sslPEMKeyFile when SSL is enabled" vs "BadValue: need to enable SSL via the sslMode flag when using SSL configuration parameters"
		_mongod_hack_ensure_arg_val --sslMode "$sslMode" "${mongodHackedArgs[@]}"

		if stat "/proc/$$/fd/1" > /dev/null && [ -w "/proc/$$/fd/1" ]; then
			# https://github.com/mongodb/mongo/blob/38c0eb538d0fd390c6cb9ce9ae9894153f6e8ef5/src/mongo/db/initialize_server_global_state.cpp#L237-L251
			# https://github.com/docker-library/mongo/issues/164#issuecomment-293965668
			_mongod_hack_ensure_arg_val --logpath "/proc/$$/fd/1" "${mongodHackedArgs[@]}"
		else
			echo >&2 "warning: initdb logs cannot write to '/proc/$$/fd/1', so they are in '/data/db/docker-initdb.log' instead"
			_mongod_hack_ensure_arg_val --logpath /data/db/docker-initdb.log "${mongodHackedArgs[@]}"
		fi
		_mongod_hack_ensure_arg --logappend "${mongodHackedArgs[@]}"

		_mongod_hack_ensure_arg_val --pidfilepath "$pidfile" "${mongodHackedArgs[@]}"
		"${mongodHackedArgs[@]}" --fork

		mongo=( mongo --host 127.0.0.1 --port 27017 --quiet )

		# check to see that our "mongod" actually did start up (catches "--help", "--version", MongoDB 3.2 being silly, slow prealloc, etc)
		# https://jira.mongodb.org/browse/SERVER-16292
		tries=30
		while true; do
			if ! { [ -s "$pidfile" ] && ps "$(< "$pidfile")" &> /dev/null; }; then
				# bail ASAP if "mongod" isn't even running
				echo >&2
				echo >&2 "error: $originalArgOne does not appear to have stayed running -- perhaps it had an error?"
				echo >&2
				exit 1
			fi
			if "${mongo[@]}" 'admin' --eval 'quit(0)' &> /dev/null; then
				# success!
				break
			fi
			(( tries-- ))
			if [ "$tries" -le 0 ]; then
				echo >&2
				echo >&2 "error: $originalArgOne does not appear to have accepted connections quickly enough -- perhaps it had an error?"
				echo >&2
				exit 1
			fi
			sleep 1
		done

		if [ "$USERNAME" ] && [ "$PASSWORD" ]; then
			rootAuthDatabase='admin'

			"${mongo[@]}" "$rootAuthDatabase" <<-EOJS
				db.createUser({
					user: $(jq --arg 'user' "$USERNAME" --null-input '$user'),
					pwd: $(jq --arg 'pwd' "$PASSWORD" --null-input '$pwd'),
					roles: [ { role: 'root', db: $(jq --arg 'db' "$rootAuthDatabase" --null-input '$db') } ]
				})
			EOJS

			mongo+=(
				--username="$USERNAME"
				--password="$PASSWORD"
				--authenticationDatabase="$rootAuthDatabase"
			)
		fi

		export DATABASE="${DATABASE:-test}"

		echo
		for f in /docker-entrypoint-initdb.d/*; do
			case "$f" in
				*.sh) echo "$0: running $f"; . "$f" ;;
				*.js) echo "$0: running $f"; "${mongo[@]}" "$DATABASE" "$f"; echo ;;
				*)    echo "$0: ignoring $f" ;;
			esac
			echo
		done

		"$@" --pidfilepath="$pidfile" --shutdown
		rm "$pidfile"
		trap - EXIT

		echo
		echo 'MongoDB init process complete; ready for start up.'
		echo
	fi

	unset USERNAME
	unset PASSWORD
	unset DATABASE
fi

exec "$@"
