#pragma once
#include <cstdint>
#include <string>
#include <vector>
#include <unordered_map>

// Tiny 32-bit RISC-V ELF loader for sim.  Returns populated word-addressed
// segments plus a symbol map.

struct LoadedElf {
    // word-addressed segments (we already know the load base is 0x80000000
    // so we don't track physaddr explicitly — we return pairs of (byte addr, word))
    struct Word {
        uint32_t byte_addr;
        uint32_t data;
    };
    std::vector<Word> words;
    std::unordered_map<std::string, uint32_t> symbols;
    uint32_t entry = 0;
};

// Load an ELF32-LE file.  Throws std::runtime_error on I/O / parse error.
LoadedElf load_elf32(const std::string& path);
