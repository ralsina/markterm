# Builds the litepdf static library: the C++ shim plus the vendored
# litehtml (including its bundled gumbo HTML parser). The result,
# build/liblitepdf.a, is linked into the markpdf Crystal binary.
#
# LaTeX math rendering, two engines:
# - MicroTeX (ext/microtex, a git submodule — init it first; MIT)
#   typesets math as vector graphics straight onto the PDF page via
#   the bridge in litepdf_microtex.cpp (stb_truetype for glyph
#   outlines, tinyxml2 for MicroTeX's XML resources). Its res/ tree
#   is embedded into the library (gen-math-res.sh) and extracted to a
#   temp dir at runtime when no installed copy is found. Disable with
#   `make WITH_MICROTEX=0`.
# - The vendored libtexprintf (ext/libtexprintf, a git submodule)
#   renders display math as UTF-8 text art for the terminal renderer
#   (markterm links build/libtexprintf.a directly) and as a markpdf
#   fallback when MicroTeX is disabled. It is GPL-3, so binaries
#   built with it are effectively GPL-3; opt out with
#   `make WITH_TEXMATH=0` (and WITH_TEXMATH=0 for shards build) to
#   fall back to a plain Unicode styling pass.

CXX ?= g++
AR ?= ar
CC ?= gcc

CXXFLAGS ?= -std=c++17 -O2 -fPIC -MMD -MP
CFLAGS ?= -O2 -fPIC -MMD -MP
INCLUDES = -I litehtml/include -I litehtml/include/litehtml -I litehtml/src -I litehtml/src/gumbo/src

WITH_TEXMATH ?= 1
WITH_MICROTEX ?= 1

