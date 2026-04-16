#include "elf_loader.h"

#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <elf.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <stdexcept>
#include <cstdint>

namespace {

struct Mapped {
    int fd = -1;
    void* base = MAP_FAILED;
    size_t size = 0;

    Mapped(const std::string& path) {
        fd = ::open(path.c_str(), O_RDONLY);
        if (fd < 0) throw std::runtime_error("open failed: " + path);
        struct stat st;
        if (fstat(fd, &st) < 0) {
            ::close(fd);
            throw std::runtime_error("fstat failed: " + path);
        }
        size = st.st_size;
        base = ::mmap(nullptr, size, PROT_READ, MAP_PRIVATE, fd, 0);
        if (base == MAP_FAILED) {
            ::close(fd);
            throw std::runtime_error("mmap failed: " + path);
        }
    }

    ~Mapped() {
        if (base != MAP_FAILED) ::munmap(base, size);
        if (fd >= 0) ::close(fd);
    }
};

} // namespace

LoadedElf load_elf32(const std::string& path) {
    Mapped m(path);
    const uint8_t* p = static_cast<const uint8_t*>(m.base);

    if (m.size < sizeof(Elf32_Ehdr)) throw std::runtime_error("file too small: " + path);
    const Elf32_Ehdr* eh = reinterpret_cast<const Elf32_Ehdr*>(p);

    if (std::memcmp(eh->e_ident, ELFMAG, SELFMAG) != 0)
        throw std::runtime_error("not an ELF file: " + path);
    if (eh->e_ident[EI_CLASS] != ELFCLASS32)
        throw std::runtime_error("not ELF32: " + path);
    if (eh->e_ident[EI_DATA] != ELFDATA2LSB)
        throw std::runtime_error("not little-endian: " + path);
    if (eh->e_machine != EM_RISCV)
        throw std::runtime_error("not RISC-V ELF: " + path);

    LoadedElf out;
    out.entry = eh->e_entry;

    // --- walk program headers, copy PT_LOAD segments ---
    const Elf32_Phdr* ph = reinterpret_cast<const Elf32_Phdr*>(p + eh->e_phoff);
    for (int i = 0; i < eh->e_phnum; ++i) {
        if (ph[i].p_type != PT_LOAD) continue;
        uint32_t vaddr  = ph[i].p_paddr ? ph[i].p_paddr : ph[i].p_vaddr;  // prefer physical
        uint32_t filesz = ph[i].p_filesz;
        uint32_t memsz  = ph[i].p_memsz;
        const uint8_t* data = p + ph[i].p_offset;

        // Emit words for file contents
        for (uint32_t off = 0; off < filesz; off += 4) {
            uint32_t w = 0;
            for (int b = 0; b < 4 && (off + b) < filesz; ++b) {
                w |= uint32_t(data[off + b]) << (8 * b);
            }
            out.words.push_back({vaddr + off, w});
        }
        // Zero-fill BSS (.bss / memsz > filesz)
        for (uint32_t off = filesz; off < memsz; off += 4) {
            out.words.push_back({vaddr + off, 0});
        }
    }

    // --- walk section headers, pull symbol table + string table ---
    const Elf32_Shdr* sh = reinterpret_cast<const Elf32_Shdr*>(p + eh->e_shoff);
    const Elf32_Shdr* symtab = nullptr;
    const Elf32_Shdr* strtab = nullptr;
    for (int i = 0; i < eh->e_shnum; ++i) {
        if (sh[i].sh_type == SHT_SYMTAB) {
            symtab = &sh[i];
            if (sh[i].sh_link < eh->e_shnum) strtab = &sh[sh[i].sh_link];
            break;
        }
    }
    if (symtab && strtab) {
        const Elf32_Sym* syms = reinterpret_cast<const Elf32_Sym*>(p + symtab->sh_offset);
        const char* strs = reinterpret_cast<const char*>(p + strtab->sh_offset);
        size_t n = symtab->sh_size / sizeof(Elf32_Sym);
        for (size_t i = 0; i < n; ++i) {
            if (syms[i].st_name == 0) continue;
            std::string name = strs + syms[i].st_name;
            out.symbols[name] = syms[i].st_value;
        }
    }

    return out;
}
