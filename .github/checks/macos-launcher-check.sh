#!/bin/bash
# Exercises the ohmac.sh changes on macOS. Everything above the first top-level call is
# sourced, so the functions under test are the ones in the file, not copies of them.
fail=0
here=$(pwd)

echo "=== $(uname -s) $(uname -m) | bash $BASH_VERSION ==="

########################################################################
echo
echo "--- 1. ohmac.sh parses ---"
if bash -n ./ohmac.sh 2>/dev/null; then echo "  OK - no syntax errors"; else echo "  FAIL"; fail=$((fail+1)); fi

line=$(grep -n '^read_settings;' ./ohmac.sh | head -1 | cut -d: -f1)
if [ -z "$line" ]; then echo "  FAIL - cannot locate the end of the definitions"; exit 1; fi
head -n $((line-1)) ./ohmac.sh > /tmp/ohmac_defs.sh
echo "  definitions taken from rows 1-$((line-1))"

########################################################################
echo
echo "--- 2. the settings file is read back, so the API server and the web UI are reachable ---"
sandbox=/tmp/ohmac-sandbox
rm -rf $sandbox && mkdir -p $sandbox/oh/rsc
dist=$(find -L ./pkg -name 'settings.properties.dist' 2>/dev/null | head -1)
if [ -z "$dist" ]; then
	echo "  SKIP - settings.properties.dist not found under ./pkg"
else
	cp "$dist" $sandbox/oh/rsc/
	api_dist=$(find -L ./pkg -name 'application.properties.dist' 2>/dev/null | head -1)
	[ -n "$api_dist" ] && cp "$api_dist" $sandbox/oh/rsc/
	printf 'VER_MAJOR=1\nVER_MINOR=15\nVER_RELEASE=0\n' > $sandbox/oh/rsc/version.properties

	cd $sandbox
	source /tmp/ohmac_defs.sh >/dev/null 2>&1
	unset EXPERT_MODE API_SERVER GUI_INTERFACE UI_INTERFACE APISERVER

	read_settings >/dev/null 2>&1; set_defaults
	if [ "$API_SERVER" = off ] && [ "$GUI_INTERFACE" = on ] && [ "$UI_INTERFACE" = off ]; then
		echo "  OK   no settings file -> defaults off/on/off"
	else
		echo "  FAIL defaults were $API_SERVER/$GUI_INTERFACE/$UI_INTERFACE"; fail=$((fail+1))
	fi

	# write the settings the way -U leaves them, then read them back as a restart would
	API_SERVER=on; GUI_INTERFACE=off; UI_INTERFACE=on
	OH_SINGLE_USER=no; DEMO_DATA=off
	write_config_files >/dev/null 2>&1
	written=$(grep -E '^APISERVER|^GUI_INTERFACE|^UI_INTERFACE' ./oh/rsc/settings.properties | tr '\n' ' ')
	echo "  written: $written"
	unset API_SERVER GUI_INTERFACE UI_INTERFACE APISERVER
	read_settings >/dev/null 2>&1; set_defaults
	if [ "$API_SERVER" = on ] && [ "$UI_INTERFACE" = on ] && [ "$GUI_INTERFACE" = off ]; then
		echo "  OK   read back on/off/on: start_api_server and start_ui are reachable"
	else
		echo "  FAIL read back $API_SERVER/$GUI_INTERFACE/$UI_INTERFACE"; fail=$((fail+1))
	fi
	if grep -q '^GUI_INTERFACE=' ./oh/rsc/settings.properties; then echo "  OK   the GUI_INTERFACE key survived"
	else echo "  FAIL the GUI_INTERFACE key was lost"; fail=$((fail+1)); fi
	cd "$here"
fi