LITEHTML_SRC := $(filter-out litehtml/src/main.cpp,$(wildcard litehtml/src/*.cpp))
# gumbo moved its sources and headers from src/gumbo/ (headers under
# include/) into src/gumbo/src/ when litehtml's PR #485 branch updated
# its vendored copy.
GUMBO_SRC := $(wildcard litehtml/src/gumbo/src/*.cpp) $(wildcard litehtml/src/gumbo/src/*.c)

SHIM_OBJ := build/litepdf.o
LITEHTML_OBJS := $(patsubst litehtml/src/%.cpp,build/litehtml/%.o,$(LITEHTML_SRC))
GUMBO_OBJS := $(patsubst litehtml/src/%.c,build/litehtml/%.o,$(filter %.c,$(GUMBO_SRC))) \
              $(patsubst litehtml/src/%.cpp,build/litehtml/%.o,$(filter %.cpp,$(GUMBO_SRC)))

TEXPRINTF_DIR := libtexprintf
# The library sources; main.c (utftex CLI), utf2unicode.c (standalone
# tool with its own main) and testfonts.c (font test tool) are excluded.
TEXPRINTF_SRC := $(filter-out $(TEXPRINTF_DIR)/src/main.c $(TEXPRINTF_DIR)/src/utf2unicode.c \
                             $(TEXPRINTF_DIR)/src/testfonts.c,\
                  $(wildcard $(TEXPRINTF_DIR)/src/*.c))
TEXPRINTF_OBJ := $(patsubst $(TEXPRINTF_DIR)/src/%.c,build/libtexprintf/%.o,$(TEXPRINTF_SRC))
MATH_OBJ := build/litepdf_math.o

MICROTEX_DIR := microtex
MICROTEX_SRC := $(wildcard $(MICROTEX_DIR)/src/*.cpp) \
                $(wildcard $(MICROTEX_DIR)/src/atom/*.cpp) \
                $(wildcard $(MICROTEX_DIR)/src/box/*.cpp) \
                $(wildcard $(MICROTEX_DIR)/src/core/*.cpp) \
                $(wildcard $(MICROTEX_DIR)/src/fonts/*.cpp) \
                $(wildcard $(MICROTEX_DIR)/src/utils/*.cpp) \
                $(wildcard $(MICROTEX_DIR)/src/res/*/*.cpp)
MICROTEX_OBJ := $(patsubst $(MICROTEX_DIR)/src/%.cpp,build/microtex/%.o,$(MICROTEX_SRC))
MICROTEX_INCLUDES = -I $(MICROTEX_DIR)/src -I tinyxml2 -I stb
MICROTEX_SHIM_OBJS := build/litepdf_microtex.o build/stb_impl.o build/tinyxml2.o \
                      build/math_res_data.o build/math_res_index.o

LIB := build/liblitepdf.a

# The bridge object always builds (stubs when WITH_MICROTEX=0), so the
# Crystal side can call litepdf_math_available unconditionally.
LIB_OBJS_BASE := build/litepdf_microtex.o

ifneq ($(WITH_TEXMATH),0)
  # override: WITH_TEXMATH is often passed on the command line, where a
  # plain += would be silently ignored. The libtexprintf includes are
  # scoped to the objects that need them: adding them globally would
  # shadow gumbo's own error.h.
  override CXXFLAGS += -DWITH_TEXMATH=1
  MATH_CFLAGS = -DWITH_TEXMATH=1 -I build/libtexprintf -I $(TEXPRINTF_DIR)/src
  LIB_OBJS_BASE += $(TEXPRINTF_OBJ) $(MATH_OBJ)
else
  MATH_CFLAGS :=
  LIB_OBJS_BASE += $(MATH_OBJ)
endif

ifneq ($(WITH_MICROTEX),0)
  override CXXFLAGS += -DWITH_MICROTEX=1
  MICROTEX_CXXFLAGS = -DWITH_MICROTEX=1 -DMATH_RES_EMBEDDED \
                      -DMICROTEX_RES_BUILD_DIR='"$(abspath $(MICROTEX_DIR)/res)"'
  LIB_OBJS := $(SHIM_OBJ) $(LITEHTML_OBJS) $(GUMBO_OBJS) $(MICROTEX_SHIM_OBJS) $(MICROTEX_OBJ) $(LIB_OBJS_BASE)
else
  MICROTEX_CXXFLAGS :=
  # Only the stub bridge object (already in LIB_OBJS_BASE) remains; no
  # engine, no embedded resources.
  LIB_OBJS := $(SHIM_OBJ) $(LITEHTML_OBJS) $(GUMBO_OBJS) $(LIB_OBJS_BASE)
endif

TEXPRINTF_LIB := build/libtexprintf.a

.PHONY: all clean test

all: $(LIB) $(TEXPRINTF_LIB)

$(LIB): $(LIB_OBJS)
	$(AR) rcs $@ $^

# Standalone static library for the terminal renderer (markterm), which
# links libtexprintf directly.
$(TEXPRINTF_LIB): $(TEXPRINTF_OBJ)
	$(AR) rcs $@ $^

build/litepdf.o: litepdf.cpp | build build/libhpdf.a
	$(CXX) $(CXXFLAGS) $(INCLUDES) -I build/include -c $< -o $@

build/litepdf_math.o: litepdf_math.c | build
	$(CC) $(CFLAGS) $(MATH_CFLAGS) -c $< -o $@

ifneq ($(WITH_MICROTEX),0)
MICROTEX_RES_PREREQ := build/math_res_index.h
else
MICROTEX_RES_PREREQ :=
endif

build/litepdf_microtex.o: litepdf_microtex.cpp litepdf_math_api.h | build build/libhpdf.a $(MICROTEX_RES_PREREQ)
	$(CXX) $(CXXFLAGS) $(INCLUDES) -I build/include -I build $(MICROTEX_INCLUDES) $(MICROTEX_CXXFLAGS) -c $< -o $@

build/stb_impl.o: stb_impl.cpp | build
	$(CXX) $(CXXFLAGS) -I stb -c $< -o $@

build/tinyxml2.o: tinyxml2/tinyxml2.cpp | build
	$(CXX) $(CXXFLAGS) -I tinyxml2 -c $< -o $@

build/microtex/%.o: $(MICROTEX_DIR)/src/%.cpp | build build/math_res_index.h
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) $(MICROTEX_INCLUDES) -c $< -o $@

