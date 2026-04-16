// Verilator C++ testbench for the Stage-0 SoC.
//
// Responsibilities:
//   - parse cmdline: +elf=<path> +timeout=<cycles> +trace=<path> +vcd=<path>
//   - load the ELF into the SoC's SRAM via the DPI backdoor (sram_dpi_write)
//   - resolve `tohost` / `fromhost` from the ELF symbol table (riscv-tests convention)
//   - run the clock, dump a per-instruction commit trace if requested
//   - exit on any of:
//       * MMIO exit register fired (user code wrote 0xD058_0004)
//       * tohost poll saw a non-zero value (riscv-tests convention: 1 = pass, else = 2*fail+1)
//       * cycle cap reached
//       * SV assertion / finish

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <memory>
#include <stdexcept>

#include <verilated.h>
#include <svdpi.h>
#if VM_TRACE
#include <verilated_vcd_c.h>
#endif

#include "Vsoc_tb_top.h"
#include "Vsoc_tb_top__Dpi.h"

#include "elf_loader.h"

static uint64_t g_cycles = 0;
double sc_time_stamp() { return double(g_cycles); }

static void usage(const char* argv0) {
    std::fprintf(stderr,
        "usage: %s +elf=<path> [+timeout=<cycles>] [+trace=<path>] [+vcd=<path>]\n",
        argv0);
    std::exit(1);
}

// Read a plusarg of the form "+<name>=<value>" from argv, or return nullptr.
static const char* plusarg(int argc, char** argv, const char* name) {
    size_t nlen = std::strlen(name);
    for (int i = 1; i < argc; ++i) {
        if (argv[i][0] == '+' && std::strncmp(argv[i] + 1, name, nlen) == 0 && argv[i][1 + nlen] == '=') {
            return argv[i] + 2 + nlen;
        }
    }
    return nullptr;
}

