// MicroTeX → libharu bridge: typesets LaTeX math as vector graphics
// directly on the PDF page (glyph outlines, rules, fills — no font
// embedding, no rasterization).
//
// Three pieces implement the MicroTeX platform contract
// (src/graphic/graphic.h):
// - Font_hpdf / TextLayout_hpdf: TTF loading and metrics via
//   stb_truetype. TeX layout metrics come from MicroTeX's own XML
//   resources; the platform font only supplies glyph outlines (drawn
//   as filled paths) and, for \text{}, advance metrics.
// - Graphics2D_hpdf: the MicroTeX 2D context over an HPDF_Page.
//   MicroTeX uses a y-down coordinate space; the base matrix
//   translates to the formula box's top-left corner and flips y, so
//   PDF y-up never leaks into the drawing code.
//
// Integration with the litepdf pipeline happens through "math:<id>"
// pseudo-image URLs: the Crystal side registers each formula
// (litepdf_math_register) and emits an <img> whose src references the
// returned id; litepdf.cpp answers get_image_size from the cached
// render and draw_image draws it vectorially (litepdf_math_draw).
//
// Resources: MicroTeX needs its res/ tree (fonts + XML metrics) at
// runtime. It is looked up in $MARKPDF_MATH_RES, next to the
// installed binary, at build-time paths, in /usr/{,local/}share, or
// — failing all that — extracted from the copy embedded into this
// library (see gen-math-res.sh) into a temp directory.
//
// MicroTeX is MIT-licensed; the res/ fonts carry their own licenses
// (Knuth/OFL, see microtex/res/fonts/licences).

#include "litepdf_math_api.h"

#ifdef WITH_MICROTEX

#include "hpdf.h"

#include <sys/stat.h>
#include <sys/types.h>

#include <unistd.h>

#include <algorithm>
#include <cctype>
#include <climits>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <vector>

#include "graphic/graphic.h"
#include "core/formula.h"
#include "latex.h"
#include "render.h"

#include "stb_truetype.h"

#ifdef MATH_RES_EMBEDDED
#include "math_res_index.h"
#endif

namespace {

// -- UTF-8 → wstring (MicroTeX parses wchar_t strings) --------------

std::wstring utf8_to_wstring(const char* s)
{
    std::wstring out;
    const unsigned char* p = (const unsigned char*)s;
    while (*p)
    {
        unsigned int cp;
        int extra;
        if (*p < 0x80)
        {
            cp = *p++;
            extra = 0;
        }
        else if ((*p & 0xE0) == 0xC0)
        {
            cp = *p++ & 0x1F;
            extra = 1;
        }
        else if ((*p & 0xF0) == 0xE0)
        {
            cp = *p++ & 0x0F;
            extra = 2;
        }
        else if ((*p & 0xF8) == 0xF0)
        {
            cp = *p++ & 0x07;
            extra = 3;
        }
        else
        {
            p++;  // stray byte: skip
            continue;
        }
        bool valid = true;
        for (int i = 0; i < extra; i++)
        {
            if ((p[i] & 0xC0) != 0x80)
            {
                valid = false;
                break;
            }
            cp = (cp << 6) | (p[i] & 0x3F);
        }
        if (!valid)
        {
            continue;
        }
        p += extra;
        out.push_back((wchar_t)cp);
    }
    return out;
}

// -- TTF loading ------------------------------------------------------

// One loaded TTF file shared by every Font_hpdf pointing at it.
struct LoadedFont
{
    std::vector<unsigned char> data;
    stbtt_fontinfo info{};
    float em_scale = 0;  // font units → coordinates where the em is 1
    int ascent = 0, descent = 0;  // font units, y-up (descent ≤ 0)

