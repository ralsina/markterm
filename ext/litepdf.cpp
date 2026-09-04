// litepdf: render HTML to PDF using litehtml for layout and libharu for
// PDF output. Implements litehtml::document_container on top of the
// libharu C API, adds pagination (litehtml has no paged-media support)
// and exposes a small flat C API for the Crystal side.
//
// Coordinate handling: litehtml works top-down in CSS pixels, libharu
// bottom-up in points. We use the identity mapping 1px = 1pt and flip
// y when drawing.

#include "litehtml.h"
#include "litehtml/render_item.h"

#include <hpdf.h>
#include <hpdf_error.h>

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <filesystem>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <vector>

namespace
{

float px(litehtml::pixel_t value)
{
    return value.value();
}

// ---------------------------------------------------------------------------
// TrueType font registry: provided font files and system-installed fonts.
// Metadata (family, weight, italic) is read from the font's name and OS/2
// tables; matching mimics CSS font matching, with Base-14 as the fallback.
// ---------------------------------------------------------------------------

struct FontFile
{
    std::string path;
    std::string family; // lowercase family name
    int weight = 400;
    bool italic = false;
    // Lazily parsed cmap coverage (sorted inclusive codepoint ranges).
    mutable std::shared_ptr<struct Coverage> coverage;
};

// Codepoint coverage of one font file, as sorted inclusive ranges.
struct Coverage
{
    bool loaded = false;
    std::vector<std::pair<uint32_t, uint32_t>> ranges;

