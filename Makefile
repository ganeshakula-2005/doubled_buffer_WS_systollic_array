# ---- Configuration ----
TOP        := top
SRC_LIST   := sim/sources_sys_array.f
OBJ_DIR    := obj_dir
BIN_DIR    := bin
BIN        := $(BIN_DIR)/$(TOP)

VERILATOR  := verilator
VFLAGS     := --binary -j 0 -Wall --sv
VFLAGS     += --Mdir $(OBJ_DIR)
VFLAGS     += --top-module $(TOP)
VFLAGS	   += -f $(SRC_LIST)
VFLAGS     += -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-VARHIDDEN -Wno-TIMESCALEMOD -Wno-UNDRIVEN
VFLAGS   += --trace

# ---- Targets ----
.PHONY: all sim run clean

all: sim

sim: $(SRC_LIST)
	$(VERILATOR) $(VFLAGS) 
	mkdir -p $(BIN_DIR)
	cp $(OBJ_DIR)/V$(TOP) $(BIN)

run: sim
	./$(BIN)

clean:
	rm -rf $(OBJ_DIR) $(BIN_DIR)