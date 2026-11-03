# Sourced by the tests that run git for real. isolate_git <dir> gives git its own empty global config in <dir> and no
# system config, so nothing of the machine's (core.hooksPath above all, which install.sh sets for the review gate's
# pre-push check; signing; templates) reaches a test repo. A test that wants a global setting sets it afterwards.
isolate_git() {
	GIT_CONFIG_GLOBAL=$1/gitconfig-global
	: >"$GIT_CONFIG_GLOBAL"
	GIT_CONFIG_NOSYSTEM=1
	export GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM
}