    bool load(const std::string& path)
    {
        FILE* f = fopen(path.c_str(), "rb");
        if (!f) return false;
        fseek(f, 0, SEEK_END);
        long size = ftell(f);
        fseek(f, 0, SEEK_SET);
        if (size <= 0)
        {
            fclose(f);
            return false;
        }
        data.resize((size_t)size);
        size_t read = fread(data.data(), 1, (size_t)size, f);
        fclose(f);
        if (read != (size_t)size) return false;
        if (!stbtt_InitFont(&info, data.data(), 0)) return false;
        em_scale = stbtt_ScaleForMappingEmToPixels(&info, 1.0f);
        stbtt_GetFontVMetrics(&info, &ascent, &descent, nullptr);
        return em_scale > 0;
    }
};

std::mutex g_font_mutex;
std::map<std::string, std::shared_ptr<LoadedFont>> g_font_cache;

std::shared_ptr<LoadedFont> load_ttf(const std::string& path)
{
    std::lock_guard<std::mutex> lock(g_font_mutex);
    auto hit = g_font_cache.find(path);
    if (hit != g_font_cache.end()) return hit->second;
    auto font = std::make_shared<LoadedFont>();
    if (!font->load(path))
    {
        g_font_cache[path] = nullptr;  // negative cache: no retry storm
        return nullptr;
    }
    g_font_cache[path] = font;
    return font;
}

// Family names used by MicroTeX's TextRenderingBox ("Serif", plus
// whatever \text* style-switching requests) resolved to res fonts.
std::string family_font_path(const std::string& res_root, const std::string& name, int style)
{
    std::string lower = name;
    for (auto& c : lower) c = (char)std::tolower((unsigned char)c);
    const bool sans = lower.find("sans") != std::string::npos;
    const bool mono = lower.find("mono") != std::string::npos || lower == "tt" || lower == "typewriter";
    const bool bold = (style & tex::BOLD) != 0;
    const bool italic = (style & tex::ITALIC) != 0;
    const char* file = "cmr10.ttf";
    if (mono)
    {
        file = "tt10.ttf";
    }
    else if (sans)
    {
        file = bold && italic ? "sbi10.ttf" : bold ? "sb10.ttf" : italic ? "si10.ttf" : "ss10.ttf";
    }
    else
    {
        file = bold && italic ? "bi10.ttf" : bold ? "bx10.ttf" : italic ? "i10.ttf" : "cmr10.ttf";
    }
    return res_root + "/fonts/latin/" + file;
}

// -- Font --------------------------------------------------------------

class Font_hpdf : public tex::Font
{
public:
    // Resolved TTF path; for family fonts also the family name so
    // deriveFont can restyle by picking a different file.
    std::string file;
    std::string family;
    int style;
    float size;
    std::shared_ptr<LoadedFont> loaded;

    Font_hpdf(std::string file_path, std::string family_name, int style_value, float size_value)
        : file(std::move(file_path)), family(std::move(family_name)), style(style_value), size(size_value)
    {
        loaded = load_ttf(file);
    }

    float getSize() const override { return size; }

    tex::sptr<Font> deriveFont(int new_style) const override
    {
        if (!family.empty())
        {
            return tex::sptrOf<Font_hpdf>(family_font_path(tex::LaTeX::getResRootPath(), family, new_style),
                                     family, new_style, size);
        }
        return tex::sptrOf<Font_hpdf>(file, "", new_style, size);
    }

    bool operator==(const Font& other) const override
    {
        auto* f = dynamic_cast<const Font_hpdf*>(&other);
        return f && f->file == file && f->style == style && f->size == size;
    }

    bool operator!=(const Font& other) const override { return !(*this == other); }
};

}  // namespace

// Font::create: from a file path (TeX glyph fonts come through here;
// FontInfo::getFont passes res_root/fonts/.../<name>.ttf).
tex::Font* tex::Font::create(const std::string& file, float size)
{
    return new Font_hpdf(file, "", tex::PLAIN, size);
}

// Font::_create: from a family name (\text{} boxes).
tex::sptr<tex::Font> tex::Font::_create(const std::string& name, int style, float size)
{
    return tex::sptrOf<Font_hpdf>(family_font_path(tex::LaTeX::getResRootPath(), name, style), name, style, size);
}

namespace {

// -- TextLayout ----------------------------------------------------------

class TextLayout_hpdf : public tex::TextLayout
{
public:
    std::wstring text;
    tex::sptr<Font_hpdf> font;
    float ascent = 0, descent = 0, advance = 0;  // in font-size units

