// Verilator C++ harness for Linux boot simulation.
//
// Responsibilities:
//   - parse cmdline: +fw=<path> +kernel=<path> +dtb=<path> +initrd=<path>
//                    +timeout=<cycles> +trace=<path> +fst=<path>
//                    +bisect=<addr> +tracelimit=<cycles>
//   - load the four binary blobs into the DDR model via ddr_dpi_write
//     at their hardware-matched offsets
//   - run the clock; stream UART to stdout (already handled by the sim
//     UartLite's $write) and optionally capture an FST waveform
//   - emit a per-instruction commit trace if requested (can be gated via
//     +tracefrom=<cycle> to keep the trace file bounded when bisecting the
//     silent-hang point deep into boot)
//
// Termination:
//   * MMIO exit register fired
//   * cycle cap reached
//   * explicit gotFinish

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <memory>
#include <stdexcept>
#include <fstream>

#include <verilated.h>
#include <svdpi.h>
#if VM_TRACE_FST
#include <verilated_fst_c.h>
#elif VM_TRACE
#include <verilated_vcd_c.h>
#endif

#include "Vsoc_tb_linux.h"
#include "Vsoc_tb_linux__Dpi.h"
#include <vector>

static uint64_t g_cycles = 0;
double sc_time_stamp() { return double(g_cycles); }

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

static constexpr uint32_t DDR_BASE  = 0x40000000;
static constexpr uint32_t DDR_WORDS = 32u * 1024u * 1024u;  // must match SV param

