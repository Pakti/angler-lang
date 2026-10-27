ERLC ?= erlc
ERL ?= erl
BUILD := _build/test

.PHONY: all test clean
all:
	mkdir -p $(BUILD)
	$(ERLC) -Werror +debug_info -o $(BUILD) src/*.erl

test: all
	$(ERLC) -Werror +debug_info -pa $(BUILD) -o $(BUILD) test/*.erl
	$(ERL) -noshell -pa $(BUILD) -eval 'case eunit:test([ext_roundtrip_tests, ext_exports_tests], [verbose]) of ok -> halt(0); _ -> halt(1) end.'

clean:
	rm -rf _build