    TextLayout_hpdf(const std::wstring& src, const tex::sptr<Font_hpdf>& f) : text(src), font(f)
    {
        if (!font || !font->loaded) return;
        const float scale = font->size * font->loaded->em_scale;
        ascent = font->loaded->ascent * scale;
        descent = -font->loaded->descent * scale;
        for (wchar_t c : src)
        {
            int advance_width = 0;
            stbtt_GetCodepointHMetrics(&font->loaded->info, (int)c, &advance_width, nullptr);
            advance += advance_width * scale;
        }
    }

    void getBounds(tex::Rect& bounds) override
    {
        bounds.x = 0;
        bounds.y = -ascent;
        bounds.w = advance;
        bounds.h = ascent + descent;
    }

    void draw(tex::Graphics2D& g2, float x, float y) override
    {
        // TextRenderingBox does not set the font on the context
        // before drawing the layout: do it here.
        g2.setFont(font.get());
        g2.drawText(text, x, y);
    }
};

}  // namespace

tex::sptr<tex::TextLayout> tex::TextLayout::create(const std::wstring& src, const tex::sptr<Font>& font)
{
    return tex::sptrOf<TextLayout_hpdf>(src, std::static_pointer_cast<Font_hpdf>(font));
}

namespace {

// -- Graphics2D over an HPDF_Page ----------------------------------------

// Row-vector affine 3x2: p' = (x·a + y·c + e, x·b + y·d + f).
struct Mat
{
    float a, b, c, d, e, f;

    static Mat identity() { return {1, 0, 0, 1, 0, 0}; }

    Mat operator*(const Mat& m) const
    {
        return {
            a * m.a + b * m.c, a * m.b + b * m.d,
            c * m.a + d * m.c, c * m.b + d * m.d,
            e * m.a + f * m.c + m.e, e * m.b + f * m.d + m.f};
    }

    void transform(float x, float y, float* ox, float* oy) const
    {
        *ox = x * a + y * c + e;
        *oy = x * b + y * d + f;
    }
};

Mat translation(float dx, float dy) { return {1, 0, 0, 1, dx, dy}; }
Mat scaling(float sx, float sy) { return {sx, 0, 0, sy, 0, 0}; }
Mat rotation(float angle)
{
    const float cs = std::cos(angle), sn = std::sin(angle);
    return {cs, sn, -sn, cs, 0, 0};
}

class Graphics2D_hpdf : public tex::Graphics2D
{
public:
    Graphics2D_hpdf(HPDF_Page page, float x, float top, float scale) : _page(page)
    {
        // MicroTeX y-down → PDF y-up, formula origin at (x, top).
        _base = scaling(scale, -scale) * translation(x, top);
        _m = _base;
    }

    void setColor(tex::color c) override { _color = c; }
    tex::color getColor() const override { return _color; }

    void setStroke(const tex::Stroke& s) override { _stroke = s; }
    const tex::Stroke& getStroke() const override { return _stroke; }
    void setStrokeWidth(float w) override { _stroke.lineWidth = w; }

    const tex::Font* getFont() const override { return _font; }
    void setFont(const tex::Font* font) override { _font = dynamic_cast<const Font_hpdf*>(font); }

    void translate(float dx, float dy) override { _m = translation(dx, dy) * _m; }
    void scale(float sx, float sy) override
    {
        _m = scaling(sx, sy) * _m;
        _sx *= sx;
        _sy *= sy;
    }
    void rotate(float angle) override { _m = rotation(angle) * _m; }
    void rotate(float angle, float px, float py) override
    {
        _m = translation(px, py) * rotation(angle) * translation(-px, -py) * _m;
    }
    void reset() override
    {
        _m = _base;
        _sx = _sy = 1;
    }
    float sx() const override { return _sx; }
    float sy() const override { return _sy; }