    bool covers(uint32_t codepoint) const
    {
        auto it = std::lower_bound(ranges.begin(), ranges.end(), codepoint,
                                   [](const std::pair<uint32_t, uint32_t>& range, uint32_t value) {
                                       return range.second < value;
                                   });
        return it != ranges.end() && it->first <= codepoint;
    }
};

// Parse the cmap table (formats 0/4/6/12) into covered ranges. Coverage
// only: a codepoint maps to a nonzero glyph.
bool parse_cmap_coverage(const std::string& path, Coverage& out);

uint16_t read_u16(const std::vector<unsigned char>& buffer, size_t offset)
{
    if (offset + 2 > buffer.size())
    {
        return 0;
    }
    return (uint16_t)((buffer[offset] << 8) | buffer[offset + 1]);
}

uint32_t read_u32(const std::vector<unsigned char>& buffer, size_t offset)
{
    if (offset + 4 > buffer.size())
    {
        return 0;
    }
    return ((uint32_t)buffer[offset] << 24) | ((uint32_t)buffer[offset + 1] << 16) |
           ((uint32_t)buffer[offset + 2] << 8) | buffer[offset + 3];
}

std::string decode_utf16be(const unsigned char* data, size_t length)
{
    std::string out;
    for (size_t i = 0; i + 1 < length; i += 2)
    {
        unsigned int codepoint = (data[i] << 8) | data[i + 1];
        if (codepoint < 0x80)
        {
            out += (char)codepoint;
        }
        else if (codepoint < 0x800)
        {
            out += (char)(0xC0 | (codepoint >> 6));
            out += (char)(0x80 | (codepoint & 0x3F));
        }
        else
        {
            out += (char)(0xE0 | (codepoint >> 12));
            out += (char)(0x80 | ((codepoint >> 6) & 0x3F));
            out += (char)(0x80 | (codepoint & 0x3F));
        }
    }
    return out;
}

std::string to_lower(const std::string& text)
{
    std::string out = text;
    std::transform(out.begin(), out.end(), out.begin(),
                   [](unsigned char character) { return (char)std::tolower(character); });
    return out;
}

// Read a table (or its head) from the font file.
bool read_table(std::FILE* file, long offset, size_t length, std::vector<unsigned char>& out)
{
    if (std::fseek(file, offset, SEEK_SET) != 0)
    {
        return false;
    }
    out.resize(length);
    return std::fread(out.data(), 1, length, file) == length;
}

bool parse_ttf_metadata(const std::string& path, FontFile& out)
{
    std::FILE* file = std::fopen(path.c_str(), "rb");
    if (!file)
    {
        return false;
    }

    std::vector<unsigned char> head;
    if (!read_table(file, 0, 16, head))
    {
        std::fclose(file);
        return false;
    }
    uint32_t version = read_u32(head, 0);
    if (version == 0x74746366) // 'ttcf': font collection, use the first font
    {
        if (!read_table(file, 12, 4, head))
        {
            std::fclose(file);
            return false;
        }
        version = read_u32(head, 0);
    }
    if (version != 0x00010000 && version != 0x74727565) // 1.0 or 'true'
    {
        std::fclose(file);
        return false;
    }

    uint16_t num_tables = read_u16(head, 4);
    long name_offset = 0, name_length = 0, os2_offset = 0;
    for (uint16_t i = 0; i < num_tables; i++)
    {
        std::vector<unsigned char> entry;
        if (!read_table(file, 12 + i * 16, 16, entry))
        {
            break;
        }
        std::string tag(reinterpret_cast<const char*>(entry.data()), 4);
        uint32_t table_offset = read_u32(entry, 8);
        uint32_t table_length = read_u32(entry, 12);
        if (tag == "name")
        {
            name_offset = (long)table_offset;
            name_length = (long)table_length;
        }
        else if (tag == "OS/2")
        {
            os2_offset = (long)table_offset;
        }
    }

    std::string family, subfamily;
    int weight = 0;
    bool os2_italic = false, os2_bold = false;
    if (name_offset)
    {
        std::vector<unsigned char> table;
        if (read_table(file, name_offset, (size_t)name_length, table) && table.size() >= 6)
        {
            uint16_t count = read_u16(table, 2);
            uint16_t string_offset = read_u16(table, 4);
            size_t best_family_rank = 4, best_style_rank = 4;
            for (uint16_t i = 0; i < count && 6 + (size_t)i * 12 + 12 <= table.size(); i++)
            {
                size_t record = 6 + (size_t)i * 12;
                uint16_t platform = read_u16(table, record);
                uint16_t name_id = read_u16(table, record + 6);
                uint16_t length = read_u16(table, record + 8);
                uint16_t offset = read_u16(table, record + 10);
                if (name_id != 1 && name_id != 2 && name_id != 16 && name_id != 17)
                {
                    continue;
                }
                // Prefer Windows UTF-16 names (rank 0), then Unicode (1),
                // then Mac Roman (2).
                size_t rank = platform == 3 ? 0 : platform == 0 ? 1 : platform == 1 ? 2 : 3;
                if (offset + (size_t)length > table.size())
                {
                    continue;
                }
                std::string value;
                if (platform == 1)
                {
                    value.assign(reinterpret_cast<const char*>(table.data()) + string_offset + offset, length);
                }
                else
                {
                    value = decode_utf16be(table.data() + string_offset + offset, length);
                }
                if (name_id == 16 && rank < best_family_rank)
                {
                    family = value;
                    best_family_rank = rank;
                }
                else if (name_id == 1 && best_family_rank > 2)
                {
                    family = value;
                    best_family_rank = 3;
                }
                if (name_id == 17 && rank < best_style_rank)
                {
                    subfamily = value;
                    best_style_rank = rank;
                }
                else if (name_id == 2 && best_style_rank > 2)
                {
                    subfamily = value;
                    best_style_rank = 3;
                }
            }
        }
    }
    if (os2_offset)
    {
        std::vector<unsigned char> os2;
        if (read_table(file, os2_offset, 96, os2) && os2.size() >= 64)
        {
            weight = read_u16(os2, 4);
            uint16_t fs_selection = read_u16(os2, 62);
            os2_italic = (fs_selection & 0x01) != 0;
            os2_bold = (fs_selection & 0x20) != 0;
        }
    }
    std::fclose(file);

    if (family.empty())
    {
        return false;
    }
    out.path = path;
    out.family = to_lower(family);
    std::string style = to_lower(subfamily);
    bool style_bold = style.find("bold") != std::string::npos;
    bool style_italic = style.find("italic") != std::string::npos ||
                        style.find("oblique") != std::string::npos;
    if (weight)
    {
        out.weight = weight;
        out.italic = os2_italic || style_italic;
    }
    else
    {
        out.weight = style_bold || os2_bold ? 700 : 400;
        out.italic = style_italic || os2_italic;
    }
    return true;
}

// Read the cmap subtable preference order: Unicode full-repertoire
// format 12 first, then BMP format 4 variants.
bool pick_cmap_subtable(std::FILE* file, long cmap_offset, uint32_t cmap_length, long& subtable_offset)
{
    std::vector<unsigned char> head;
    if (!read_table(file, cmap_offset, 4, head))
    {
        return false;
    }
    uint16_t num_tables = read_u16(head, 2);
    long best = -1;
    int best_rank = 100;
    static const int preferred[][2] = {{3, 10}, {0, 4}, {0, 6}, {3, 1}, {0, 3}, {0, 2}, {0, 1}, {0, 0}, {1, 0}};
    for (uint16_t i = 0; i < num_tables; i++)
    {
        std::vector<unsigned char> entry;
        if (!read_table(file, cmap_offset + 4 + i * 8, 8, entry))
        {
            break;
        }
        uint16_t platform = read_u16(entry, 0);
        uint16_t encoding = read_u16(entry, 2);
        uint32_t offset = read_u32(entry, 4);
        if (offset >= cmap_length)
        {
            continue;
        }
        for (int rank = 0; rank < 9; rank++)
        {
            if (preferred[rank][0] == platform && preferred[rank][1] == encoding && rank < best_rank)
            {
                best = (long)offset;
                best_rank = rank;
            }
        }
    }
    if (best < 0)
    {
        return false;
    }
    subtable_offset = cmap_offset + best;
    return true;
}

// Scan a format 4 subtable and record covered (nonzero glyph) ranges.
void collect_format4(const std::vector<unsigned char>& table, Coverage& out)
{
    uint16_t seg_count_x2 = read_u16(table, 6);
    size_t seg_count = seg_count_x2 / 2;
    size_t end_base = 14;
    size_t start_base = end_base + seg_count_x2 + 2;
    size_t delta_base = start_base + seg_count_x2;
    size_t range_base = delta_base + seg_count_x2;
    for (size_t segment = 0; segment < seg_count; segment++)
    {
        uint16_t start_code = read_u16(table, start_base + segment * 2);
        uint16_t end_code = read_u16(table, end_base + segment * 2);
        uint16_t id_delta = read_u16(table, delta_base + segment * 2);
        uint16_t id_range_offset = read_u16(table, range_base + segment * 2);
        if (start_code == 0xFFFF)
        {
            break;
        }
        uint32_t run_start = 0, run_end = 0;
        bool run_open = false;
        for (uint32_t codepoint = start_code; codepoint <= (uint32_t)end_code && codepoint != 0xFFFF; codepoint++)
        {
            uint32_t glyph;
            if (id_range_offset == 0)
            {
                glyph = (codepoint + id_delta) & 0xFFFF;
            }
            else
            {
                size_t index = range_base + segment * 2 + id_range_offset + (codepoint - start_code) * 2;
                glyph = (index + 1 < table.size()) ? (uint32_t)((table[index] << 8) | table[index + 1]) : 0;
            }
            if (glyph != 0)
            {
                if (!run_open)
                {
                    run_start = codepoint;
                    run_open = true;
                }
                run_end = codepoint;
            }
            else if (run_open)
            {
                out.ranges.emplace_back(run_start, run_end);
                run_open = false;
            }
        }
        if (run_open)
        {
            out.ranges.emplace_back(run_start, run_end);
        }
    }
}

// Scan format 12 (groups) or 6/0 (compact tables).
void collect_simple(const std::vector<unsigned char>& table, uint16_t format, Coverage& out)
{
    if (format == 12)
    {
        uint32_t num_groups = read_u32(table, 12);
        for (uint32_t i = 0; i < num_groups && 16 + (size_t)i * 12 + 12 <= table.size(); i++)
        {
            size_t group = 16 + (size_t)i * 12;
            uint32_t start = read_u32(table, group);
            uint32_t end = read_u32(table, group + 4);
            uint32_t start_glyph = read_u32(table, group + 8);
            if (start_glyph != 0 && start <= end)
            {
                out.ranges.emplace_back(start, end);
            }
        }
    }
    else if (format == 6)
    {
        uint16_t first = read_u16(table, 6);
        uint16_t count = read_u16(table, 8);
        for (uint16_t i = 0; i < count; i++)
        {
            uint16_t glyph = read_u16(table, 10 + i * 2);
            if (glyph != 0)
            {
                out.ranges.emplace_back(first + i, first + i);
            }
        }
    }
    else if (format == 0)
    {
        for (uint32_t codepoint = 0; codepoint < 256; codepoint++)
        {
            if (codepoint < table.size() && table[codepoint] != 0)
            {
                out.ranges.emplace_back(codepoint, codepoint);
            }
        }
    }
}

bool parse_cmap_coverage(const std::string& path, Coverage& out)
{
    std::FILE* file = std::fopen(path.c_str(), "rb");
    if (!file)
    {
        return false;
    }
    std::vector<unsigned char> head;
    if (!read_table(file, 0, 16, head))
    {
        std::fclose(file);
        return false;
    }
    uint32_t version = read_u32(head, 0);
    if (version == 0x74746366)
    {
        if (!read_table(file, 12, 4, head))
        {
            std::fclose(file);
            return false;
        }
        version = read_u32(head, 0);
    }
    if (version != 0x00010000 && version != 0x74727565)
    {
        std::fclose(file);
        return false;
    }
    uint16_t num_tables = read_u16(head, 4);
    long cmap_offset = 0;
    uint32_t cmap_length = 0;
    for (uint16_t i = 0; i < num_tables; i++)
    {
        std::vector<unsigned char> entry;
        if (!read_table(file, 12 + i * 16, 16, entry))
        {
            break;
        }
        if (std::string(reinterpret_cast<const char*>(entry.data()), 4) == "cmap")
        {
            cmap_offset = (long)read_u32(entry, 8);
            cmap_length = read_u32(entry, 12);
        }
    }
    if (!cmap_offset)
    {
        std::fclose(file);
        return false;
    }
    long subtable;
    if (!pick_cmap_subtable(file, cmap_offset, cmap_length, subtable))
    {
        std::fclose(file);
        return false;
    }
    std::vector<unsigned char> format_head;
    if (!read_table(file, subtable, 4, format_head))
    {
        std::fclose(file);
        return false;
    }
    uint16_t format = read_u16(format_head, 0);
    bool ok = false;
    if (format == 4)
    {
        std::vector<unsigned char> table;
        if (read_table(file, subtable, cmap_length, table))
        {
            collect_format4(table, out);
            ok = true;
        }
    }
    else if (format == 12 || format == 6 || format == 0)
    {
        std::vector<unsigned char> table;
        if (read_table(file, subtable, cmap_length, table))
        {
            collect_simple(table, format, out);
            ok = true;
        }
    }
    std::fclose(file);
    std::sort(out.ranges.begin(), out.ranges.end());
    out.loaded = ok;
    return ok;
}

// Lazily load (and cache) the coverage of a font file.
bool font_covers(const FontFile& font, uint32_t codepoint)
{
    if (!font.coverage)
    {
        font.coverage = std::make_shared<Coverage>();
        if (!parse_cmap_coverage(font.path, *font.coverage))
        {
            // Unparseable cmap: claim full coverage so the font stays in
            // use rather than having every character fall back.
            font.coverage->ranges.emplace_back(0, 0x10FFFF);
            font.coverage->loaded = true;
        }
    }
    return font.coverage->covers(codepoint);
}

bool is_emoji_codepoint(uint32_t codepoint)
{
    return (codepoint >= 0x2600 && codepoint <= 0x27BF) || // misc symbols + dingbats
           (codepoint >= 0x2B00 && codepoint <= 0x2BFF) || // misc symbols and arrows
           (codepoint >= 0x1F000 && codepoint <= 0x1FAFF); // emoji planes
}

// Zero-width joiners/variation selectors never draw on their own.
bool is_zero_width_codepoint(uint32_t codepoint)
{
    return codepoint == 0xFE0F || codepoint == 0xFE0E || codepoint == 0x200D;
}

// The explicit emoji font path (--emoji-font); empty means auto-detect.
std::string g_emoji_font_path;

// Optional page header/footer templates. "%p" expands to the page
// number and "%t" to the total page count.
std::string g_header_template;
std::string g_footer_template;

// Page background color as a CSS "#rrggbb" string; empty = white.
std::string g_page_background;

// Provided font files (--font flags), then scanned system fonts.
std::vector<FontFile> g_provided_fonts;
std::vector<FontFile> g_system_fonts;
bool g_system_scanned = false;

void scan_font_dir(const std::string& directory)
{
    std::error_code error;
    if (!std::filesystem::exists(directory, error))
    {
        return;
    }
    auto iterator = std::filesystem::recursive_directory_iterator(directory, error);
    for (auto end = std::filesystem::end(iterator); iterator != end; iterator.increment(error))
    {
        if (error)
        {
            break;
        }
        const auto& entry = *iterator;
        if (!entry.is_regular_file(error))
        {
            continue;
        }
        std::string path = entry.path().string();
        std::string lower = to_lower(path);
        if (lower.size() > 4 && lower.rfind(".ttf") == lower.size() - 4)
        {
            FontFile font;
            if (parse_ttf_metadata(path, font))
            {
                g_system_fonts.push_back(font);
            }
        }
    }
}

void ensure_system_fonts_scanned()
{
    if (g_system_scanned)
    {
        return;
    }
    g_system_scanned = true;
    scan_font_dir("/usr/share/fonts");
    scan_font_dir("/usr/local/share/fonts");
    const char* home = std::getenv("HOME");
    if (home)
    {
        scan_font_dir(std::string(home) + "/.local/share/fonts");
        scan_font_dir(std::string(home) + "/.fonts");
    }
}

// Generic CSS families, resolved to concrete families commonly installed.
const std::vector<std::string>& generic_aliases(const std::string& family)
{
    static const std::map<std::string, std::vector<std::string>> aliases = {
        {"serif", {"dejavu serif", "liberation serif", "times new roman", "nimbus roman", "georgia", "garamond"}},
        {"sans-serif", {"dejavu sans", "liberation sans", "arial", "helvetica", "nimbus sans", "verdana"}},
        {"monospace", {"dejavu sans mono", "liberation mono", "courier new", "nimbus mono", "consolas"}},
    };
    static const std::vector<std::string> empty;
    auto found = aliases.find(family);
    return found != aliases.end() ? found->second : empty;
}

// CSS font matching, simplified: prefer a face with the wanted bold and
// italic flags, then the closest weight.
const FontFile* match_face(const std::vector<FontFile>& registry, const std::string& family, bool want_bold,
                           bool want_italic)
{
    const FontFile* best = nullptr;
    int best_score = -1;
    int best_weight_gap = 1 << 20;
    for (const auto& font : registry)
    {
        if (font.family != family)
        {
            continue;
        }
        int score = (font.italic == want_italic ? 1 : 0) + ((font.weight >= 600) == want_bold ? 2 : 0);
        int weight_gap = std::abs(font.weight - (want_bold ? 700 : 400));
        if (score > best_score || (score == best_score && weight_gap < best_weight_gap))
        {
            best = &font;
            best_score = score;
            best_weight_gap = weight_gap;
        }
    }
    return best;
}

// Walk the CSS font-family list; returns a TTF from the provided fonts or,
// failing that, the system fonts. Generic families expand to well-known
// concrete families before matching.
const FontFile* match_font(const std::string& family_list, bool want_bold, bool want_italic)
{
    size_t start = 0;
    while (start <= family_list.size())
    {
        size_t comma = family_list.find(',', start);
        std::string token =
            to_lower(family_list.substr(start, comma == std::string::npos ? comma : comma - start));
        size_t first = token.find_first_not_of(" \t\"'");
        size_t last = token.find_last_not_of(" \t\"'");
        token = first == std::string::npos ? "" : token.substr(first, last - first + 1);
        if (!token.empty())
        {
            const auto& expanded = generic_aliases(token);
            std::vector<std::string> candidates =
                expanded.empty() ? std::vector<std::string>{token} : expanded;
            for (const auto& candidate : candidates)
            {
                ensure_system_fonts_scanned();
                const FontFile* found = match_face(g_provided_fonts, candidate, want_bold, want_italic);
                if (!found)
                {
                    found = match_face(g_system_fonts, candidate, want_bold, want_italic);
                }
                if (found)
                {
                    return found;
                }
            }
        }
        if (comma == std::string::npos)
        {
            break;
        }
        start = comma + 1;
    }
    return nullptr;
}

// Best-effort UTF-8 -> CP1252. libharu Base-14 fonts with the default
// encoding render single bytes, so multi-byte characters degrade to
// '?' unless they have a CP1252 equivalent.
std::string to_cp1252(const char* text)
{
    std::string out;
    const auto* cursor = reinterpret_cast<const unsigned char*>(text);
    while (*cursor)
    {
        unsigned int codepoint = *cursor;
        int extra = 0;
        if (codepoint >= 0xF0)
        {
            codepoint &= 0x07;
            extra = 3;
        }
        else if (codepoint >= 0xE0)
        {
            codepoint &= 0x0F;
            extra = 2;
        }
        else if (codepoint >= 0xC0)
        {
            codepoint &= 0x1F;
            extra = 1;
        }
        bool valid = extra == 0 || ((codepoint != 0) && extra <= 2);
        for (int i = 0; i < extra && valid; i++)
        {
            unsigned char continuation = *++cursor;
            if ((continuation & 0xC0) != 0x80)
            {
                valid = false;
                break;
            }
            codepoint = (codepoint << 6) | (continuation & 0x3F);
        }
        if (!valid)
        {
            out += '?';
            cursor++;
            continue;
        }
        if (extra > 0)
        {
            cursor++;
        }

        // The handful of CP1252 mappings for codepoints in the 0x80-0x9F
        // window; everything else non-Latin-1 degrades to '?'.
        switch (codepoint)
        {
        case 0x20AC: out += (char)0x80; break;
        case 0x2018: out += (char)0x91; break;
        case 0x2019: out += (char)0x92; break;
        case 0x201C: out += (char)0x93; break;
        case 0x201D: out += (char)0x94; break;
        case 0x2022: out += (char)0x95; break;
        case 0x2013: out += (char)0x96; break;
        case 0x2014: out += (char)0x97; break;
        case 0x2122: out += (char)0x99; break;
        default:
            if (codepoint < 0x100)
            {
                out += (char)codepoint;
            }
            else
            {
                out += '?';
            }
        }
        cursor++;
    }
    return out;
}

struct PdfFont
{
    std::string name;
    HPDF_Font handle = nullptr;
    float size = 0;
    float ascent = 0;
    float descent = 0;
    float x_height = 0;
    float ch_width = 0;
    int decoration = 0; // litehtml::text_decoration_line bitset
    bool utf8 = false;  // embedded TTF with the UTF-8 encoding
    // Coverage of the source TTF (null for Base-14 fonts).
    std::shared_ptr<Coverage> coverage;
};

// Last libharu error, captured by the error handler so failure messages
// can say what actually went wrong instead of "something failed".
int g_hpdf_error = 0;
int g_hpdf_error_detail = 0;
std::string g_last_op = "starting up";

void hpdf_error_handler(HPDF_STATUS error_no, HPDF_STATUS detail_no, void* /*user_data*/)
{
    g_hpdf_error = (int)error_no;
    g_hpdf_error_detail = (int)detail_no;
    if (getenv("LITEPDF_DEBUG"))
    {
        std::fprintf(stderr, "libharu error 0x%04lX (detail %ld) while: %s\n",
                     (unsigned long)error_no, (unsigned long)detail_no, g_last_op.c_str());
    }
}

const char* hpdf_error_name(int code)
{
    switch (code)
    {
    case 0: return "none";
    case HPDF_FAILED_TO_ALLOC_MEM: return "out of memory";
    case HPDF_INVALID_DOCUMENT: return "invalid document";
    case HPDF_INVALID_DOCUMENT_STATE: return "invalid document state";
    case HPDF_INVALID_PARAMETER: return "invalid parameter";
    case HPDF_INVALID_IMAGE: return "invalid image";
    case HPDF_INVALID_COLOR_SPACE: return "invalid color space";
    case HPDF_INVALID_ENCODING_NAME: return "invalid encoding name";
    case HPDF_INVALID_FONT_NAME: return "invalid font name";
    case HPDF_INVALID_FONTDEF_DATA: return "invalid font data";
    case HPDF_UNSUPPORTED_FONT_TYPE: return "unsupported font type";
    case HPDF_UNSUPPORTED_FUNC: return "unsupported function";
    case HPDF_UNSUPPORTED_JPEG_FORMAT: return "unsupported JPEG format";
    case HPDF_UNSUPPORTED_TYPE1_FONT: return "unsupported Type1 font";
    case HPDF_PAGE_INVALID_FONT: return "invalid page font";
    case HPDF_PAGE_INVALID_GMODE: return "unbalanced GSave/GRestore";
    case HPDF_PAGE_CANNOT_RESTORE_GSTATE: return "GRestore without matching GSave";
    case HPDF_EXCEED_GSTATE_LIMIT: return "too many nested graphics states";
    case HPDF_PAGE_OUT_OF_RANGE: return "value out of range";
    default: return nullptr;
    }
}

std::string describe_hpdf_error()
{
    if (g_hpdf_error == 0)
    {
        return "no libharu error recorded";
    }
    std::string out = "libharu error 0x";
    char buffer[16];
    std::snprintf(buffer, sizeof(buffer), "%04X", g_hpdf_error);
    out += buffer;
    if (const char* name = hpdf_error_name(g_hpdf_error))
    {
        out += " (";
        out += name;
        out += ")";
    }
    out += " [while " + g_last_op + "]";
    return out;
}

struct DrawContext
{
    HPDF_Page page = nullptr;
    float page_height = 0; // PDF page height in points
    float y_offset = 0;    // document-space y drawn at the top margin of this page
    float x_offset = 0;    // left margin in document space (page window left edge)
    float top_margin = 0;  // page top margin in points
    // Depth of clip paths pushed by set_clip (overflow: hidden); libharu
    // clips are real, so partially visible glyphs get cut at the box edge.
    int clip_depth = 0;

