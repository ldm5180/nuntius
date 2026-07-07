# Thin wrapper around Alire + gprbuild so the common flows are one word.  Every
# target runs through `alr` (so the aws/utilada/aunit/gnatprove dependencies
# resolve).  The tests and examples build in two profiles selected with -XMODE
# (sml-ada convention): release (-O3) and debug (-O0).

EX := -P example/example.gpr

.PHONY: all build test prove format example release debug run clean help

all: build

## build       Build the library
build:
	alr build

## test        Build and run the AUnit suite in both modes (per-test output)
test:
	alr exec -- gprbuild -p -j0 -XMODE=debug -P tests/test_nuntius.gpr
	alr exec -- tests/bin/debug/test_runner
	alr exec -- gprbuild -p -j0 -XMODE=release -P tests/test_nuntius.gpr
	alr exec -- tests/bin/release/test_runner

## prove       Run the SPARK proof (same flags as CI)
prove:
	alr exec -- gnatprove -P proof/proof.gpr -j0 --level=2 --checks-as-errors=on

## format      Check formatting (per project, explicit files; no warnings)
format:
	alr exec -- gnatformat -P nuntius.gpr --check $$(git ls-files 'src/*/*.ad[sb]')
	alr exec -- gnatformat -P tests/test_nuntius.gpr --check $$(git ls-files 'tests/src/*.ad[sb]')
	alr exec -- gnatformat -P example/example.gpr --check $$(git ls-files 'example/src/*.ad[sb]')
	alr exec -- gnatformat -P proof/proof.gpr --check $$(git ls-files 'proof/src/*.ad[sb]')

## example     Build the examples both ways (they talk to real endpoints,
##             so CI builds them and running is manual)
example: release debug

## release     Build the examples (-O3)
release:
	alr exec -- gprbuild -p -j0 -XMODE=release $(EX)

## debug       Build the examples (-O0)
debug:
	alr exec -- gprbuild -p -j0 -XMODE=debug $(EX)

## run         Build and run the release http_get example (needs a network)
run: release
	./example/bin/release/http_get

## clean       Remove all build artifacts
clean:
	-alr exec -- gprclean -q -XMODE=release $(EX)
	-alr exec -- gprclean -q -XMODE=debug $(EX)
	alr clean

## help        List targets
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /  /'