    void drawChar(wchar_t c, float x, float y) override
    {
        if (!_font || !_font->loaded) return;
        if (tex::isTransparent(_color)) return;
        stbtt_vertex* vertices = nullptr;
        int count = stbtt_GetCodepointShape(&_font->loaded->info, (int)c, &vertices);
        if (count <= 0 || !vertices)
        {
            if (vertices) stbtt_FreeShape(&_font->loaded->info, vertices);
            return;
        }
        // Font units, y-up, origin at the baseline; MicroTeX space is
        // y-down with the baseline at y.
        const float glyph_scale = _font->size * _font->loaded->em_scale;
        set_fill_color();
        bool drew = false;
        float cur_x = x, cur_y = y;
        for (int i = 0; i < count; i++)
        {
            const stbtt_vertex& v = vertices[i];
            const float ux = x + v.x * glyph_scale;
            const float uy = y - v.y * glyph_scale;
            switch (v.type)
            {
                case STBTT_vmove:
                    move_to(ux, uy);
                    drew = true;
                    break;
                case STBTT_vline:
                    line_to(ux, uy);
                    break;
                case STBTT_vcurve:
                {
                    // elevate the quadratic to a cubic for PDF
                    const float qx = x + v.cx * glyph_scale;
                    const float qy = y - v.cy * glyph_scale;
                    const float c1x = cur_x + (2.0f / 3.0f) * (qx - cur_x);
                    const float c1y = cur_y + (2.0f / 3.0f) * (qy - cur_y);
                    const float c2x = ux + (2.0f / 3.0f) * (qx - ux);
                    const float c2y = uy + (2.0f / 3.0f) * (qy - uy);
                    bezier_to(c1x, c1y, c2x, c2y, ux, uy);
                    break;
                }
                case STBTT_vcubic:
                    bezier_to(x + v.cx * glyph_scale, y - v.cy * glyph_scale,
                              x + v.cx1 * glyph_scale, y - v.cy1 * glyph_scale, ux, uy);
                    break;
                default:
                    break;
            }
            cur_x = ux;
            cur_y = uy;
        }
        stbtt_FreeShape(&_font->loaded->info, vertices);
        if (!drew) return;
        HPDF_Page_ClosePath(_page);
        HPDF_Page_Fill(_page);  // TrueType outlines use nonzero winding
    }

    void drawText(const std::wstring& t, float x, float y) override
    {
        if (!_font || !_font->loaded) return;
        const float scale = _font->size * _font->loaded->em_scale;
        float cursor = x;
        for (wchar_t c : t)
        {
            drawChar(c, cursor, y);
            int advance_width = 0;
            stbtt_GetCodepointHMetrics(&_font->loaded->info, (int)c, &advance_width, nullptr);
            cursor += advance_width * scale;
        }
    }

    void drawLine(float x1, float y1, float x2, float y2) override
    {
        float px1, py1, px2, py2;
        _m.transform(x1, y1, &px1, &py1);
        _m.transform(x2, y2, &px2, &py2);
        begin_stroke();
        HPDF_Page_MoveTo(_page, px1, py1);
        HPDF_Page_LineTo(_page, px2, py2);
        HPDF_Page_Stroke(_page);
    }

    void drawRect(float x, float y, float w, float h) override
    {
        rect_path(x, y, w, h);
        begin_stroke();
        HPDF_Page_Stroke(_page);
    }

    void fillRect(float x, float y, float w, float h) override
    {
        if (tex::isTransparent(_color)) return;
        rect_path(x, y, w, h);
        set_fill_color();
        HPDF_Page_Fill(_page);
    }

    void drawRoundRect(float x, float y, float w, float h, float rx, float ry) override
    {
        round_rect_path(x, y, w, h, rx, ry);
        begin_stroke();
        HPDF_Page_Stroke(_page);
    }

    void fillRoundRect(float x, float y, float w, float h, float rx, float ry) override
    {
        if (tex::isTransparent(_color)) return;
        round_rect_path(x, y, w, h, rx, ry);
        set_fill_color();
        HPDF_Page_Fill(_page);
    }

private:
    HPDF_Page _page;
    Mat _base, _m;
    float _sx = 1, _sy = 1;
    tex::color _color = tex::black;
    tex::Stroke _stroke;
    const Font_hpdf* _font = nullptr;

    void set_fill_color()
    {
        HPDF_Page_SetRGBFill(_page,
                             (HPDF_REAL)(tex::color_r(_color) / 255.0f),
                             (HPDF_REAL)(tex::color_g(_color) / 255.0f),
                             (HPDF_REAL)(tex::color_b(_color) / 255.0f));
    }

