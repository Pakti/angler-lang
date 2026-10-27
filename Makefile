ERLC ?= erlc
ERL ?= erl
PYTHON ?= python3
EMACS ?= emacs
BUILD := _build/test

.PHONY: all test test-emacs clean
all:
	mkdir -p $(BUILD)
	$(ERLC) -Werror +debug_info -o $(BUILD) src/*.erl

test: all
	$(ERLC) -Werror +debug_info -pa $(BUILD) -o $(BUILD) test/*.erl
	$(ERL) -noshell -pa $(BUILD) -eval 'case eunit:test([ext_roundtrip_tests, ext_exports_tests, ext_snippet_tests, ext_types_tests], [verbose]) of ok -> halt(0); _ -> halt(1) end.'
	$(PYTHON) test/cli_test.py

test-emacs: all
	$(EMACS) -Q --batch -L emacs -l test/angler-emacs-tests.el -f ert-run-tests-batch-and-exit

clean:
	rm -rf _build