    float pdf_x(float document_x) const
    {
        return document_x + x_offset;
    }

    // Convert the top of a box in document space to a PDF y coordinate.
    float pdf_y(float document_y) const
    {
        return page_height - top_margin - (document_y - y_offset);
    }
};

class PdfContainer : public litehtml::document_container
{
  public:
    HPDF_Doc pdf = nullptr;
    std::string base_dir;
    litehtml::pixel_t content_width = 0;

    explicit PdfContainer(HPDF_Doc doc) : pdf(doc) {}

    // -- fonts -----------------------------------------------------------

    // Font handles must stay valid while new fonts are created during
    // drawing, so a deque's stable references matter here.
    std::deque<PdfFont> fonts;
    std::map<std::string, litehtml::uint_ptr> font_cache;
    std::map<std::string, std::string> ttf_names; // path -> internal name
    HPDF_Page measure_page = nullptr;
    std::string measure_font_name;
    float measure_font_size = 0;

    // Load an embedded TTF and fill a PdfFont for it. Returns false when
    // libharu rejects the file.
    bool create_ttf_font(const FontFile& file, float size, int decoration, PdfFont& font)
    {
        std::string internal;
        auto cached = ttf_names.find(file.path);
        if (cached != ttf_names.end())
        {
            internal = cached->second;
        }
        else
        {
            const char* name = HPDF_LoadTTFontFromFile(pdf, file.path.c_str(), 0);
            if (!name)
            {
                HPDF_ResetError(pdf);
                return false;
            }
            internal = name;
            ttf_names[file.path] = internal;
        }
        HPDF_Font handle = HPDF_GetFont(pdf, internal.c_str(), "UTF-8");
        if (!handle)
        {
            HPDF_ResetError(pdf);
            return false;
        }
        font.name = internal;
        font.handle = handle;
        font.utf8 = true;
        font.size = size;
        font.decoration = decoration;
        font.ascent = HPDF_Font_GetAscent(handle) * size / 1000.0f;
        font.descent = -HPDF_Font_GetDescent(handle) * size / 1000.0f;
        font.x_height = HPDF_Font_GetXHeight(handle) * size / 1000.0f;
        if (font.descent <= 0)
        {
            font.descent = size * 0.22f;
        }
        if (font.ascent <= 0)
        {
            font.ascent = size * 0.78f;
        }
        set_measure_font(font);
        font.ch_width = measure_page ? HPDF_Page_TextWidth(measure_page, "0") : size * 0.6f;
        return true;
    }

    void set_measure_font(const PdfFont& font)
    {
        if (measure_page && font.handle &&
            (measure_font_name != font.name || measure_font_size != font.size))
        {
            HPDF_Page_SetFontAndSize(measure_page, font.handle, font.size);
            measure_font_name = font.name;
            measure_font_size = font.size;
        }
    }

    static bool is_monospace(const std::string& family)
    {
        return family.find("courier") != std::string::npos ||
               family.find("mono") != std::string::npos ||
               family.find("consol") != std::string::npos;
    }