    void set_stroke_color()
    {
        HPDF_Page_SetRGBStroke(_page,
                               (HPDF_REAL)(tex::color_r(_color) / 255.0f),
                               (HPDF_REAL)(tex::color_g(_color) / 255.0f),
                               (HPDF_REAL)(tex::color_b(_color) / 255.0f));
    }

    // Stroke attributes must be re-issued before every stroked shape:
    // other drawing (text, fills) resets them on the shared page.
    void begin_stroke()
    {
        set_stroke_color();
        HPDF_Page_SetLineWidth(_page, (HPDF_REAL)std::max(0.05f, _stroke.lineWidth * std::abs(_sy)));
        HPDF_LineCap cap = HPDF_BUTT_END;
        switch (_stroke.cap)
        {
            case tex::CAP_ROUND: cap = HPDF_ROUND_END; break;
            case tex::CAP_SQUARE: cap = HPDF_PROJECTING_SQUARE_END; break;
            default: break;
        }
        HPDF_Page_SetLineCap(_page, cap);
        HPDF_LineJoin join = HPDF_MITER_JOIN;
        switch (_stroke.join)
        {
            case tex::JOIN_BEVEL: join = HPDF_BEVEL_JOIN; break;
            case tex::JOIN_ROUND: join = HPDF_ROUND_JOIN; break;
            default: break;
        }
        HPDF_Page_SetLineJoin(_page, join);
    }

    void move_to(float x, float y)
    {
        float px, py;
        _m.transform(x, y, &px, &py);
        HPDF_Page_MoveTo(_page, px, py);
    }

    void line_to(float x, float y)
    {
        float px, py;
        _m.transform(x, y, &px, &py);
        HPDF_Page_LineTo(_page, px, py);
    }

    void bezier_to(float c1x, float c1y, float c2x, float c2y, float x, float y)
    {
        float pc1x, pc1y, pc2x, pc2y, px, py;
        _m.transform(c1x, c1y, &pc1x, &pc1y);
        _m.transform(c2x, c2y, &pc2x, &pc2y);
        _m.transform(x, y, &px, &py);
        HPDF_Page_CurveTo(_page, pc1x, pc1y, pc2x, pc2y, px, py);
    }

    void rect_path(float x, float y, float w, float h)
    {
        move_to(x, y);
        line_to(x + w, y);
        line_to(x + w, y + h);
        line_to(x, y + h);
        HPDF_Page_ClosePath(_page);
    }

