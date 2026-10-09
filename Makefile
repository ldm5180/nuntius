# Thin wrapper around Alire + gprbuild so the common flows are one word.  Every
# target runs through `alr` (so the aws/utilada/aunit/gnatprove dependencies
# resolve).  The tests and examples build in two profiles selected with -XMODE
# (sml-ada convention): release (-O3) and debug (-O0).

EX := -P example/example.gpr

.PHONY: all build test features features-report prove format example release debug run clean help

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

## features    Build and run the Gherkin features in both modes, printing
##             the runner's report as it goes -- in colour when make writes
##             to a terminal: fabula colours only a terminal, so the runner
##             then runs under script(1) for a pseudo-terminal while tee
##             keeps a copy.  fabula exits 0 for a missing path or an empty
##             file, so the summary line, not the exit status alone, is
##             what says every scenario passed
features:
	alr exec -- gprbuild -p -j0 -XMODE=debug -P tests/test_nuntius.gpr
	alr exec -- gprbuild -p -j0 -XMODE=release -P tests/test_nuntius.gpr
	@log=$$(mktemp) && rc=$$(mktemp) && trap 'rm -f $$log $$rc' EXIT && \
	if [ -t 1 ]; then tty=yes; else tty=; fi; \
	for mode in debug release; do \
	  echo "== features ($$mode)"; \
	  run="alr exec -- tests/bin/$$mode/nuntius_features tests/features"; \
	  { if [ -n "$$tty" ]; then script -qefc "$$run" /dev/null; \
	    else $$run; fi; echo $$? > $$rc; } | tee $$log; \
	  [ "$$(cat $$rc)" = 0 ] || \
	    { echo "features: $$mode: the runner failed"; exit 1; }; \
	  sed -e 's/\x1b\[[0-9;]*m//g' -e 's/\r$$//' $$log | \
	    grep -qE '^[1-9][0-9]* Scenarios? \([0-9]+ passed\)$$' || \
	    { echo "features: $$mode: a scenario did not pass"; exit 1; }; \
	done; echo 'features: every scenario passed in both modes'

## features-report  The living documentation: run the features (release)
##             with --report-json and render it into
##             obj/features-report/html with multiple-cucumber-html-reporter
##             (tools/features-report).  The page is made even when a
##             scenario fails -- that is when it is most worth reading --
##             and the target then fails with the runner.
features-report:
	alr exec -- gprbuild -p -j0 -XMODE=release -P tests/test_nuntius.gpr
	@rm -rf obj/features-report && mkdir -p obj/features-report/json
	@alr exec -- tests/bin/release/nuntius_features tests/features \
	   --report-json obj/features-report/json/features.json; rc=$$?; \
	 npm ci --prefix tools/features-report --no-audit --no-fund && \
	 node tools/features-report/report.js obj/features-report/json \
	   obj/features-report/html && exit $$rc

## prove       Run the SPARK proof (same flags as CI), bounded in time
#  PROVE_TIMEOUT only stops a wedged run.  phase1_guard.py first drops
#  gnatprove's phase-1 ALIs when a `gnatprove -u` left two of them
#  disagreeing on a source's checksum: from there gnatprove's own
#  gprbuild re-reads an ALI its compiler is rewriting and spins until
#  killed.  Its selftest runs first.  The lock holds the guard and
#  gnatprove together, because two gnatprove runs on one tree corrupt
#  each other's output.
PROVE_TIMEOUT ?= 30m
PROVE_OBJ := proof/obj
prove:
	python3 tools/phase1_guard.py --selftest
	@mkdir -p $(PROVE_OBJ)
	flock $(PROVE_OBJ)/.prove.lock sh -c '\
	  python3 tools/phase1_guard.py --obj $(PROVE_OBJ) \
	    proof/src src/core && \
	  timeout $(PROVE_TIMEOUT) alr exec -- gnatprove -P proof/proof.gpr \
	    -j0 --level=2 --checks-as-errors=on --warnings=error'

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
