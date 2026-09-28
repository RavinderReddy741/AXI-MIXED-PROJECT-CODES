# ============================================================
# Makefile -- VCS V-2023.12 + UVM-1.1d
#
#   make compile DUT_FILELIST=<vivado export_simulation .f>
#   make run  TEST=axi_sanity_test [SEED=1] [VERB=UVM_MEDIUM]
#   make verdi
#   make all  TEST=...          (compile + run)
#   make regress                (all tests in TESTS)
#
# WAVEFORMS: -debug_access+all -kdb -lca are REQUIRED for FSDB to
# contain interface/class-visible values. Without them Verdi
# shows the signal names but no values.
#
# XILINX IP: the BD wrapper needs its IP sources + Xilinx sim libs
# (compile_simlib) + glbl.v elaborated as a SECOND TOP. Without
# glbl the IP primitives never leave GSR and all DUT outputs stay
# X/0. Generate the list with Vivado:
#   export_simulation -simulator vcs -directory ./export_sim
# and point DUT_FILELIST at it.
# ============================================================

TEST         ?= axi_sanity_test
SEED         ?= 1
VERB         ?= UVM_MEDIUM
DUT_FILELIST ?= dut_filelist.f
XIL_GLBL     ?= $(XILINX_VIVADO)/data/verilog/src/glbl.v
TOP          ?= tb_top
TESTS        ?= axi_sanity_test axi4lite_wr_rd_test axi3_rd_after_wr_test axi4_rd_after_wr_test
DUMP_DEFINE  ?=

VCS_OPTS = -full64 -sverilog -ntb_opts uvm-1.1 \
           -timescale=1ns/1ps \
           -debug_access+all -kdb -lca \
           +lint=PCWM +lint=TFIPC-L \
           -top $(TOP) -top glbl \
           $(DUT_DEFINES) $(DUMP_DEFINE) \
           -l compile.log

compile:
	vcs $(VCS_OPTS) -f $(DUT_FILELIST) $(XIL_GLBL) -f axi_filelist.f -o simv

run:
	./simv +UVM_TESTNAME=$(TEST) +ntb_random_seed=$(SEED) \
	       +UVM_VERBOSITY=$(VERB) -l $(TEST)_$(SEED).log

all: compile run

regress: compile
	@for t in $(TESTS); do \
	  ./simv +UVM_TESTNAME=$$t +ntb_random_seed=$(SEED) +UVM_VERBOSITY=UVM_LOW \
	         -l $${t}_$(SEED).log > /dev/null; \
	  if grep -q "TEST PASSED" $${t}_$(SEED).log; then echo "PASS  $$t"; \
	  else echo "FAIL  $$t  (see $${t}_$(SEED).log)"; fi; \
	done

verdi:
	verdi -ssf waves.fsdb -dbdir simv.daidir &

clean:
	rm -rf simv* csrc *.log *.fsdb *.vcd *.key ucli.key verdiLog novas* DVEfiles

.PHONY: compile run all regress verdi clean