    static bool is_serif(const std::string& family)
    {
        // "sans-serif" contains "serif": check for "sans" first.
        if (family.find("sans") != std::string::npos ||
            family.find("helvetica") != std::string::npos ||
            family.find("arial") != std::string::npos ||
            family.find("verdana") != std::string::npos)
        {
            return false;
        }
        return family.find("serif") != std::string::npos ||
               family.find("times") != std::string::npos ||
               family.find("georgia") != std::string::npos ||
               family.find("garamond") != std::string::npos ||
               family.find("book") != std::string::npos;
    }

    litehtml::uint_ptr create_font(const litehtml::font_description& descr, const litehtml::document* /*doc*/,
                                   litehtml::font_metrics* fm) override
    {
        std::string family = descr.family;
        std::transform(family.begin(), family.end(), family.begin(),
                       [](unsigned char character) { return (char)std::tolower(character); });

        const char* base;
        if (is_monospace(family))
        {
            base = "Courier";
        }
        else if (is_serif(family))
        {
            base = "Times";
        }
        else
        {
            base = "Helvetica";
        }
        bool bold = descr.weight >= 600;
        bool italic = descr.style == litehtml::font_style_italic;
        std::string name;
        if (std::string(base) == "Times")
        {
            name = bold && italic ? "Times-BoldItalic"
                   : bold         ? "Times-Bold"
                   : italic       ? "Times-Italic"
                                  : "Times-Roman";
        }
        else
        {
            name = bold && italic ? std::string(base) + "-BoldOblique"
                   : bold         ? std::string(base) + "-Bold"
                   : italic       ? std::string(base) + "-Oblique"
                                  : base;
        }

        std::string key = descr.hash();
        auto cached = font_cache.find(key);
        if (cached != font_cache.end())
        {
            return cached->second;
        }

        float size = px(descr.size);
        PdfFont font;

        // Embedded TrueType fonts first (full Unicode), matched like CSS
        // would: walk the font-family list through provided and system
        // fonts, generic families expand to commonly installed ones.
        bool want_bold = descr.weight >= 600;
        bool want_italic = descr.style == litehtml::font_style_italic;
        const FontFile* ttf = match_font(descr.family, want_bold, want_italic);
        if (ttf)
        {
            font_covers(*ttf, 'A'); // load coverage once per font file
            font.coverage = ttf->coverage;
        }
        if (ttf && create_ttf_font(*ttf, size, descr.decoration_line, font))
        {
            fonts.push_back(font);
            litehtml::uint_ptr handle = fonts.size();
            font_cache[key] = handle;
            if (fm)
            {
                fm->font_size = size;
                fm->height = font.ascent + font.descent;
                fm->ascent = font.ascent;
                fm->descent = font.descent;
                fm->x_height = font.x_height;
                fm->ch_width = font.ch_width;
                fm->draw_spaces = true;
            }
            return handle;
        }

        // Base-14 fallback (CP1252 text).
        font.name = name;
        font.size = size;
        font.decoration = descr.decoration_line;
        font.handle = HPDF_GetFont(pdf, name.c_str(), nullptr);
        if (font.handle)
        {
            font.ascent = HPDF_Font_GetAscent(font.handle) * size / 1000.0f;
            font.descent = -HPDF_Font_GetDescent(font.handle) * size / 1000.0f;
            font.x_height = HPDF_Font_GetXHeight(font.handle) * size / 1000.0f;
            set_measure_font(font);
            font.ch_width = measure_page ? HPDF_Page_TextWidth(measure_page, "0") : size * 0.6f;
        }
        if (font.descent <= 0)
        {
            font.descent = size * 0.22f;
        }
        if (font.ascent <= 0)
        {
            font.ascent = size * 0.78f;
        }

        fonts.push_back(font);
        litehtml::uint_ptr handle = fonts.size(); // 1-based, 0 stays invalid
        font_cache[key] = handle;

        if (fm)
        {
            fm->font_size = size;
            fm->height = font.ascent + font.descent;
            fm->ascent = font.ascent;
            fm->descent = font.descent;
            fm->x_height = font.x_height;
            fm->ch_width = font.ch_width;
            fm->draw_spaces = true;
        }
        return handle;
    }

    void delete_font(litehtml::uint_ptr /*hFont*/) override {}

    const PdfFont& font(litehtml::uint_ptr handle) const
    {
        return fonts[handle - 1];
    }

    // -- emoji fallback -----------------------------------------------------
    // One designated emoji/symbol font, used for emoji-range codepoints the
    // primary font lacks. Candidates are tried in order; fonts libharu
    // cannot embed (e.g. bitmap color emoji) are skipped.

    std::vector<FontFile> emoji_candidates;
    std::shared_ptr<FontFile> emoji_font_file;
    bool emoji_resolved = false;
    std::map<std::string, litehtml::uint_ptr> emoji_font_cache; // size key -> handle

    bool emoji_possible() const
    {
        return !emoji_resolved || emoji_font_file != nullptr;
    }

    // Find (or reuse) an emoji font that actually covers the codepoint.
    // Candidates claiming coverage but failing to load or drawing blank
    // (.notdef) are skipped.
    const PdfFont* emoji_font_at(float size, int decoration, uint32_t codepoint)
    {
        if (!emoji_resolved)
        {
            emoji_resolved = true;
            if (!g_emoji_font_path.empty())
            {
                FontFile file;
                if (parse_ttf_metadata(g_emoji_font_path, file))
                {
                    emoji_candidates.push_back(file);
                }
            }
            else
            {
                // Monochrome symbol fonts first: color bitmap emoji fonts
                // cannot be embedded with outlines.
                static const char* families[] = {"noto sans symbols 2",  "noto sans symbols", "symbola",
                                                 "segoe ui symbol",      "segoe ui emoji",    "openmoji",
                                                 "noto emoji",           "twitter color emoji",
                                                 "font awesome 7 free",  "font awesome 6 free", "font awesome 5 free",
                                                 "iosevka nerd font",    "noto color emoji"};
                ensure_system_fonts_scanned();
                for (const char* family : families)
                {
                    for (const auto& candidate : g_provided_fonts)
                    {
                        if (candidate.family == family)
                        {
                            emoji_candidates.push_back(candidate);
                        }
                    }
                    for (const auto& candidate : g_system_fonts)
                    {
                        if (candidate.family == family)
                        {
                            emoji_candidates.push_back(candidate);
                        }
                    }
                }
            }
        }
        if (emoji_font_file && font_covers(*emoji_font_file, codepoint))
        {
            std::string key = emoji_font_file->path + "|" + std::to_string((int)(size * 4));
            auto cached = emoji_font_cache.find(key);
            if (cached != emoji_font_cache.end())
            {
                return cached->second ? &fonts[cached->second - 1] : nullptr;
            }
        }
        while (!emoji_candidates.empty())
        {
            FontFile file = emoji_candidates.front();
            emoji_candidates.erase(emoji_candidates.begin());
            if (!font_covers(file, codepoint))
            {
                continue;
            }
            PdfFont font;
            if (!create_ttf_font(file, size, decoration, font))
            {
                continue;
            }
            emoji_font_file = std::make_shared<FontFile>(file);
            fonts.push_back(font);
            litehtml::uint_ptr handle = fonts.size();
            std::string key = file.path + "|" + std::to_string((int)(size * 4));
            emoji_font_cache[key] = handle;
            return &fonts[handle - 1];
        }
        return nullptr;
    }

    // -- text segmentation ----------------------------------------------------
    // Split a UTF-8 run into (font kind, text) pieces: codepoints the
    // primary font covers stay there; missing emoji-range codepoints go
    // to the emoji font; joiners and variation selectors are dropped.

    static bool cp1252_covers(uint32_t codepoint)
    {
        if (codepoint < 0x100)
        {
            return true;
        }
        switch (codepoint)
        {
        case 0x20AC: case 0x2018: case 0x2019: case 0x201C: case 0x201D:
        case 0x2022: case 0x2013: case 0x2014: case 0x2122:
            return true;
        default:
            return false;
        }
    }

    struct TextPiece
    {
        int kind;          // 0 = primary font, 1 = emoji font
        uint32_t codepoint; // first codepoint in the piece
        std::string text;
    };

    std::vector<TextPiece> segment_text(const char* text, const PdfFont& primary)
    {
        std::vector<TextPiece> out;
        const unsigned char* cursor = reinterpret_cast<const unsigned char*>(text);
        size_t byte_pos = 0;
        int current_kind = -1;
        size_t current_start = 0;
        uint32_t piece_codepoint = 0;
        auto flush = [&](size_t end) {
            if (current_kind >= 0 && end > current_start)
            {
                out.push_back({current_kind, piece_codepoint, std::string(text + current_start, end - current_start)});
            }
        };
        while (*cursor)
        {
            uint32_t codepoint = cursor[0];
            int extra = 0;
            if (codepoint >= 0xF0)
            {
                codepoint &= 0x07;
                extra = 3;
            }
            else if (codepoint >= 0xE0)
            {
                codepoint &= 0x0F;
                extra = 2;
            }
            else if (codepoint >= 0xC0)
            {
                codepoint &= 0x1F;
                extra = 1;
            }
            bool valid = true;
            for (int i = 0; i < extra; i++)
            {
                if ((cursor[1 + i] & 0xC0) != 0x80)
                {
                    valid = false;
                    break;
                }
                codepoint = (codepoint << 6) | (uint32_t)(cursor[1 + i] & 0x3F);
            }
            if (!valid)
            {
                flush(byte_pos);
                current_kind = -1;
                byte_pos += 1;
                cursor += 1;
                continue;
            }
            size_t length = (size_t)extra + 1;
            if (is_zero_width_codepoint(codepoint))
            {
                flush(byte_pos);
                current_kind = -1;
            }
            else
            {
                bool primary_covers = primary.utf8 ? (!primary.coverage || primary.coverage->covers(codepoint))
                                                   : cp1252_covers(codepoint);
                int kind = 0;
                if (!primary_covers && emoji_possible() && is_emoji_codepoint(codepoint))
                {
                    kind = 1;
                }
                if (kind != current_kind)
                {
                    flush(byte_pos);
                    current_kind = kind;
                    current_start = byte_pos;
                    piece_codepoint = codepoint;
                }
            }
            byte_pos += length;
            cursor += length;
        }
        flush(byte_pos);
        return out;
    }