    void round_rect_path(float x, float y, float w, float h, float rx, float ry)
    {
        const float r = std::max(std::max(rx, ry), 0.0f);
        const float k = 0.55228475f * r;  // bezier circle approximation
        move_to(x + r, y);
        line_to(x + w - r, y);
        bezier_to(x + w - r + k, y, x + w, y + r - k, x + w, y + r);
        line_to(x + w, y + h - r);
        bezier_to(x + w, y + h - r + k, x + w - r + k, y + h, x + w - r, y + h);
        line_to(x + r, y + h);
        bezier_to(x + r - k, y + h, x, y + h - r + k, x, y + h - r);
        line_to(x, y + r);
        bezier_to(x, y + r - k, x + r - k, y, x + r, y);
        HPDF_Page_ClosePath(_page);
    }
};

// -- resource discovery ----------------------------------------------------

std::string res_with_marker(const std::string& dir)
{
    if (dir.empty()) return "";
    std::string marker = dir + "/.clatexmath-res_root";
    struct stat st{};
    if (stat(marker.c_str(), &st) == 0 && S_ISREG(st.st_mode)) return dir;
    return "";
}

std::string executable_path()
{
    char buffer[PATH_MAX];
    ssize_t n = readlink("/proc/self/exe", buffer, sizeof(buffer) - 1);
    if (n <= 0) return "";
    buffer[n] = '\0';
    return buffer;
}

void mkdir_p(const std::string& dir)
{
    std::string current;
    std::stringstream parts(dir);
    std::string part;
    while (std::getline(parts, part, '/'))
    {
        if (part.empty()) continue;
        if (current.empty() && dir[0] == '/') current = "/";
        if (!current.empty() && current.back() != '/') current += "/";
        current += part;
        mkdir(current.c_str(), 0755);
    }
}

#ifdef MATH_RES_EMBEDDED
// Extract the embedded resource tree to a fresh temp directory.
std::string extract_embedded_res()
{
    const char* tmp = getenv("TMPDIR");
    if (!tmp || !*tmp) tmp = "/tmp";
    std::string pattern = std::string(tmp) + "/markpdf-mathres-XXXXXX";
    std::vector<char> dir(pattern.begin(), pattern.end());
    dir.push_back('\0');
    if (!mkdtemp(dir.data())) return "";
    std::string root(dir.data());
    for (unsigned int i = 0; i < math_res_files_count; i++)
    {
        const MathResFile& file = math_res_files[i];
        std::string target = root + "/" + file.path;
        std::string parent = target.substr(0, target.rfind('/'));
        mkdir_p(parent);
        FILE* out = fopen(target.c_str(), "wb");
        if (!out) continue;
        fwrite(file.data, 1, file.size, out);
        fclose(out);
    }
    return root;
}
#endif

std::string find_res_dir()
{
    // Explicit override first.
    if (const char* env = getenv("MARKPDF_MATH_RES"))
    {
        std::string found = res_with_marker(env);
        if (!found.empty()) return found;
    }
    // Installed layout: <exe>/../share/markterm/math-res.
    std::string exe = executable_path();
    if (!exe.empty())
    {
        size_t slash = exe.rfind('/');
        if (slash != std::string::npos)
        {
            std::string found = res_with_marker(exe.substr(0, slash) + "/../share/markterm/math-res");
            if (!found.empty()) return found;
        }
    }
#ifdef MICROTEX_RES_BUILD_DIR
    {
        std::string found = res_with_marker(MICROTEX_RES_BUILD_DIR);
        if (!found.empty()) return found;
    }
#endif
    const char* shared[] = {"/usr/share/markterm/math-res", "/usr/local/share/markterm/math-res",
                            "/usr/share/clatexmath", "/usr/local/share/clatexmath"};
    for (const char* dir : shared)
    {
        std::string found = res_with_marker(dir);
        if (!found.empty()) return found;
    }
#ifdef MATH_RES_EMBEDDED
    return extract_embedded_res();
#else
    return "";
#endif
}

// -- formula registry ----------------------------------------------------

std::mutex g_registry_mutex;
std::vector<tex::TeXRender*> g_renders;
std::vector<std::string> g_sources;  // LaTeX source per id, for ActualText
std::map<std::string, int> g_render_ids;
const size_t kMaxRenders = 4096;

std::once_flag g_math_init_once;
bool g_math_ready = false;

void math_init_once()
{
    std::string dir = find_res_dir();
    if (dir.empty())
    {
        std::fprintf(stderr, "markpdf: math resources not found, math rendering disabled\n");
        return;
    }
    try
    {
        tex::LaTeX::init(dir);
        g_math_ready = true;
    }
    catch (const std::exception& e)
    {
        std::fprintf(stderr, "markpdf: MicroTeX init failed: %s\n", e.what());
    }
}

bool ensure_math_ready()
{
    std::call_once(g_math_init_once, math_init_once);
    return g_math_ready;
}

}  // namespace

extern "C" int litepdf_math_available(void)
{
    return ensure_math_ready() ? 1 : 0;
}

