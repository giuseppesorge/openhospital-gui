#!/bin/bash
# Exercises the oh.sh changes on Linux, against the released portable package.
# The checked lines are taken out of oh.sh itself, so this cannot drift from the code.
fail=0
here=$(pwd)

echo "=== $(uname -s) $(uname -m) | bash $BASH_VERSION ==="

########################################################################
echo
echo "--- 1. oh.sh parses ---"
if bash -n ./oh.sh 2>/dev/null; then echo "  OK - no syntax errors"; else echo "  FAIL"; fail=$((fail+1)); fi

########################################################################
echo
echo "--- 2. database_port_open, taken from oh.sh, with no netcat on PATH ---"
# the defect this replaced: the wait used `nc -z`, and a machine without netcat
# span forever. The probe must not need it.
eval "$(awk '/^function database_port_open/,/^}/' ./oh.sh)"
if ! declare -f database_port_open >/dev/null; then
	echo "  FAIL - function not found in oh.sh"; fail=$((fail+1))
else
	if command -v nc >/dev/null 2>&1; then echo "  (netcat is present on this runner: hiding it)"; fi

	# An empty PATH, so `nc` cannot be found at all. bash is called by absolute path: with the PATH
	# cleared, `env bash` cannot even find bash, and the probe would never run - which earlier read
	# as "port closed" and let two of these three checks pass without having tested anything.
	# The result is therefore reported through a sentinel, and anything else is a failure.
	run_without_nc() {
		local out
		out=$(env -i PATH=/nonexistent /bin/bash -c "
			$(declare -f database_port_open)
			DATABASE_SERVER=$1; DATABASE_PORT=$2
			command -v nc >/dev/null 2>&1 && { echo NC_STILL_THERE; exit; }
			if database_port_open; then echo OPEN; else echo CLOSED; fi" 2>&1)
		case "$out" in
			OPEN) return 0 ;;
			CLOSED) return 1 ;;
			*) echo "  FAIL - the probe did not run: [$out]"; fail=$((fail+1)); return 2 ;;
		esac
	}

	DATABASE_SERVER=127.0.0.1; DATABASE_PORT=65041
	run_without_nc 127.0.0.1 65041; rc=$?
	case $rc in
		1) echo "  OK   closed port -> false, with no netcat reachable" ;;
		0) echo "  FAIL - closed port reported open"; fail=$((fail+1)) ;;
	esac

	python3 -c "
import socket, time, sys
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', 65041)); s.listen(50); s.settimeout(0.5)
stop = time.time() + 10
while time.time() < stop:
    try:
        c, _ = s.accept(); c.close()
    except socket.timeout: pass
" &
	listener=$!
	sleep 1
	run_without_nc 127.0.0.1 65041; rc=$?
	case $rc in
		0) echo "  OK   listening port -> true, with no netcat reachable" ;;
		1) echo "  FAIL - listening port reported closed"; fail=$((fail+1)) ;;
	esac
	kill $listener 2>/dev/null; wait $listener 2>/dev/null
	sleep 1
	run_without_nc 127.0.0.1 65041; rc=$?
	case $rc in
		1) echo "  OK   listener stopped -> false" ;;
		0) echo "  FAIL - still open after the listener stopped"; fail=$((fail+1)) ;;
	esac
fi

########################################################################
echo
echo "--- 3. an unfinished installation is told apart from a finished one ---"
# the expression oh.sh uses, taken from the file
expr_line=$(grep -o 'find \./"\$DATA_DIR" -mindepth 1 -maxdepth 1 -type d -iname "\$DATABASE_NAME" -print -quit' ./oh.sh | head -1)
if [ -z "$expr_line" ]; then
	echo "  FAIL - the datadir expression was not found in oh.sh"; fail=$((fail+1))
else
	echo "  expression: $expr_line"
	check_dir() { DATA_DIR=$1; DATABASE_NAME=$2; [ -z "$(eval "$expr_line" 2>/dev/null)" ] && echo unfinished || echo finished; }

	rm -rf /tmp/dd && mkdir -p /tmp/dd/data/db
	cd /tmp/dd
	got=$(check_dir data/db oh)
	[ "$got" = unfinished ] && echo "  OK   datadir with no schema -> unfinished" || { echo "  FAIL empty datadir -> $got"; fail=$((fail+1)); }

	mkdir -p data/db/oh
	got=$(check_dir data/db oh)
	[ "$got" = finished ] && echo "  OK   datadir with the schema -> finished" || { echo "  FAIL -> $got"; fail=$((fail+1)); }

	# lower_case_table_names: the engine stores a database named MyHospital as myhospital
	rm -rf data/db && mkdir -p data/db/myhospital
	got=$(check_dir data/db MyHospital)
	[ "$got" = finished ] && echo "  OK   schema dir in a different case -> finished" || { echo "  FAIL -> $got"; fail=$((fail+1)); }

	# without -mindepth 1 the find matches the starting directory itself; guard against
	# that regression, which would report every fresh installation as finished
	rm -rf data/db && mkdir -p data/db
	got=$(DATA_DIR=data/db DATABASE_NAME=db; [ -z "$(find ./"$DATA_DIR" -mindepth 1 -maxdepth 1 -type d -iname "$DATABASE_NAME" -print -quit 2>/dev/null)" ] && echo unfinished || echo finished)
	[ "$got" = unfinished ] && echo "  OK   a datadir whose own name matches -> still unfinished" || { echo "  FAIL -> $got"; fail=$((fail+1)); }
	cd "$here"
fi

########################################################################
echo
echo "--- 4. the real mysqld from the released package ---"
mysqld=$(find -L ./pkg \( -name mysqld -o -name mariadbd \) -type f 2>/dev/null | head -1)
if [ -z "$mysqld" ]; then
	# the portable package ships MariaDB, so not finding it means the lookup is wrong, not that
	# there is nothing to test. Saying SKIP here would quietly drop the main check of this platform.
	echo "  FAIL - no mysqld/mariadbd under ./pkg. What is there:"
	find -L ./pkg -maxdepth 3 -name 'maria*' -o -maxdepth 3 -name 'mysql*' 2>/dev/null | head -10 | sed 's/^/      /'
	find -L ./pkg -maxdepth 2 -type d 2>/dev/null | head -10 | sed 's/^/      /'
	fail=$((fail+1))
else
	echo "  using $mysqld"
	"$mysqld" --defaults-file=/nonexistent.cnf >/tmp/mysqld.out 2>&1 &
	pid=$!
	t0=$SECONDS; detected=no
	while [ $((SECONDS-t0)) -lt 30 ]; do
		if ! kill -0 $pid 2>/dev/null; then detected=yes; break; fi
		sleep 1
	done
	elapsed=$((SECONDS-t0))
	if [ "$detected" = yes ] && [ $elapsed -lt 15 ]; then
		echo "  OK   the dead server is seen after ${elapsed}s, not at the 90s timeout"
	else
		echo "  FAIL detected=$detected after ${elapsed}s"; fail=$((fail+1))
	fi
	echo "  mysqld said: $(head -2 /tmp/mysqld.out | tr '\n' ' ')"
fi

########################################################################
echo
echo "=== failures: $fail ==="
[ $fail -eq 0 ] || exit 1
