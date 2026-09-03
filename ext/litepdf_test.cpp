// Standalone driver to render an HTML file (plus optional CSS file) to
// PDF without going through the Crystal side. Used for iterating on the
// shim: ./build/litepdf_test file.html [file.css] out.pdf [base_dir]
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

extern "C" int litepdf_render(const char* html, const char* css, int page_size, float margin_pt,
                              const char* out_path, const char* base_dir, char* errbuf, int errbuf_len);

static std::string read_file(const char* path)
{
    std::FILE* file = std::fopen(path, "rb");
    if (!file)
    {
        std::fprintf(stderr, "cannot open %s\n", path);
        std::exit(1);
    }
    std::string contents;
    char buffer[65536];
    size_t read;
    while ((read = std::fread(buffer, 1, sizeof(buffer), file)) > 0)
    {
        contents.append(buffer, read);
    }
    std::fclose(file);
    return contents;
}

int main(int argc, char** argv)
{
    if (argc < 3)
    {
        std::fprintf(stderr, "usage: litepdf_test in.html [in.css] out.pdf [base_dir]\n");
        return 1;
    }
    std::string html = read_file(argv[1]);
    const char* css_arg = argc >= 4 && std::string(argv[2]).find(".css") != std::string::npos ? argv[2] : nullptr;
    const char* out = css_arg && argc >= 4 ? argv[3] : argv[2];
    std::string css = css_arg ? read_file(css_arg) : std::string();
    const char* base_dir = ".";
    for (int i = 2; i < argc && i <= 4; i++)
    {
        std::string argument = argv[i];
        if (argument[0] != '-')
        {
            base_dir = argv[i];
        }
    }
    char errbuf[512];
    int pages = litepdf_render(html.c_str(), css.c_str(), 0, 56.7f, out, base_dir, errbuf, sizeof(errbuf));
    if (pages < 0)
    {
        std::fprintf(stderr, "error: %s\n", errbuf);
        return 1;
    }
    std::printf("%s: %d pages\n", out, pages);
    return 0;
}