extern "C" int litepdf_math_register(const char* latex, float text_size, float wrap_width, int display,
                                     float* out_width, float* out_height, float* out_depth)
{
    if (!latex || !*latex || !ensure_math_ready()) return -1;
    if (text_size <= 0) text_size = 12;
    if (wrap_width <= 0) wrap_width = 468;

    std::ostringstream key_stream;
    key_stream << text_size << '|' << wrap_width << '|' << (display ? 'D' : 'T') << '|' << latex;
    const std::string key = key_stream.str();

    std::lock_guard<std::mutex> lock(g_registry_mutex);
    auto hit = g_render_ids.find(key);
    if (hit != g_render_ids.end())
    {
        tex::TeXRender* render = g_renders[hit->second];
        if (render)
        {
            *out_width = (float)render->getWidth();
            *out_height = (float)render->getHeight();
            *out_depth = (float)render->getDepth();
            return hit->second;
        }
    }

    tex::TeXRender* render = nullptr;
    try
    {
        tex::Formula formula;
        formula.setLaTeX(utf8_to_wstring(latex));
        tex::TeXRenderBuilder builder;
        builder.setStyle(display ? tex::TexStyle::display : tex::TexStyle::text)
            .setTextSize(text_size)
            .setWidth(tex::UnitType::pixel, (int)wrap_width, tex::Alignment::left)
            .setIsMaxWidth(true)
            .setForeground(tex::black);
        render = builder.build(formula);
    }
    catch (const std::exception&)
    {
        return -1;
    }
    if (!render || render->getWidth() <= 0)
    {
        delete render;
        return -1;
    }

    if (g_renders.size() >= kMaxRenders)
    {
        // Bound memory in long-lived processes (the web playground):
        // drop everything and reparse on demand.
        for (tex::TeXRender* old : g_renders) delete old;
        g_renders.clear();
        g_sources.clear();
        g_render_ids.clear();
    }

    const int id = (int)g_renders.size();
    g_renders.push_back(render);
    g_sources.push_back(latex);
    g_render_ids[key] = id;
    *out_width = (float)render->getWidth();
    *out_height = (float)render->getHeight();
    *out_depth = (float)render->getDepth();
    return id;
}

extern "C" int litepdf_math_size(int id, float* out_width, float* out_height)
{
    std::lock_guard<std::mutex> lock(g_registry_mutex);
    if (id < 0 || (size_t)id >= g_renders.size() || !g_renders[id]) return -1;
    *out_width = (float)g_renders[id]->getWidth();
    *out_height = (float)g_renders[id]->getHeight();
    return 0;
}

extern "C" void litepdf_math_draw(void* page_ptr, void* anchor_font, int id, float x, float top, float width)
{
    tex::TeXRender* render = nullptr;
    std::string source;
    {
        std::lock_guard<std::mutex> lock(g_registry_mutex);
        if (id < 0 || (size_t)id >= g_renders.size() || !g_renders[id]) return;
        render = g_renders[id];
        if ((size_t)id < g_sources.size()) source = g_sources[id];
    }
    HPDF_Page page = (HPDF_Page)page_ptr;
    if (!page || width <= 0) return;
    const float scale = width / (float)render->getWidth();
    if (getenv("LITEPDF_DEBUG"))
        std::fprintf(stderr, "math draw id=%d x=%.1f top=%.1f w=%.1f scale=%.4f\n", id, x, top, width, scale);
    // The formula is ink, not text: mark the span with the LaTeX
    // source as its ActualText so copying, searching and screen
    // readers see the source instead of nothing.
    HPDF_Page_BeginActualText(page, source.c_str());
    if (anchor_font)
    {
        // Poppler only substitutes ActualText on spans containing at
        // least one text-showing operation (it needs the glyph extents
        // to place the replacement): draw an invisible anchor glyph at
        // the formula baseline. Tr reverts to fill explicitly — gstate
        // restore semantics differ across producers.
        const float baseline = top + ((float)render->getHeight() - (float)render->getDepth()) * scale;
        HPDF_Page_SetFontAndSize(page, (HPDF_Font)anchor_font, 1);
        HPDF_Page_BeginText(page);
        HPDF_Page_SetTextRenderingMode(page, HPDF_INVISIBLE);
        HPDF_Page_TextOut(page, x, baseline, "x");
        HPDF_Page_SetTextRenderingMode(page, HPDF_FILL);
        HPDF_Page_EndText(page);
    }
    Graphics2D_hpdf g2(page, x, top, scale);
    render->draw(g2, 0, 0);
    HPDF_Page_EndActualText(page);
}

#else  // !WITH_MICROTEX

extern "C" int litepdf_math_available(void)
{
    return 0;
}

extern "C" int litepdf_math_register(const char*, float, float, int, float*, float*, float*)
{
    return -1;
}

extern "C" int litepdf_math_size(int, float*, float*)
{
    return -1;
}

extern "C" void litepdf_math_draw(void*, void*, int, float, float, float)
{
}

#endif  // WITH_MICROTEX