static bool load_blob_at(const char* path, uint32_t byte_addr, const char* label) {
    if (!path) return true;
    std::ifstream f(path, std::ios::binary);
    if (!f) {
        std::fprintf(stderr, "[sim] FATAL: cannot open %s: %s\n", label, path);
        return false;
    }
    f.seekg(0, std::ios::end);
    size_t size = f.tellg();
    f.seekg(0, std::ios::beg);
    if (byte_addr < DDR_BASE) {
        std::fprintf(stderr, "[sim] FATAL: %s target 0x%08x below DDR base\n", label, byte_addr);
        return false;
    }
    uint32_t offs = byte_addr - DDR_BASE;
    if (offs + size > DDR_WORDS * 4) {
        std::fprintf(stderr, "[sim] FATAL: %s (0x%08x + %zu B) overruns DDR aperture\n",
                     label, byte_addr, size);
        return false;
    }
    std::vector<uint8_t> buf(size);
    f.read(reinterpret_cast<char*>(buf.data()), size);
    // Pad to 4 bytes, word-write via DPI.
    uint32_t word_base = offs / 4;
    size_t words = (size + 3) / 4;
    for (size_t i = 0; i < words; ++i) {
        uint32_t w = 0;
        for (int b = 0; b < 4; ++b) {
            size_t idx = i * 4 + b;
            if (idx < size) w |= uint32_t(buf[idx]) << (8 * b);
        }
        ddr_dpi_write(int(word_base + i), int32_t(w));
    }
    std::fprintf(stderr, "[sim] loaded %s: %zu B at 0x%08x (%zu words)\n",
                 label, size, byte_addr, words);
    return true;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    const char* fw_path     = plusarg(argc, argv, "fw");
    const char* kernel_path = plusarg(argc, argv, "kernel");
    const char* dtb_path    = plusarg(argc, argv, "dtb");
    const char* initrd_path = plusarg(argc, argv, "initrd");
    const char* bootrom_p   = plusarg(argc, argv, "bootrom");   // into SRAM @ 0x80000000
    const char* raw_path    = plusarg(argc, argv, "raw");       // single binary @ 0x40000000
    const char* trace_path  = plusarg(argc, argv, "trace");
    const char* vcd_path    = plusarg(argc, argv, "vcd");
    const char* fst_path    = plusarg(argc, argv, "fst");
    const char* tfrom_s     = plusarg(argc, argv, "tracefrom");
    const char* tto_s       = plusarg(argc, argv, "traceuntil");
    const char* tpcmin_s    = plusarg(argc, argv, "tracepcmin");
    const char* tpcmax_s    = plusarg(argc, argv, "tracepcmax");
    const char* timeout_s   = plusarg(argc, argv, "timeout");
    const char* memtrace_p  = plusarg(argc, argv, "memtrace");
    const char* mtpamin_s   = plusarg(argc, argv, "memtracepamin");
    const char* mtpamax_s   = plusarg(argc, argv, "memtracepamax");
    uint64_t timeout  = timeout_s ? std::strtoull(timeout_s, nullptr, 0) : 20'000'000ULL;
    uint64_t tfrom    = tfrom_s   ? std::strtoull(tfrom_s,   nullptr, 0) : 0ULL;
    uint64_t tto      = tto_s     ? std::strtoull(tto_s,     nullptr, 0) : UINT64_MAX;
    uint32_t tpcmin   = tpcmin_s  ? (uint32_t)std::strtoull(tpcmin_s, nullptr, 0) : 0u;
    uint32_t tpcmax   = tpcmax_s  ? (uint32_t)std::strtoull(tpcmax_s, nullptr, 0) : 0xFFFFFFFFu;
    uint32_t mtpamin  = mtpamin_s ? (uint32_t)std::strtoull(mtpamin_s, nullptr, 0) : 0u;
    uint32_t mtpamax  = mtpamax_s ? (uint32_t)std::strtoull(mtpamax_s, nullptr, 0) : 0xFFFFFFFFu;

    if (!fw_path && !raw_path) {
        std::fprintf(stderr,
            "usage: %s [+fw=<path> [+kernel=<path> [+dtb=<path> [+initrd=<path>]]]]"
            " | +raw=<path>@<base>\n"
            "       [+timeout=N] [+trace=path] [+fst=path] [+tracefrom=N] [+traceuntil=N]\n",
            argv[0]);
        return 1;
    }

    auto top = std::make_unique<Vsoc_tb_linux>();

    // Scopes for the two DPI backdoors (DDR + SRAM).
    svScope ddr_scope  = svGetScopeFromName("TOP.soc_tb_linux.u_ddr");
    svScope sram_scope = svGetScopeFromName("TOP.soc_tb_linux.u_soc.u_sram");
    if (!ddr_scope || !sram_scope) {
        std::fprintf(stderr, "FATAL: missing scope (ddr=%p sram=%p)\n",
                     (void*)ddr_scope, (void*)sram_scope);
        return 2;
    }

    // Start with SRAM scope for bootrom load below; DDR scope for image loads.
    svSetScope(ddr_scope);

    // DPI self-check — write a sentinel, read it back.
    ddr_dpi_write(0, 0xDEADBEEF);
    int32_t rb = ddr_dpi_read(0);
    if (uint32_t(rb) != 0xDEADBEEFu) {
        std::fprintf(stderr, "[sim] FATAL: DDR DPI round-trip failed: wrote DEADBEEF, read %08x\n", uint32_t(rb));
        return 2;
    }
    ddr_dpi_write(0, 0);  // clear before load

    // Load images.
    if (raw_path) {
        // +raw=/path/to.bin@0x40000000 — single blob, useful for ddr_hello
        std::string s = raw_path;
        auto at = s.find('@');
        uint32_t base = DDR_BASE;
        std::string p = s;
        if (at != std::string::npos) {
            p = s.substr(0, at);
            base = std::strtoul(s.c_str() + at + 1, nullptr, 0);
        }
        if (!load_blob_at(p.c_str(), base, "raw")) return 2;
    } else {
        if (!load_blob_at(fw_path,     0x40000000, "fw_jump")) return 2;
        if (kernel_path && !load_blob_at(kernel_path, 0x40400000, "kernel")) return 2;
        if (dtb_path    && !load_blob_at(dtb_path,    0x42200000, "dtb"))    return 2;
        if (initrd_path && !load_blob_at(initrd_path, 0x43000000, "initrd")) return 2;
    }

    // BootROM (optional): load into SRAM @ 0x80000000. If provided, we also
    // write the handshake words to DDR so the BootROM's polling loop fires
    // immediately on the first fetch.
    if (bootrom_p) {
        std::ifstream f(bootrom_p, std::ios::binary);
        if (!f) { std::fprintf(stderr, "[sim] FATAL: cannot open bootrom %s\n", bootrom_p); return 2; }
        f.seekg(0, std::ios::end);
        size_t size = f.tellg();
        f.seekg(0, std::ios::beg);
        std::vector<uint8_t> buf(size);
        f.read(reinterpret_cast<char*>(buf.data()), size);
        svSetScope(sram_scope);
        size_t words = (size + 3) / 4;
        for (size_t i = 0; i < words; ++i) {
            uint32_t w = 0;
            for (int b = 0; b < 4; ++b) {
                size_t idx = i * 4 + b;
                if (idx < size) w |= uint32_t(buf[idx]) << (8 * b);
            }
            sram_dpi_write(int(i), int32_t(w));
        }
        std::fprintf(stderr, "[sim] loaded bootrom: %zu B at 0x80000000\n", size);

        // Handshake words: entry=0x40000000, dtb=0x42200000, magic=0xDEADBEEF.
        // These live at 0x47000000..0x47000008 which is inside the DDR aperture.
        svSetScope(ddr_scope);
        uint32_t hs_word = (0x47000000u - 0x40000000u) / 4;
        ddr_dpi_write(int(hs_word + 1), int32_t(0x40000000));  // entry
        ddr_dpi_write(int(hs_word + 2), int32_t(0x42200000));  // dtb
        ddr_dpi_write(int(hs_word + 0), int32_t(0xDEADBEEF));  // magic (last)
        std::fprintf(stderr, "[sim] handshake armed at 0x47000000 (magic=0xDEADBEEF)\n");
    }

    // Trace setup.
    FILE* trace_fp = nullptr;
    if (trace_path) {
        trace_fp = std::fopen(trace_path, "w");
        if (!trace_fp) { std::perror(trace_path); return 2; }
    }
    FILE* mtrace_fp = nullptr;
    if (memtrace_p) {
        mtrace_fp = std::fopen(memtrace_p, "w");
        if (!mtrace_fp) { std::perror(memtrace_p); return 2; }
    }
    // Pending dm-rsp tracker — same-cycle issue/rsp pairs are common, but
    // when separated by stalls we need to remember the issue side so the
    // rsp line can include the (PC-less) PA back-reference.
    bool     pending_rsp = false;
    uint32_t pending_va = 0, pending_pa = 0;
    bool     pending_wen = false;

#if VM_TRACE_FST
    std::unique_ptr<VerilatedFstC> fst;
    if (fst_path) {
        Verilated::traceEverOn(true);
        fst.reset(new VerilatedFstC());
        top->trace(fst.get(), 99);
        fst->open(fst_path);
        std::fprintf(stderr, "[sim] FST trace enabled: %s\n", fst_path);
    }
#elif VM_TRACE
    std::unique_ptr<VerilatedVcdC> vcd;
    if (vcd_path) {
        Verilated::traceEverOn(true);
        vcd.reset(new VerilatedVcdC());
        top->trace(vcd.get(), 99);
        vcd->open(vcd_path);
    }
#else
    if (vcd_path || fst_path) {
        std::fprintf(stderr, "warning: trace requested but Verilator built without tracing\n");
    }
#endif

    // Reset pulse.
    top->clk = 0;
    top->rst = 1;
    for (int i = 0; i < 10; ++i) {
        top->clk = !top->clk;
        top->eval();
        g_cycles++;
    }
    top->rst = 0;

    // Post-reset DPI readback — confirm the DDR still has our image.
    {
        uint32_t w0 = uint32_t(ddr_dpi_read(0));
        uint32_t w1 = uint32_t(ddr_dpi_read(1));
        uint32_t w2 = uint32_t(ddr_dpi_read(2));
        std::fprintf(stderr, "[sim] post-reset DDR[0..2] = %08x %08x %08x\n", w0, w1, w2);
    }

    int exit_code = -1;
    bool done = false;
    uint8_t prev_priv = 3;   // M-mode after reset
    uint64_t traps_seen = 0;
    static const char* const PRIV_NAMES[4] = {"U", "S", "?", "M"};

    while (!done && g_cycles < timeout) {
        top->clk = 1;
        top->eval();

        if (top->commit_valid && trace_fp && g_cycles >= tfrom && g_cycles <= tto &&
            top->commit_pc >= tpcmin && top->commit_pc <= tpcmax) {
            std::fprintf(trace_fp, "c%llu: 0x%08x (0x%08x)",
                         (unsigned long long)g_cycles, top->commit_pc, top->commit_insn);
            if (top->commit_rd_wen) {
                std::fprintf(trace_fp, " x%u=0x%08x", top->commit_rd_addr, top->commit_rd_data);
            }
            if (top->commit_trap) {
                std::fprintf(trace_fp, " TRAP cause=0x%08x", top->commit_cause);
            }
            std::fprintf(trace_fp, "\n");
        }

        // dm-bus tap. Issue and response can fire same cycle (single
        // outstanding usual case) or be separated by stalls. Filter by PA
        // window so we can dump only ranges of interest.
        if (mtrace_fp && g_cycles >= tfrom && g_cycles <= tto) {
            if (top->tap_dm_req_fire &&
                top->tap_dm_req_pa >= mtpamin && top->tap_dm_req_pa <= mtpamax) {
                std::fprintf(mtrace_fp, "i%llu: VA=0x%08x PA=0x%08x %s sz=%u",
                             (unsigned long long)g_cycles,
                             top->tap_dm_req_va, top->tap_dm_req_pa,
                             top->tap_dm_req_wen ? "ST" : "LD",
                             unsigned(top->tap_dm_req_size));
                if (top->tap_dm_req_wen) {
                    std::fprintf(mtrace_fp, " wmask=0x%x wdata=0x%08x",
                                 unsigned(top->tap_dm_req_wmask),
                                 top->tap_dm_req_wdata);
                }
                std::fprintf(mtrace_fp, "\n");
                pending_rsp = true;
                pending_va = top->tap_dm_req_va;
                pending_pa = top->tap_dm_req_pa;
                pending_wen = top->tap_dm_req_wen;
            }
            if (top->tap_dm_rsp_fire && pending_rsp &&
                pending_pa >= mtpamin && pending_pa <= mtpamax) {
                std::fprintf(mtrace_fp,
                             "r%llu: VA=0x%08x PA=0x%08x %s rdata=0x%08x%s%s\n",
                             (unsigned long long)g_cycles,
                             pending_va, pending_pa,
                             pending_wen ? "ST" : "LD",
                             top->tap_dm_rsp_rdata,
                             top->tap_dm_rsp_fault     ? " FAULT" : "",
                             top->tap_dm_rsp_pagefault ? " PFAULT" : "");
                pending_rsp = false;
            }
        }

        if (top->exit_valid) {
            exit_code = int(top->exit_code);
            done = true;
            std::fprintf(stderr, "\n[sim] MMIO exit %d @ cycle %llu\n",
                         exit_code, (unsigned long long)g_cycles);
        }

        top->clk = 0;
        top->eval();

        g_cycles++;
#if VM_TRACE_FST
        if (fst && g_cycles >= tfrom && g_cycles <= tto) fst->dump(g_cycles);
#elif VM_TRACE
        if (vcd && g_cycles >= tfrom && g_cycles <= tto) vcd->dump(g_cycles);
#endif
        if (Verilated::gotFinish()) {
            std::fprintf(stderr, "[sim] gotFinish @ cycle %llu\n",
                         (unsigned long long)g_cycles);
            done = true;
        }

        // Always-on trap print (cheap and always useful).
        if (top->commit_valid && top->commit_trap) {
            traps_seen++;
            if (traps_seen <= 64 || (traps_seen & 0xFFFF) == 0) {
                std::fprintf(stderr, "[sim] TRAP @ cycle %llu pc=0x%08x cause=0x%08x (priv=%s)\n",
                             (unsigned long long)g_cycles, top->commit_pc,
                             top->commit_cause, PRIV_NAMES[top->tap_priv_mode & 3]);
            }
        }

        // Priv-mode transitions — M↔S↔U boundaries are the interesting ones.
        {
            uint8_t cur_priv = top->tap_priv_mode & 3;
            if (cur_priv != prev_priv) {
                std::fprintf(stderr, "[sim] PRIV %s->%s @ cycle %llu pc=0x%08x\n",
                             PRIV_NAMES[prev_priv], PRIV_NAMES[cur_priv],
                             (unsigned long long)g_cycles, top->commit_pc);
                prev_priv = cur_priv;
            }
        }

        // Progress heartbeat: coarse so long runs (~10B cycles) aren't noisy.
        // ~67M cycles = every 1–2 minutes wall-clock on this sim host.
        if ((g_cycles & 0x3FFFFFF) == 0 && g_cycles != 0) {
            std::fprintf(stderr, "[sim] cycle %llu, last PC 0x%08x priv=%s traps=%llu\n",
                         (unsigned long long)g_cycles, top->commit_pc,
                         PRIV_NAMES[top->tap_priv_mode & 3],
                         (unsigned long long)traps_seen);
        }
    }

    if (!done && g_cycles >= timeout) {
        std::fprintf(stderr, "\n[sim] TIMEOUT after %llu cycles (last PC 0x%08x)\n",
                     (unsigned long long)g_cycles, top->commit_pc);
        exit_code = 124;
    }

    // Dump trampoline_pg_dir region so we can tell if setup_vm() populated it.
    {
        svSetScope(ddr_scope);
        static const uint32_t probe[] = {
            0x420bf000, 0x420bfc00, 0x420bfc04, 0x420bfc08,
            0x420c0000, 0x420c0c00, 0x420c0c04,
            0x41982010, 0x41982014, 0x41982038,
        };
        std::fprintf(stderr, "[sim] DDR post-run probe:\n");
        for (size_t i = 0; i < sizeof(probe)/sizeof(probe[0]); ++i) {
            uint32_t pa = probe[i];
            uint32_t w = uint32_t(ddr_dpi_read(int((pa - DDR_BASE) / 4)));
            std::fprintf(stderr, "  [0x%08x] = 0x%08x\n", pa, w);
        }
    }

    top->final();
#if VM_TRACE_FST
    if (fst) fst->close();
#elif VM_TRACE
    if (vcd) vcd->close();
#endif
    if (trace_fp) std::fclose(trace_fp);
    if (mtrace_fp) std::fclose(mtrace_fp);

    return exit_code;
}