static bool has_plusarg(int argc, char** argv, const char* name) {
    size_t nlen = std::strlen(name);
    for (int i = 1; i < argc; ++i) {
        if (argv[i][0] == '+' && std::strncmp(argv[i] + 1, name, nlen) == 0) {
            return true;
        }
    }
    return false;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    const char* elf_path = plusarg(argc, argv, "elf");
    if (!elf_path) usage(argv[0]);
    const char* timeout_s = plusarg(argc, argv, "timeout");
    uint64_t timeout = timeout_s ? std::strtoull(timeout_s, nullptr, 0) : 2'000'000ULL;
    const char* trace_path = plusarg(argc, argv, "trace");
    const char* vcd_path   = plusarg(argc, argv, "vcd");
    bool quiet = has_plusarg(argc, argv, "quiet");

    auto top = std::make_unique<Vsoc_tb_top>();

    FILE* trace_fp = nullptr;
    if (trace_path) {
        trace_fp = std::fopen(trace_path, "w");
        if (!trace_fp) { std::perror(trace_path); return 2; }
    }

#if VM_TRACE
    std::unique_ptr<VerilatedVcdC> vcd;
    if (vcd_path) {
        Verilated::traceEverOn(true);
        vcd.reset(new VerilatedVcdC());
        top->trace(vcd.get(), 99);
        vcd->open(vcd_path);
    }
#else
    if (vcd_path) {
        std::fprintf(stderr, "warning: VCD requested but Verilator built without --trace\n");
    }
#endif

    // The SRAM's DPI exports live inside the module instance; set the scope
    // before calling them.  Module path = TOP.soc_tb_top.u_soc.u_sram.
    svScope scope = svGetScopeFromName("TOP.soc_tb_top.u_soc.u_sram");
    if (!scope) {
        std::fprintf(stderr, "FATAL: cannot find SRAM DPI scope\n");
        return 2;
    }
    svSetScope(scope);

    // --- load ELF into SRAM via DPI ---
    LoadedElf elf;
    try {
        elf = load_elf32(elf_path);
    } catch (const std::exception& e) {
        std::fprintf(stderr, "ELF load failed: %s\n", e.what());
        return 2;
    }

    // SRAM is 64 KiB at 0x80000000; word index = (addr - 0x80000000) / 4.
    // The DPI function is word-addressed against the SRAM array.
    uint32_t sram_base = 0x80000000;
    uint32_t sram_words = 16384;
    uint32_t loaded = 0;
    uint32_t skipped = 0;
    for (const auto& w : elf.words) {
        if (w.byte_addr < sram_base) { skipped++; continue; }
        uint32_t widx = (w.byte_addr - sram_base) / 4;
        if (widx >= sram_words) { skipped++; continue; }
        sram_dpi_write(widx, int32_t(w.data));
        loaded++;
    }
    if (!quiet) {
        std::fprintf(stderr, "[sim] loaded %u words (%u skipped out of range) from %s entry=0x%08x\n",
                     loaded, skipped, elf_path, elf.entry);
    }

    // tohost / fromhost for riscv-tests.
    uint32_t tohost_addr = 0;
    auto it = elf.symbols.find("tohost");
    if (it != elf.symbols.end()) tohost_addr = it->second;
    if (!quiet && tohost_addr) {
        std::fprintf(stderr, "[sim] tohost @ 0x%08x\n", tohost_addr);
    }
    uint32_t tohost_widx = tohost_addr ? (tohost_addr - sram_base) / 4 : 0;

    // --- reset ---
    top->clk = 0;
    top->rst = 1;
    for (int i = 0; i < 10; ++i) {
        top->clk = !top->clk;
        top->eval();
        g_cycles++;
#if VM_TRACE
        if (vcd) vcd->dump(g_cycles);
#endif
    }
    top->rst = 0;

    int exit_code = -1;
    bool done = false;

    while (!done && g_cycles < timeout) {
        // --- rising edge ---
        top->clk = 1;
        top->eval();

        // Sample commit and MMIO just after the clock edge.
        if (top->commit_valid) {
            if (trace_fp) {
                // Format: "core 0: 3 0x<pc> (0x<insn>) [xN 0x<rd_data>]" — Spike-compatible commit log shape.
                // We always emit priv=3 (M-mode) for Stage 1.
                std::fprintf(trace_fp, "core   0: 3 0x%08x (0x%08x)", top->commit_pc, top->commit_insn);
                if (top->commit_rd_wen) {
                    std::fprintf(trace_fp, " x%2u 0x%08x", top->commit_rd_addr, top->commit_rd_data);
                }
                if (top->commit_trap) {
                    std::fprintf(trace_fp, " TRAP cause=0x%08x", top->commit_cause);
                }
                std::fprintf(trace_fp, "\n");
            }
        }

        if (top->console_valid) {
            char c = char(top->console_byte);
            std::fputc(c, stdout);
            std::fflush(stdout);
        }

        if (top->exit_valid) {
            exit_code = int(top->exit_code);
            done = true;
            if (!quiet) std::fprintf(stderr, "[sim] MMIO exit %d @ cycle %llu\n",
                                     exit_code, (unsigned long long)g_cycles);
        }

        // --- falling edge ---
        top->clk = 0;
        top->eval();

        // Poll tohost — riscv-tests writes 1 on pass, (2*failed_test_id+1) on fail.
        if (!done && tohost_addr) {
            int32_t val = sram_dpi_read(tohost_widx);
            if (val != 0) {
                if (val == 1) {
                    exit_code = 0;
                    if (!quiet) std::fprintf(stderr, "[sim] tohost=1 PASS @ cycle %llu\n",
                                             (unsigned long long)g_cycles);
                } else {
                    int failed = (val >> 1);
                    exit_code = 1;
                    if (!quiet) std::fprintf(stderr, "[sim] tohost=0x%x FAIL (test %d) @ cycle %llu\n",
                                             uint32_t(val), failed, (unsigned long long)g_cycles);
                }
                done = true;
            }
        }

        g_cycles++;
#if VM_TRACE
        if (vcd) vcd->dump(g_cycles);
#endif
        if (Verilated::gotFinish()) {
            if (!quiet) std::fprintf(stderr, "[sim] gotFinish @ cycle %llu\n",
                                     (unsigned long long)g_cycles);
            done = true;
        }
    }

    if (!done && g_cycles >= timeout) {
        std::fprintf(stderr, "[sim] TIMEOUT after %llu cycles (no termination)\n",
                     (unsigned long long)g_cycles);
        exit_code = 124;
    }

    top->final();
#if VM_TRACE
    if (vcd) vcd->close();
#endif
    if (trace_fp) std::fclose(trace_fp);

    return exit_code;
}