    litehtml::pixel_t text_width(const char* text, litehtml::uint_ptr hFont) override
    {
        const PdfFont& f = font(hFont);
        if (!measure_page)
        {
            return 0;
        }
        float width = 0;
        for (const auto& segment : segment_text(text, f))
        {
            const PdfFont* segment_font = segment.kind == 1 ? emoji_font_at(f.size, f.decoration, segment.codepoint) : &f;
            if (!segment_font)
            {
                continue;
            }
            set_measure_font(*segment_font);
            std::string piece = segment_font->utf8 ? segment.text : to_cp1252(segment.text.c_str());
            width += HPDF_Page_TextWidth(measure_page, piece.c_str());
        }
        return width;
    }

    // -- drawing -----------------------------------------------------------

    DrawContext* ctx(litehtml::uint_ptr hdc) const
    {
        return reinterpret_cast<DrawContext*>(hdc);
    }

    void set_fill(litehtml::uint_ptr hdc, const litehtml::web_color& color)
    {
        DrawContext* context = ctx(hdc);
        // libharu has no alpha: blend over the white page.
        float alpha = color.alpha / 255.0f;
        float blend = [&](float channel) { return 255.0f - alpha * (255.0f - channel); }(color.red);
        HPDF_Page_SetRGBFill(context->page, blend / 255.0f,
                             (255.0f - alpha * (255.0f - color.green)) / 255.0f,
                             (255.0f - alpha * (255.0f - color.blue)) / 255.0f);
    }

    void fill_rect(litehtml::uint_ptr hdc, float left, float top, float width, float height)
    {
        DrawContext* context = ctx(hdc);
        HPDF_Page_Rectangle(context->page, context->pdf_x(left), context->pdf_y(top) - height, width, height);
        HPDF_Page_Fill(context->page);
    }

    void draw_text(litehtml::uint_ptr hdc, const char* text, litehtml::uint_ptr hFont,
                   litehtml::web_color color, const litehtml::position& pos) override
    {
        DrawContext* context = ctx(hdc);
        if (!context->page)
        {
            return;
        }
        const PdfFont& f = font(hFont);
        set_fill(hdc, color);
        g_last_op = std::string("draw_text '") + std::string(text).substr(0, 20) + "'";
        if (getenv("LITEPDF_DEBUG")) std::fprintf(stderr, "draw_text '%s' x=%.1f y=%.1f w=%.1f h=%.1f\n", text, px(pos.x), px(pos.y), px(pos.width), px(pos.height));
        float baseline = context->pdf_y(pos.y + pos.height - f.descent);
        // Draw segment by segment; emoji-range codepoints the primary font
        // lacks come from the emoji font at the shared baseline.
        float cursor = context->pdf_x(px(pos.x));
        for (const auto& segment : segment_text(text, f))
        {
            const PdfFont* segment_font = segment.kind == 1 ? emoji_font_at(f.size, f.decoration, segment.codepoint) : &f;
            if (!segment_font)
            {
                continue;
            }
            g_last_op = "segment: SetFontAndSize";
            HPDF_Page_SetFontAndSize(context->page, segment_font->handle, segment_font->size);
            std::string piece = segment_font->utf8 ? segment.text : to_cp1252(segment.text.c_str());
            g_last_op = "segment: BeginText";
            HPDF_Page_BeginText(context->page);
            g_last_op = "segment: TextOut";
            HPDF_Page_TextOut(context->page, cursor, baseline, piece.c_str());
            g_last_op = "segment: EndText";
            HPDF_Page_EndText(context->page);
            g_last_op = "segment: measure";
            set_measure_font(*segment_font);
            cursor += measure_page ? HPDF_Page_TextWidth(measure_page, piece.c_str()) : 0.0f;
        }

        int decoration = f.decoration;
        if (decoration & (litehtml::text_decoration_line_underline | litehtml::text_decoration_line_line_through |
                          litehtml::text_decoration_line_overline))
        {
            float thickness = std::max(0.6f, f.size / 14.0f);
            // PDF y grows upward: positive offsets sit above the baseline.
            float offset;
            if (decoration & litehtml::text_decoration_line_underline)
            {
                offset = -f.size * 0.14f;
            }
            else if (decoration & litehtml::text_decoration_line_line_through)
            {
                offset = f.size * 0.28f;
            }
            else
            {
                offset = f.ascent + f.size * 0.06f;
            }
            HPDF_Page_SetLineWidth(context->page, thickness);
            HPDF_Page_SetRGBStroke(context->page, color.red / 255.0f, color.green / 255.0f, color.blue / 255.0f);
            float line_y = baseline + offset;
            HPDF_Page_MoveTo(context->page, context->pdf_x(pos.x), line_y);
            HPDF_Page_LineTo(context->page, context->pdf_x(pos.x + pos.width), line_y);
            HPDF_Page_Stroke(context->page);
        }
    }

    litehtml::pixel_t pt_to_px(float pt) const override
    {
        return pt * 96.0f / 72.0f;
    }

    litehtml::pixel_t get_default_font_size() const override
    {
        return 11;
    }

    const char* get_default_font_name() const override
    {
        return "Helvetica";
    }

    void draw_list_marker(litehtml::uint_ptr hdc, const litehtml::list_marker& marker) override
    {
        DrawContext* context = ctx(hdc);
        if (!context->page)
        {
            return;
        }
        g_last_op = "draw_list_marker";
        litehtml::list_style_type type = marker.marker_type;
        float size = std::max(3.0f, px(marker.pos.height) * 0.22f);
        float center_x = context->pdf_x(px(marker.pos.x) + px(marker.pos.width) * 0.5f);
        float top = px(marker.pos.y) + px(marker.pos.height) * 0.5f;

        switch (type)
        {
        case litehtml::list_style_type_disc:
        case litehtml::list_style_type_circle:
        case litehtml::list_style_type_square:
        {
            // SetLineWidth before constructing the path: libharu requires
            // page graphics mode for it.
            bool stroked = type == litehtml::list_style_type_circle;
            if (stroked)
            {
                HPDF_Page_SetLineWidth(context->page, std::max(0.6f, size / 6));
            }
            g_last_op = "marker: set_fill";
            set_fill(hdc, marker.color);
            g_last_op = "marker: shape";
            if (type == litehtml::list_style_type_square)
            {
                HPDF_Page_Rectangle(context->page, center_x - size / 2, context->pdf_y(top) - size / 2, size, size);
            }
            else
            {
                HPDF_Page_Circle(context->page, center_x, context->pdf_y(top), size / 2);
            }
            g_last_op = "marker: paint";
            if (stroked)
            {
                HPDF_Page_Stroke(context->page);
            }
            else
            {
                HPDF_Page_Fill(context->page);
            }
            break;
        }
        case litehtml::list_style_type_none:
            break;
        default:
        {
            // Ordered lists: render the index as text.
            if (marker.font)
            {
                const PdfFont& f = font(marker.font);
                std::string label = format_index(marker.index, type);
                std::string encoded = to_cp1252(label.c_str());
                HPDF_Page_SetFontAndSize(context->page, f.handle, f.size);
                set_fill(hdc, marker.color);
                float baseline = context->pdf_y(px(marker.pos.y) + px(marker.pos.height) - f.descent);
                HPDF_Page_BeginText(context->page);
                HPDF_Page_TextOut(context->page,
                                  context->pdf_x(px(marker.pos.x) + px(marker.pos.width) - f.size * 0.2f) -
                                      HPDF_Page_TextWidth(context->page, encoded.c_str()),
                                  baseline, encoded.c_str());
                HPDF_Page_EndText(context->page);
            }
        }
        }
    }

    static std::string format_index(int index, litehtml::list_style_type type)
    {
        char buffer[32];
        switch (type)
        {
        case litehtml::list_style_type_lower_alpha:
        case litehtml::list_style_type_lower_latin:
        case litehtml::list_style_type_lower_greek:
            if (index >= 1 && index <= 26)
            {
                char letter = (char)('a' + index - 1);
                return std::string(1, letter) + ".";
            }
            return std::to_string(index) + ".";
        case litehtml::list_style_type_upper_alpha:
        case litehtml::list_style_type_upper_latin:
            if (index >= 1 && index <= 26)
            {
                char letter = (char)('A' + index - 1);
                return std::string(1, letter) + ".";
            }
            return std::to_string(index) + ".";
        case litehtml::list_style_type_lower_roman:
            return to_roman(index, true) + ".";
        case litehtml::list_style_type_upper_roman:
            return to_roman(index, false) + ".";
        case litehtml::list_style_type_decimal_leading_zero:
            std::snprintf(buffer, sizeof(buffer), "%02d.", index);
            return buffer;
        default:
            std::snprintf(buffer, sizeof(buffer), "%d.", index);
            return buffer;
        }
    }

    static std::string to_roman(int value, bool lower)
    {
        static const struct
        {
            int value;
            const char* symbol;
        } table[] = {
            {1000, "m"}, {900, "cm"}, {500, "d"}, {400, "cd"}, {100, "c"},
            {90, "xc"},  {50, "l"},   {40, "xl"}, {10, "x"},   {9, "ix"},
            {5, "v"},    {4, "iv"},   {1, "i"},
        };
        std::string out;
        for (const auto& entry : table)
        {
            while (value >= entry.value)
            {
                out += entry.symbol;
                value -= entry.value;
            }
        }
        if (!lower)
        {
            std::transform(out.begin(), out.end(), out.begin(), [](unsigned char character) {
                return (char)std::toupper(character);
            });
        }
        return out;
    }

    // -- images -----------------------------------------------------------