########################################################################
echo
echo "--- 3. the API configuration is written from the template, leaving no placeholder ---"
cd $sandbox 2>/dev/null || cd "$here"
if [ -f ./oh/rsc/application.properties.dist ]; then
	source /tmp/ohmac_defs.sh >/dev/null 2>&1
	WRITE_CONFIG_FILES=on
	write_api_config_file >/dev/null 2>&1
	if [ -f ./oh/rsc/application.properties ]; then
		if grep -qE 'API_HOST|API_PORT|UI_HOST|UI_PORT|OH_API_PID|JWT_TOKEN_SECRET' ./oh/rsc/application.properties; then
			echo "  FAIL placeholders left:"; grep -nE 'API_HOST|UI_HOST|OH_API_PID|JWT_TOKEN_SECRET' ./oh/rsc/application.properties | head -3
			fail=$((fail+1))
		else echo "  OK   no placeholder left"; fi
		grep -q 'API_HOST:API_PORT' ./oh/rsc/application.properties.dist \
			&& echo "  OK   the template is untouched" \
			|| { echo "  FAIL the template was consumed"; fail=$((fail+1)); }
	else
		echo "  FAIL application.properties was not written"; fail=$((fail+1))
	fi
else
	# the client package carries no API server, and write_api_config_file is reached there all the
	# same. Before OP-1449 it failed with sed/cp errors against a path at the filesystem root; it
	# now has to say so and return, leaving nothing behind.
	source /tmp/ohmac_defs.sh >/dev/null 2>&1
	WRITE_CONFIG_FILES=on
	out=$(write_api_config_file 2>&1); rc=$?
	if [ $rc -ne 0 ]; then echo "  FAIL returned $rc where no template ships"; fail=$((fail+1))
	elif [ -f ./oh/rsc/application.properties ]; then echo "  FAIL wrote a configuration with no template"; fail=$((fail+1))
	elif ! printf '%s' "$out" | grep -qi 'does not include the API server'; then
		echo "  FAIL said nothing useful: $out"; fail=$((fail+1))
	else
		echo "  OK   no API template -> warns and returns, writing nothing"
	fi
	printf '%s' "$out" | grep -qiE 'sed:|cp:|No such file' \
		&& { echo "  FAIL shell errors leaked: $out"; fail=$((fail+1)); } \
		|| echo "  OK   no sed/cp error leaked"
fi
cd "$here"

########################################################################
echo
echo "--- 4. -E and -U toggle, and the advanced menu lists what the script implements ---"
(
	source /tmp/ohmac_defs.sh >/dev/null 2>&1
	# from a clean slate: set_defaults deliberately leaves a value that is already set, so a
	# variable left behind by an earlier check would silently decide the outcome here
	unset EXPERT_MODE API_SERVER GUI_INTERFACE UI_INTERFACE
	set_defaults
	parse_user_input E 1 </dev/null >/dev/null 2>&1
	[ "$EXPERT_MODE" = on ] && echo "  OK   -E turns expert mode on" || { echo "  FAIL -E left $EXPERT_MODE"; exit 1; }
	parse_user_input U 1 </dev/null >/dev/null 2>&1
	[ "$UI_INTERFACE" = on ] && [ "$GUI_INTERFACE" = off ] && echo "  OK   -U turns the web UI on and the Swing GUI off" || { echo "  FAIL -U left $UI_INTERFACE/$GUI_INTERFACE"; exit 1; }
	EXPERT_MODE=on OH_VERSION=1.15.0 ARCH=arm64 script_menu 2>&1 | grep -q -- '-U  enable UI web interface' \
		&& echo "  OK   the advanced menu is reachable and lists -U" || { echo "  FAIL the advanced menu does not list -U"; exit 1; }
) || fail=$((fail+1))

########################################################################
echo
echo "--- 5. the database waits are bounded ---"
(
	source /tmp/ohmac_defs.sh >/dev/null 2>&1
	DATABASE_SERVER=127.0.0.1; DATABASE_PORT=65042; DATABASE_WAIT_TIMEOUT=3
	t0=$SECONDS
	( wait_for_database ) >/dev/null 2>&1; rc=$?
	el=$((SECONDS-t0))
	[ $rc -eq 2 ] && [ $el -ge 2 ] && [ $el -le 6 ] \
		&& echo "  OK   a port that never opens gives up after ${el}s with code $rc" \
		|| { echo "  FAIL rc=$rc after ${el}s"; exit 1; }
) || fail=$((fail+1))

########################################################################
echo
echo "=== failures: $fail ==="
[ $fail -eq 0 ] || exit 1
