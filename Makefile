# REPO     ?= nkcluster
# RELOADER ?= -s nkreloader
DEPS     = _build/$(PROFILE)/lib/*/ebin

.PHONY: release dev

all: compile

compile: ; @rebar3 compile

clean: ; @rebar3 clean

distclean: ; @rebar3 clean -a

tests: eunit

eunit: export PROFILE    = test
eunit: export ERL_FLAGS  = -pa $(DEPS)
eunit: export ERL_FLAGS += -config test/app.config
eunit: export ERL_FLAGS += -args_file test/vm.args
eunit: ; @rebar3 eunit

shell: export PROFILE    = default
shell: export ERL_FLAGS  = -pa $(DEPS)
shell: export ERL_FLAGS += -config util/shell_app.config
shell: export ERL_FLAGS += -args_file util/shell_vm.args
# shell: export ERL_FLAGS += $(RELOADER)
shell: ; @rebar3 shell

shell-test: export PROFILE    = default
shell-test: export ERL_FLAGS  = -pa $(DEPS)
shell-test: export ERL_FLAGS += -config test/app.config
shell-test: export ERL_FLAGS += -args_file test/vm.args
# shell-test: export ERL_FLAGS += $(RELOADER)
shell-test: ; @rebar3 shell

docs: ; @rebar3 edoc

dev%: export NAME                 = $@@127.0.0.1
dev%: export RELX_REPLACE_OS_VARS = true
# dev%: export ERL_FLAGS = $(RELOADER)
dev%: ; @rebar3 as $@ run

dev: ; @rebar3 as dev run

dialyzer: ; @rebar3 dialyzer

build_tests: ; @rebar3 as test compile
