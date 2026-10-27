ERLC ?= erlc
ERL ?= erl
PYTHON ?= python3
EMACS ?= emacs
ERLFMT ?= erlfmt
FMT_FILES ?= src/*.erl src/*.app.src test/*.erl test/fixtures/*.erl test/fixtures/*.hrl rebar.config
BUILD := _build/default/lib/angler/ebin
TEST_BUILD := _build/test

.PHONY: all test test-emacs fmt clean
all:
	mkdir -p $(BUILD)
	$(ERLC) -Werror +debug_info -o $(BUILD) src/*.erl

test: all
	mkdir -p $(TEST_BUILD)
	$(ERLC) -Werror +debug_info -pa $(BUILD) -o $(TEST_BUILD) test/*.erl
	$(ERL) -noshell -pa $(BUILD) $(TEST_BUILD) -eval 'case eunit:test([ext_roundtrip_tests, ext_exports_tests, ext_snippet_tests, ext_types_tests, ext_records_tests], [verbose]) of ok -> halt(0); _ -> halt(1) end.'
	$(PYTHON) test/cli_test.py

test-emacs: all
	$(EMACS) -Q --batch -L emacs -l test/angler-emacs-tests.el -f ert-run-tests-batch-and-exit

fmt:
	$(ERLFMT) -w $(FMT_FILES)

clean:
	rm -rf _build