    std::map<std::string, HPDF_Image> image_cache;

    std::string resolve_path(const char* src, const char* baseurl)
    {
        std::string path = src ? src : "";
        if (path.empty())
        {
            return path;
        }
        if (path[0] == '/')
        {
            return path;
        }
        std::string directory = baseurl && *baseurl ? baseurl : base_dir;
        if (!directory.empty() && directory.back() != '/')
        {
            directory += '/';
        }
        return directory + path;
    }

    HPDF_Image load_image(const char* src, const char* baseurl)
    {
        std::string path = resolve_path(src, baseurl);
        auto cached = image_cache.find(path);
        if (cached != image_cache.end())
        {
            return cached->second;
        }
        // Remote (http/https) images are not supported: skip them without
        // tripping libharu's error state.
        bool remote = path.rfind("http://", 0) == 0 || path.rfind("https://", 0) == 0;
        HPDF_Image image = nullptr;
        if (!remote)
        {
            if (path.size() > 4)
            {
                std::string lower = path;
                std::transform(lower.begin(), lower.end(), lower.begin(),
                               [](unsigned char character) { return (char)std::tolower(character); });
                if (lower.rfind(".jpg") == lower.size() - 4 || lower.rfind(".jpeg") == lower.size() - 5)
                {
                    image = HPDF_LoadJpegImageFromFile(pdf, path.c_str());
                }
                else
                {
                    image = HPDF_LoadPngImageFromFile(pdf, path.c_str());
                }
            }
            else
            {
                image = HPDF_LoadPngImageFromFile(pdf, path.c_str());
            }
        }
        if (!image)
        {
            // A failed load sets the document error state, which would
            // make every subsequent HPDF_AddPage return null.
            HPDF_ResetError(pdf);
        }
        image_cache[path] = image;
        return image;
    }

    void load_image(const char* /*src*/, const char* /*baseurl*/, bool /*redraw_on_ready*/) override {}

    void get_image_size(const char* src, const char* baseurl, litehtml::size& sz) override
    {
        HPDF_Image image = load_image(src, baseurl);
        if (image)
        {
            HPDF_Point size = HPDF_Image_GetSize(image);
            sz.width = size.x;
            sz.height = size.y;
        }
    }

    void draw_image(litehtml::uint_ptr hdc, const litehtml::background_layer& layer, const std::string& url,
                    const std::string& base_url) override
    {
        DrawContext* context = ctx(hdc);
        HPDF_Image image = load_image(url.c_str(), base_url.c_str());
        if (!image || !context->page)
        {
            return;
        }
        const litehtml::position& box = layer.border_box;
        HPDF_Page_DrawImage(context->page, image, context->pdf_x(px(box.x)),
                            context->pdf_y(px(box.y)) - px(box.height), px(box.width), px(box.height));
    }

    // -- backgrounds and borders -------------------------------------------

    void draw_solid_fill(litehtml::uint_ptr hdc, const litehtml::background_layer& layer,
                         const litehtml::web_color& color) override
    {
        if (getenv("LITEPDF_DEBUG")) std::fprintf(stderr, "solid_fill CALLED\n");
        DrawContext* context = ctx(hdc);
        if (!context->page)
        {
            return;
        }
        if (color.alpha == 0)
        {
            return;
        }
        set_fill(hdc, color);
        if (getenv("LITEPDF_DEBUG")) std::fprintf(stderr, "solid_fill box x=%.1f y=%.1f w=%.1f h=%.1f\n", px(layer.border_box.x), px(layer.border_box.y), px(layer.border_box.width), px(layer.border_box.height));
        fill_rect(hdc, px(layer.border_box.x), px(layer.border_box.y), px(layer.border_box.width),
                  px(layer.border_box.height));
    }

    void draw_linear_gradient(litehtml::uint_ptr, const litehtml::background_layer&,
                              const litehtml::background_layer::linear_gradient&) override
    {
    }

    void draw_radial_gradient(litehtml::uint_ptr, const litehtml::background_layer&,
                              const litehtml::background_layer::radial_gradient&) override
    {
    }

    void draw_conic_gradient(litehtml::uint_ptr, const litehtml::background_layer&,
                             const litehtml::background_layer::conic_gradient&) override
    {
    }

    void draw_borders(litehtml::uint_ptr hdc, const litehtml::borders& borders,
                      const litehtml::position& draw_pos, bool /*root*/) override
    {
        DrawContext* context = ctx(hdc);
        if (!context->page)
        {
            return;
        }
        const litehtml::border* sides[4] = {&borders.left, &borders.top, &borders.right, &borders.bottom};
        float left = px(draw_pos.x);
        float top = px(draw_pos.y);
        float right = left + px(draw_pos.width);
        float bottom = top + px(draw_pos.height);

        for (int i = 0; i < 4; i++)
        {
            const litehtml::border* side = sides[i];
            if (!side || side->style == litehtml::border_style_none || side->style == litehtml::border_style_hidden ||
                px(side->width) <= 0)
            {
                continue;
            }
            if (side->color.alpha == 0)
            {
                continue;
            }
            HPDF_Page_SetLineWidth(context->page, px(side->width));
            HPDF_Page_SetRGBStroke(context->page, side->color.red / 255.0f, side->color.green / 255.0f,
                                   side->color.blue / 255.0f);
            float inset = px(side->width) / 2;
            switch (i)
            {
            case 0: // left
                HPDF_Page_MoveTo(context->page, context->pdf_x(left) + inset, context->pdf_y(top));
                HPDF_Page_LineTo(context->page, context->pdf_x(left) + inset, context->pdf_y(bottom));
                break;
            case 1: // top
                HPDF_Page_MoveTo(context->page, context->pdf_x(left), context->pdf_y(top) + inset);
                HPDF_Page_LineTo(context->page, context->pdf_x(right), context->pdf_y(top) + inset);
                break;
            case 2: // right
                HPDF_Page_MoveTo(context->page, context->pdf_x(right) - inset, context->pdf_y(top));
                HPDF_Page_LineTo(context->page, context->pdf_x(right) - inset, context->pdf_y(bottom));
                break;
            case 3: // bottom
                HPDF_Page_MoveTo(context->page, context->pdf_x(left), context->pdf_y(bottom) - inset);
                HPDF_Page_LineTo(context->page, context->pdf_x(right), context->pdf_y(bottom) - inset);
                break;
            }
            HPDF_Page_Stroke(context->page);
        }
    }

    // -- interaction callbacks: no-ops for print output ----------------------

    void set_caption(const char* caption) override
    {
        if (caption && *caption)
        {
            bool ascii = true;
            for (const char* character = caption; *character; character++)
            {
                if ((unsigned char)*character > 126)
                {
                    ascii = false;
                    break;
                }
            }
            if (ascii)
            {
                HPDF_SetInfoAttr(pdf, HPDF_INFO_TITLE, caption);
            }
        }
    }

    void set_base_url(const char* /*base_url*/) override {}
    void link(const std::shared_ptr<litehtml::document>&, const litehtml::element::ptr&) override {}
    void on_anchor_click(const char*, const litehtml::element::ptr&) override {}
    void on_mouse_event(const litehtml::element::ptr&, litehtml::mouse_event) override {}
    void set_cursor(const char*) override {}

    void transform_text(std::string& text, litehtml::text_transform tt) override
    {
        switch (tt)
        {
        case litehtml::text_transform_capitalize:
        {
            bool word_start = true;
            for (auto& character : text)
            {
                if (std::isspace((unsigned char)character))
                {
                    word_start = true;
                }
                else if (word_start)
                {
                    character = (char)std::toupper((unsigned char)character);
                    word_start = false;
                }
            }
            break;
        }
        case litehtml::text_transform_uppercase:
            std::transform(text.begin(), text.end(), text.begin(),
                           [](unsigned char character) { return (char)std::toupper(character); });
            break;
        case litehtml::text_transform_lowercase:
            std::transform(text.begin(), text.end(), text.begin(),
                           [](unsigned char character) { return (char)std::tolower(character); });
            break;
        default:
            break;
        }
    }

    void import_css(std::string& text, const std::string& url, std::string& baseurl) override
    {
        std::string path = resolve_path(url.c_str(), baseurl.c_str());
        std::FILE* file = std::fopen(path.c_str(), "rb");
        if (!file)
        {
            text.clear();
            return;
        }
        text.clear();
        char buffer[4096];
        size_t read;
        while ((read = std::fread(buffer, 1, sizeof(buffer), file)) > 0)
        {
            text.append(buffer, read);
        }
        std::fclose(file);
        std::string::size_type slash = path.rfind('/');
        baseurl = slash == std::string::npos ? std::string() : path.substr(0, slash);
    }

    // set_clip/del_clip don't carry hdc, so the active context is
    // swapped in while a document is being drawn.
    DrawContext* active_context = nullptr;

    void set_clip(const litehtml::position& pos, const litehtml::border_radiuses&) override
    {
        // Every set_clip must pair with the del_clip GRestore, even for
        // degenerate boxes, or the GSave/GRestore stack underflows and
        // poisons the document (later HPDF_AddPage calls return null).
        DrawContext* context = active_context;
        if (!context || !context->page)
        {
            return;
        }
        float left = context->pdf_x(px(pos.x));
        float top = context->pdf_y(px(pos.y));
        float width = std::max(px(pos.width), 0.01f);
        float height = std::max(px(pos.height), 0.01f);
        HPDF_Page_GSave(context->page);
        HPDF_Page_Rectangle(context->page, left, top - height, width, height);
        HPDF_Page_Clip(context->page);
        HPDF_Page_EndPath(context->page);
        context->clip_depth++;
    }

    void del_clip() override
    {
        DrawContext* context = active_context;
        if (!context || !context->page || context->clip_depth == 0)
        {
            return;
        }
        HPDF_Page_GRestore(context->page);
        context->clip_depth--;
    }