build/litehtml/%.o: litehtml/src/%.cpp | build
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) $(INCLUDES) -I litehtml/src -c $< -o $@

build/litehtml/%.o: litehtml/src/%.c | build
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(INCLUDES) -I litehtml/src -c $< -o $@

# The libtexprintf build generates two headers (errorflags.h,
# errormessages.h) from error-marker comments in its sources; generate
# them into build/libtexprintf and add that to the include path.
build/libtexprintf/gen: $(wildcard $(TEXPRINTF_DIR)/src/gen_errorflags.sh) \
                        $(wildcard $(TEXPRINTF_DIR)/src/boxes.c) \
                        $(wildcard $(TEXPRINTF_DIR)/src/drawbox.c) \
                        $(wildcard $(TEXPRINTF_DIR)/src/lexer.c) \
                        $(wildcard $(TEXPRINTF_DIR)/src/parser.c)
	@mkdir -p $(dir $@)
	cd build/libtexprintf && $(SHELL) ../../$(TEXPRINTF_DIR)/src/gen_errorflags.sh ../../$(TEXPRINTF_DIR)/src/boxes.c ../../$(TEXPRINTF_DIR)/src/drawbox.c ../../$(TEXPRINTF_DIR)/src/lexer.c ../../$(TEXPRINTF_DIR)/src/parser.c
	@touch $@

build/libtexprintf/%.o: $(TEXPRINTF_DIR)/src/%.c | build build/libtexprintf/gen
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -I build/libtexprintf -I $(TEXPRINTF_DIR)/src -c $< -o $@

# Embedded MicroTeX resources: every file under microtex/res becomes an
# .incbin blob plus a generated index; extracted to a temp dir at
# runtime when no installed res directory is found.
RES_FILES := $(shell find $(MICROTEX_DIR)/res -type f 2>/dev/null)

build/math_res.manifest: gen-math-res.sh $(RES_FILES)
	./gen-math-res.sh

build/math_res_data.cpp build/math_res_index.cpp build/math_res_index.h: build/math_res.manifest
	./gen-math-res.sh

build/math_res_data.o: build/math_res_data.cpp | build
	$(CXX) $(CXXFLAGS) -c build/math_res_data.cpp -o $@

build/math_res_index.o: build/math_res_index.cpp | build
	$(CXX) $(CXXFLAGS) -I build -c build/math_res_index.cpp -o $@

build:
	mkdir -p build

# libharu: built from source (the CID font fixes in
# libharu-cid-fixes.patch are required for correct embedded-CID fonts;
# distro packages ship unpatched builds). The script is idempotent and
# re-applies the patch when it changes.
build/libhpdf.a: build-libharu.sh libharu-cid-fixes.patch | build
	./build-libharu.sh

# Standalone test driver: ./build/litepdf_test file.html [file.css] out.pdf
test: $(LIB) build/litepdf_test.o
	$(CXX) $(CXXFLAGS) $(INCLUDES) build/litepdf_test.o $(LIB) -Lbuild -lhpdf -lpng -lz -lm -lstdc++ -o build/litepdf_test

build/litepdf_test.o: litepdf_test.cpp | build
	$(CXX) $(CXXFLAGS) $(INCLUDES) -c $< -o $@

clean:
	rm -rf build

# Header dependency tracking
-include $(SHIM_OBJ:.o=.d) $(LITEHTML_OBJS:.o=.d) $(GUMBO_OBJS:.o=.d) $(MATH_OBJ:.o=.d) \
  $(MICROTEX_OBJ:.o=.d) $(MICROTEX_SHIM_OBJS:.o=.d)
