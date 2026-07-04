#!/usr/bin/env bats
#
# appliance-kasmvnc.bats
# Tests for the kasmVNC profile (appliance/lib/profiles/kasmvnc.sh)
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	# shellcheck source=appliance/lib/common.sh
	source "$SCRIPT_DIR/../appliance/lib/common.sh"
	# shellcheck source=appliance/lib/profiles/kasmvnc.sh
	source "$SCRIPT_DIR/../appliance/lib/profiles/kasmvnc.sh"
	appliance_dry_run=0
	appliance_force=0
}

teardown() {
	[[ -n $TEST_TMP && -d $TEST_TMP ]] && rm -rf "$TEST_TMP"
}

@test "kasmvnc_gen_password: 16 alphanumeric chars" {
	local pw
	pw=$(kasmvnc_gen_password)
	[[ ${#pw} -eq 16 ]]
	[[ $pw =~ ^[A-Za-z0-9]+$ ]]
}

@test "setup_auth: dry-run creates nothing" {
	user_home() { printf '%s' "$TEST_TMP/home"; }
	appliance_dry_run=1
	run profile_kasmvnc_setup_auth alice
	[[ $status -eq 0 ]]
	[[ $output == *'DRY-RUN: create kasmvnc control user for alice'* ]]
	[[ ! -e $TEST_TMP/home/.kasmpasswd ]]
}

@test "setup_auth: creates control user non-interactively and stores creds" {
	mkdir -p "$TEST_TMP/home/.vnc"
	user_home() { printf '%s' "$TEST_TMP/home"; }
	chown() { return 0; }
	# capture that kasmvncpasswd is fed the password twice on stdin
	runuser() {
		shift 3  # -u alice --
		if [[ $1 == kasmvncpasswd ]]; then
			local in; in=$(cat)
			printf '%s' "$in" > "$TEST_TMP/pw-stdin"
			printf '%s\n' "$*" > "$TEST_TMP/pw-argv"
			return 0
		fi
		"$@"
	}
	run profile_kasmvnc_setup_auth alice
	[[ $status -eq 0 ]]
	# argv: kasmvncpasswd -u alice -w
	grep -q -- '-u alice -w' "$TEST_TMP/pw-argv"
	# stdin had the password twice (two identical non-empty lines)
	local l1 l2
	l1=$(sed -n 1p "$TEST_TMP/pw-stdin"); l2=$(sed -n 2p "$TEST_TMP/pw-stdin")
	[[ -n $l1 && $l1 == "$l2" ]]
	# credentials persisted, mode 600
	[[ -f $TEST_TMP/home/.vnc/kasm-credentials ]]
	grep -q '^username=alice$' "$TEST_TMP/home/.vnc/kasm-credentials"
	grep -q '^password=' "$TEST_TMP/home/.vnc/kasm-credentials"
	[[ $(stat -c '%a' "$TEST_TMP/home/.vnc/kasm-credentials") == 600 ]]
}

@test "setup_auth: idempotent when kasmpasswd already exists" {
	mkdir -p "$TEST_TMP/home"
	printf 'existing' > "$TEST_TMP/home/.kasmpasswd"
	user_home() { printf '%s' "$TEST_TMP/home"; }
	run profile_kasmvnc_setup_auth alice
	[[ $status -eq 0 ]]
	[[ $output == *'already configured'* ]]
}

@test "setup_auth: fails loudly when kasmvncpasswd errors" {
	mkdir -p "$TEST_TMP/home/.vnc"
	user_home() { printf '%s' "$TEST_TMP/home"; }
	runuser() { shift 3; [[ $1 == kasmvncpasswd ]] && { cat >/dev/null; return 1; }; "$@"; }
	run profile_kasmvnc_setup_auth alice
	[[ $status -ne 0 ]]
	[[ $output == *'kasmvncpasswd failed'* ]]
}

@test "install_packages: generates snakeoil cert when missing" {
	# stub the network + package steps; assert the snakeoil gen runs
	appliance_distro_codename() { printf 'noble'; }
	appliance_arch() { printf 'amd64'; }
	command() {
		if [[ $1 == '-v' && $2 == 'kasmvncserver' ]]; then return 0; fi
		if [[ $1 == '-v' ]]; then return 0; fi
		builtin command "$@"
	}
	dpkg() { return 0; }
	pkg_install() { return 0; }
	export APPLIANCE_SNAKEOIL="$TEST_TMP/snakeoil.key"  # absent
	local ran=""
	run_cmd() { [[ $1 == make-ssl-cert ]] && printf 'GEN\n' >> "$TEST_TMP/ran"; return 0; }
	# point the check at a path that doesn't exist by shadowing test -f
	# via a wrapper: run the function; snakeoil path is hardcoded, so
	# we assert make-ssl-cert was invoked when the real path is absent.
	if [[ -f /etc/ssl/private/ssl-cert-snakeoil.key ]]; then
		skip 'host already has snakeoil cert'
	fi
	run profile_kasmvnc_install_packages
	[[ $status -eq 0 ]]
	grep -q GEN "$TEST_TMP/ran"
}