    void get_viewport(litehtml::position& viewport) const override
    {
        viewport.x = 0;
        viewport.y = 0;
        viewport.width = content_width;
        viewport.height = 1000000;
    }

    litehtml::element::ptr create_element(const char*, const litehtml::string_map&,
                                          const std::shared_ptr<litehtml::document>&) override
    {
        return nullptr;
    }

    void get_media_features(litehtml::media_features& media) const override
    {
        media.width = content_width;
        media.height = 1000000;
        media.device_width = content_width;
        media.device_height = 1000000;
        media.color = 8;
        media.color_index = 24;
        media.resolution = 96;
        media.monochrome = 0;
    }

    void get_language(std::string& language, std::string& culture) const override
    {
        language = "en";
        culture = "";
    }

    // -- links -------------------------------------------------------------
    // <a href="scheme:..."> elements become real PDF URI annotations and
    // <a href="#name"> become GoTo annotations targeting the element with
    // the matching id: after layout, each anchor's inline boxes become
    // clickable rectangles (split across pages when a link wraps).

    struct LinkRect
    {
        std::string uri; // external: the URI; internal: the target id
        float x, y, width, height;
        bool external;
    };

    // An id="..." target: document-space position to jump to.
    struct AnchorTarget
    {
        std::string name;
        float x, y;
    };

    std::vector<LinkRect> links;
    std::vector<AnchorTarget> targets;

    static bool is_external_uri(const std::string& uri)
    {
        return uri.find("://") != std::string::npos || uri.rfind("mailto:", 0) == 0;
    }

    void collect_links(const std::shared_ptr<litehtml::render_item>& item, float offset_x, float offset_y)
    {
        if (!item)
        {
            return;
        }
        litehtml::position pos = item->pos();
        float abs_x = offset_x + px(pos.x);
        float abs_y = offset_y + px(pos.y);
        if (item->src_el())
        {
            const char* id = item->src_el()->get_attr("id");
            if (id && *id)
            {
                bool known = false;
                for (const auto& target : targets)
                {
                    known = target.name == id;
                    if (known)
                    {
                        break;
                    }
                }
                if (!known)
                {
                    targets.push_back({id, abs_x, abs_y});
                }
            }
            const char* href = item->src_el()->get_tagName() == std::string("a")
                                   ? item->src_el()->get_attr("href")
                                   : nullptr;
            if (href && *href)
            {
                std::string uri = href;
                bool external = is_external_uri(uri);
                bool internal = uri.size() > 1 && uri[0] == '#';
                if (external || internal)
                {
                    std::vector<LinkRect> rects;
                    item->for_inline_boxes([&](const litehtml::position& box, bool /*first*/, bool /*last*/) {
                        if (px(box.width) > 0 && px(box.height) > 0)
                        {
                            rects.push_back({uri, abs_x + px(box.x), abs_y + px(box.y), px(box.width),
                                             px(box.height), external});
                        }
                        return true;
                    });
                    if (rects.empty() && px(pos.width) > 0 && px(pos.height) > 0)
                    {
                        rects.push_back({uri, abs_x, abs_y, px(pos.width), px(pos.height), external});
                    }
                    for (const auto& rect : rects)
                    {
                        links.push_back(rect);
                    }
                }
            }
        }
        for (const auto& child : item->children())
        {
            collect_links(child, abs_x, abs_y);
        }
    }

    // -- pagination -----------------------------------------------------------

    bool is_atomic(const std::string& tag) const
    {
        // li is atomic too: the marker sits outside the item's content box,
        // so a break between marker and text would orphan the bullet.
        static const std::set<std::string> atomic_tags = {"h1", "h2", "h3", "h4", "h5", "h6", "table",  "tr",
                                                          "pre", "img", "td", "th", "figure", "svg", "hr",
                                                          "li"};
        return atomic_tags.count(tag) > 0;
    }

    // Collect safe page-start candidates: the tops of block elements and
    // the tops of individual inline line boxes. Tops of atomic elements
    // (headings, tables, code blocks...) are candidates; their interiors
    // are not, so they never get split across pages.
    // render_item positions are relative to the parent's content box
    // (litehtml accumulates x/y offsets while drawing), so the walk must
    // accumulate them too to get document-space coordinates.
    void collect_breaks(const std::shared_ptr<litehtml::render_item>& item, float offset_x, float offset_y,
                        bool inside_atomic, std::set<int>& candidates)
    {
        if (!item)
        {
            return;
        }
        litehtml::position pos = item->pos();
        float abs_x = offset_x + px(pos.x);
        float abs_y = offset_y + px(pos.y);
        if (getenv("LITEPDF_WALK")) std::fprintf(stderr, "walk tag=%s y=%.1f h=%.1f atomic=%d\n",
            item->src_el() ? item->src_el()->get_tagName() : "?", abs_y, px(pos.height), (int)inside_atomic);
        // Candidates use the margin/border-box top: breaking there keeps
        // backgrounds and borders of the element together with its text.
        if (px(pos.width) > 0 || px(pos.height) > 0)
        {
            candidates.insert((int)std::floor(offset_y + px(item->top())));
        }
        bool atomic = inside_atomic;
        if (item->src_el())
        {
            atomic = atomic || is_atomic(item->src_el()->get_tagName());
        }
        if (atomic)
        {
            return;
        }
        item->for_inline_boxes([&](const litehtml::position& box, bool /*first*/, bool /*last*/) {
            candidates.insert((int)std::floor(abs_y + px(box.y)));
            return true;
        });
        for (const auto& child : item->children())
        {
            collect_breaks(child, abs_x, abs_y, atomic, candidates);
        }
    }
};

} // namespace

// -- C API ------------------------------------------------------------------

