ERLC ?= erlc
ERL ?= erl
PYTHON ?= python3
EMACS ?= emacs
ERLANG_EMACS_DIR ?= $(shell $(ERL) -noshell -eval 'case code:lib_dir(tools) of {error, _} -> halt(1); Dir -> io:format("~ts", [filename:join(Dir, "emacs")]), halt() end.')
REBAR3 := rebar3
BUILD := _build/default/lib/angler/ebin
TEST_BUILD := _build/test

.PHONY: all test test-emacs fmt clean
all:
	mkdir -p $(BUILD)
	$(ERLC) -Werror +debug_info -o $(BUILD) src/*.erl

test: all
	mkdir -p $(TEST_BUILD)
	$(ERLC) -Werror +debug_info -pa $(BUILD) -o $(TEST_BUILD) test/*.erl
	# -pa prepends paths: put freshly compiled application modules first.
	$(ERL) -noshell -pa $(TEST_BUILD) -pa $(BUILD) -eval 'case eunit:test([ext_roundtrip_tests, ext_exports_tests, ext_snippet_tests, ext_types_tests, ext_records_tests, ext_build_tests], [verbose]) of ok -> halt(0); _ -> halt(1) end.'
	$(PYTHON) test/cli_test.py
	$(PYTHON) test/build_test.py

test-emacs: all
	$(EMACS) -Q --batch $(if $(ERLANG_EMACS_DIR),-L "$(ERLANG_EMACS_DIR)") -L emacs -l test/angler-emacs-tests.el -f ert-run-tests-batch-and-exit

fmt:
	$(REBAR3) fmt -w

clean:
	rm -rf _build