extern "C"
{

// Set page header/footer templates drawn in the top/bottom margin of
// every page. "%p" expands to the page number, "%t" to the total page
// count. NULL or empty disables.
void litepdf_set_page_text(const char* header, const char* footer)
{
    g_header_template = header ? header : "";
    g_footer_template = footer ? footer : "";
}

// Set the page background color (CSS "#rrggbb"); empty = white.
void litepdf_set_page_background(const char* css_color)
{
    g_page_background = css_color ? css_color : "";
}

// Register a TTF file as a candidate font for font-family matching.
// Provided fonts take priority over scanned system fonts. Parses the
// font's metadata; returns 1 on success, 0 and fills errbuf on failure.
int litepdf_register_font(const char* ttf_path, char* errbuf, int errbuf_len)
{
    if (errbuf && errbuf_len > 0)
    {
        errbuf[0] = '\0';
    }
    if (!ttf_path || !*ttf_path)
    {
        if (errbuf)
        {
            std::snprintf(errbuf, errbuf_len, "empty font path");
        }
        return 0;
    }
    FontFile font;
    if (!parse_ttf_metadata(ttf_path, font))
    {
        if (errbuf)
        {
            std::snprintf(errbuf, errbuf_len, "'%s' is not a usable TrueType font", ttf_path);
        }
        return 0;
    }
    for (const auto& existing : g_provided_fonts)
    {
        if (existing.path == font.path)
        {
            return 1;
        }
    }
    g_provided_fonts.push_back(font);
    return 1;
}

// Designate the emoji/symbol fallback font. When not set, well-known
// system symbol fonts are tried automatically. Returns 1 on success.
int litepdf_set_emoji_font(const char* ttf_path, char* errbuf, int errbuf_len)
{
    if (ttf_path && *ttf_path)
    {
        FontFile font;
        if (!parse_ttf_metadata(ttf_path, font))
        {
            if (errbuf)
            {
                std::snprintf(errbuf, errbuf_len, "'%s' is not a usable TrueType font", ttf_path);
            }
            return 0;
        }
    }
    g_emoji_font_path = ttf_path ? ttf_path : "";
    return 1;
}

// Render HTML to a PDF file. css is the author stylesheet (the caller
// concatenates the default stylesheet and any user CSS). base_dir resolves
// relative image paths. page_size: 0 = A4, 1 = Letter. margin_pt is the
// uniform page margin. Returns the number of pages, or -1 and fills
// errbuf on failure.
int litepdf_render(const char* html, const char* css, int page_size, float margin_pt, const char* out_path,
                   const char* base_dir, char* errbuf, int errbuf_len)
{
    if (errbuf && errbuf_len > 0)
    {
        errbuf[0] = '\0';
    }
    HPDF_Doc pdf = HPDF_New(nullptr, nullptr);
    if (!pdf)
    {
        if (errbuf)
        {
            std::snprintf(errbuf, errbuf_len, "failed to create libharu document");
        }
        return -1;
    }
    HPDF_SetErrorHandler(pdf, hpdf_error_handler);
    g_hpdf_error = 0;
    g_last_op = "creating document";
    HPDF_SetCompressionMode(pdf, HPDF_COMP_ALL);
    HPDF_UseUTFEncodings(pdf);

    PdfContainer container(pdf);
    container.base_dir = base_dir ? base_dir : ".";
    if (container.base_dir.empty())
    {
        container.base_dir = ".";
    }

    // First page doubles as the font measurement page; it becomes page 1
    // of the output and the first page window is drawn onto it.
    container.measure_page = HPDF_AddPage(pdf);
    if (!container.measure_page)
    {
        std::snprintf(errbuf, errbuf_len, "failed to create page");
        HPDF_Free(pdf);
        return -1;
    }

    const char* user_css = css ? css : "";
    g_last_op = "parsing HTML";
    std::shared_ptr<litehtml::document> doc;
    try
    {
        doc = litehtml::document::createFromString(html, &container, litehtml::master_css, user_css);
    }
    catch (const std::exception& error)
    {
        std::snprintf(errbuf, errbuf_len, "html parse failed: %s", error.what());
        HPDF_Free(pdf);
        return -1;
    }
    if (!doc)
    {
        std::snprintf(errbuf, errbuf_len, "html parse failed");
        HPDF_Free(pdf);
        return -1;
    }

    float page_width = page_size == 1 ? 612.0f : 595.276f;
    float page_height = page_size == 1 ? 792.0f : 841.89f;
    float margin = margin_pt;
    if (margin * 2 >= page_width || margin * 2 >= page_height)
    {
        margin = page_width * 0.05f;
    }
    float content_width = page_width - margin * 2;
    container.content_width = content_width;

    // Note: render() returns the root's natural width; the laid-out
    // document height is what matters for pagination.
    doc->render(content_width);
    float total_height = px(doc->height());
    if (total_height <= 0)
    {
        std::snprintf(errbuf, errbuf_len, "document rendered to zero height");
        HPDF_Free(pdf);
        return -1;
    }

    // Page windows: greedy over safe break candidates.
    float content_height = page_height - margin * 2;
    std::set<int> raw_candidates;
    container.collect_breaks(doc->root_render(), 0, 0, false, raw_candidates);
    container.collect_links(doc->root_render(), 0, 0);
    if (getenv("LITEPDF_DEBUG")) std::fprintf(stderr, "links collected: %zu\n", container.links.size());
    std::vector<int> candidates(raw_candidates.begin(), raw_candidates.end());
    if (candidates.empty() || candidates[0] > 0)
    {
        candidates.insert(candidates.begin(), 0);
    }

    if (getenv("LITEPDF_DEBUG")) std::fprintf(stderr, "total_height=%.1f content_height=%.1f candidates=%zu\n", total_height, content_height, candidates.size());
    std::vector<std::pair<float, float>> windows;
    {
        float start = 0;
        while (start < total_height)
        {
            float limit = start + content_height;
            if (limit >= total_height)
            {
                windows.emplace_back(start, total_height);
                break;
            }
            // Largest candidate <= limit; fall back to a forced mid-cut if
            // nothing fits (a single element taller than a page).
            float next = -1;
            for (auto it = candidates.rbegin(); it != candidates.rend(); ++it)
            {
                if (*it <= limit && *it > start)
                {
                    next = (float)*it;
                    break;
                }
            }
            if (next <= start)
            {
                next = limit;
            }
            windows.emplace_back(start, next);
            start = next;
        }
    }

    if (getenv("LITEPDF_DEBUG")) { for (auto& w : windows) std::fprintf(stderr, "window %.1f..%.1f\n", w.first, w.second); }
    DrawContext context;
    container.active_context = &context;
    int page_count = 0;
    int total_pages = (int)windows.size();
    // Headers/footers use the body font (the first one created).
    const PdfFont* page_text_font = container.fonts.empty() ? nullptr : &container.fonts[0];
    auto draw_page_text = [&](const std::string& templ, bool top)
    {
        if (templ.empty() || !page_text_font || !context.page)
        {
            return;
        }
        std::string text = templ;
        std::string number = std::to_string(page_count + 1);
        std::string total = std::to_string(total_pages);
        for (size_t pos = text.find("%p"); pos != std::string::npos; pos = text.find("%p"))
        {
            text.replace(pos, 2, number);
        }
        for (size_t pos = text.find("%t"); pos != std::string::npos; pos = text.find("%t"))
        {
            text.replace(pos, 2, total);
        }
        const char* drawn = text.c_str();
        std::string encoded;
        if (!page_text_font->utf8)
        {
            encoded = to_cp1252(text.c_str());
            drawn = encoded.c_str();
        }
        float size = std::max(7.0f, page_text_font->size * 0.85f);
        HPDF_Page_SetFontAndSize(context.page, page_text_font->handle, size);
        HPDF_Page_SetRGBFill(context.page, 0.45f, 0.45f, 0.45f);
        float width = HPDF_Page_TextWidth(context.page, drawn);
        float y = top ? page_height - margin * 0.35f : margin * 0.35f;
        HPDF_Page_BeginText(context.page);
        HPDF_Page_TextOut(context.page, (page_width - width) / 2.0f, y, drawn);
        HPDF_Page_EndText(context.page);
    };
    std::vector<HPDF_Page> page_handles;
    // Internal links wait for all pages to exist: their annotations need
    // destinations bound to (possibly earlier) pages.
    struct PendingInternalLink
    {
        size_t page_index;
        HPDF_Rect rect;
        std::string target;
    };
    std::vector<PendingInternalLink> pending_internal;
    for (const auto& window : windows)
    {
        HPDF_Page page;
        if (page_count == 0)
        {
            page = container.measure_page;
        }
        else
        {
            page = HPDF_AddPage(pdf);
        }
        if (!page)
        {
            std::snprintf(errbuf, errbuf_len, "failed to create page %d: %s",
                          page_count + 1, describe_hpdf_error().c_str());
            HPDF_Free(pdf);
            return -1;
        }
        HPDF_Page_SetWidth(page, page_width);
        HPDF_Page_SetHeight(page, page_height);
        // Themed page background: fill the whole page before clipping.
        if (g_page_background.size() >= 7 && g_page_background[0] == '#')
        {
            auto channel = [](const std::string& text, size_t offset) {
                return std::strtol(text.substr(offset, 2).c_str(), nullptr, 16) / 255.0f;
            };
            HPDF_Page_SetRGBFill(page, channel(g_page_background, 1), channel(g_page_background, 3),
                                 channel(g_page_background, 5));
            HPDF_Page_Rectangle(page, 0, 0, page_width, page_height);
            HPDF_Page_Fill(page);
        }
        g_last_op = "drawing page " + std::to_string(page_count + 1);
        context.page = page;
        context.page_height = page_height;
        context.y_offset = window.first;
        context.x_offset = margin;
        context.top_margin = margin;
        // Physically clip drawing to this page's window (content area
        // slice): litehtml only culls elements whose boxes intersect the
        // clip, and draws list markers unculled, relying on the container.
        float window_height = window.second - window.first;
        HPDF_Page_GSave(page);
        HPDF_Page_Rectangle(page, margin, page_height - margin - window_height,
                            page_width - margin * 2, window_height);
        HPDF_Page_Clip(page);
        HPDF_Page_EndPath(page);
        litehtml::position clip(0, (int)std::floor(window.first),
                                (int)std::ceil(content_width),
                                (int)std::ceil(window.second - window.first));
        doc->draw(reinterpret_cast<litehtml::uint_ptr>(&context), 0, 0, &clip);
        while (context.clip_depth > 0)
        {
            HPDF_Page_GRestore(page);
            context.clip_depth--;
        }
        HPDF_Page_GRestore(page);
        // Header/footer go in the margins, outside the window clip.
        draw_page_text(g_header_template, true);
        draw_page_text(g_footer_template, false);

        // Link annotations for every anchor rectangle on this page's window.
        if (getenv("LITEPDF_DEBUG")) std::fprintf(stderr, "page %d: links=%zu window=%.1f..%.1f\n", page_count, container.links.size(), window.first, window.second);
        for (const auto& link : container.links)
        {
            float top_doc = link.y;
            float bottom_doc = link.y + link.height;
            if (bottom_doc <= window.first || top_doc >= window.second)
            {
                continue;
            }
            float top = page_height - margin - (std::max(top_doc, window.first) - window.first);
            float bottom = page_height - margin - (std::min(bottom_doc, window.second) - window.first);
            if (bottom >= top)
            {
                continue;
            }
            HPDF_Rect rect;
            rect.left = margin + link.x;
            rect.right = margin + link.x + link.width;
            rect.top = top;
            rect.bottom = bottom;
            if (getenv("LITEPDF_DEBUG")) std::fprintf(stderr, "  annot uri=%s top=%.1f bottom=%.1f\n", link.uri.c_str(), rect.top, rect.bottom);
            if (link.external)
            {
                HPDF_Annotation annot = HPDF_Page_CreateURILinkAnnot(page, rect, link.uri.c_str());
                // The PDF spec defaults annotations to a 1pt border drawn
                // by the viewer; zero it so only our styling shows.
                if (annot)
                {
                    HPDF_LinkAnnot_SetBorderStyle(annot, 0, 0, 0);
                }
            }
            else
            {
                pending_internal.push_back({(size_t)page_count, rect, link.uri.substr(1)});
            }
        }
        page_handles.push_back(page);
        page_count++;
    }

    // Internal links: resolve #targets to destinations and wire them up.
    std::map<std::string, HPDF_Destination> destinations;
    for (const auto& target : container.targets)
    {
        if (getenv("LITEPDF_DEBUG")) std::fprintf(stderr, "target '%s' y=%.1f\n", target.name.c_str(), target.y);
        for (size_t i = 0; i < windows.size(); i++)
        {
            if (target.y >= windows[i].first && target.y < windows[i].second)
            {
                HPDF_Destination dst = HPDF_Page_CreateDestination(page_handles[i]);
                if (dst)
                {
                    // Keep the reader's zoom, jump to the target's height.
                    HPDF_Destination_SetFitH(dst, page_height - margin - (target.y - windows[i].first));
                    destinations[target.name] = dst;
                }
                break;
            }
        }
    }
    if (getenv("LITEPDF_DEBUG")) std::fprintf(stderr, "targets=%zu pending=%zu destinations=%zu\n", container.targets.size(), pending_internal.size(), destinations.size());
    for (const auto& pending : pending_internal)
    {
        auto destination = destinations.find(pending.target);
        if (destination == destinations.end())
        {
            continue;
        }
        HPDF_Annotation annot =
            HPDF_Page_CreateLinkAnnot(page_handles[pending.page_index], pending.rect, destination->second);
        if (annot)
        {
            HPDF_LinkAnnot_SetBorderStyle(annot, 0, 0, 0);
        }
    }

    g_last_op = "saving " + std::string(out_path);
    if (HPDF_SaveToFile(pdf, out_path) != HPDF_OK)
    {
        std::snprintf(errbuf, errbuf_len, "failed to write %s: %s", out_path,
                      describe_hpdf_error().c_str());
        HPDF_Free(pdf);
        return -1;
    }
    HPDF_Free(pdf);
    return page_count;
}
}
