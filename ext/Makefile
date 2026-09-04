# Builds the litepdf static library: the C++ shim plus the vendored
# litehtml (including its bundled gumbo HTML parser). The result,
# build/liblitepdf.a, is linked into the markpdf Crystal binary.
#
# LaTeX math rendering: the vendored libtexprintf (ext/libtexprintf,
# a git submodule — init it first) renders display math as UTF-8 text
# art. It is GPL-3, so binaries built this way are effectively GPL-3;
# opt out with `make WITH_TEXMATH=0` (and WITH_TEXMATH=0 for shards
# build) to fall back to a plain Unicode styling pass.

CXX ?= g++
AR ?= ar
CC ?= gcc

CXXFLAGS ?= -std=c++17 -O2 -fPIC -MMD -MP
CFLAGS ?= -O2 -fPIC -MMD -MP
INCLUDES = -I litehtml/include -I litehtml/include/litehtml -I litehtml/src -I litehtml/src/gumbo/include -I litehtml/src/gumbo/include/gumbo -I litehtml/src/gumbo

WITH_TEXMATH ?= 1

LITEHTML_SRC := $(filter-out litehtml/src/main.cpp,$(wildcard litehtml/src/*.cpp))
GUMBO_SRC := $(wildcard litehtml/src/gumbo/*.cpp) $(wildcard litehtml/src/gumbo/*.c)

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

LIB := build/liblitepdf.a

ifneq ($(WITH_TEXMATH),0)
  # override: WITH_TEXMATH is often passed on the command line, where a
  # plain += would be silently ignored. The libtexprintf includes are
  # scoped to the objects that need them: adding them globally would
  # shadow gumbo's own error.h.
  override CXXFLAGS += -DWITH_TEXMATH=1
  MATH_CFLAGS = -DWITH_TEXMATH=1 -I build/libtexprintf -I $(TEXPRINTF_DIR)/src
  LIB_OBJS := $(SHIM_OBJ) $(LITEHTML_OBJS) $(GUMBO_OBJS) $(TEXPRINTF_OBJ) $(MATH_OBJ)
else
  MATH_CFLAGS :=
  LIB_OBJS := $(SHIM_OBJ) $(LITEHTML_OBJS) $(GUMBO_OBJS) $(MATH_OBJ)
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

build/litepdf.o: litepdf.cpp | build
	$(CXX) $(CXXFLAGS) $(INCLUDES) -I build/include -c $< -o $@

build/litepdf_math.o: litepdf_math.c | build
	$(CC) $(CFLAGS) $(MATH_CFLAGS) -c $< -o $@

build/litehtml/%.o: litehtml/src/%.cpp | build
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) $(INCLUDES) -I litehtml/src -c $< -o $@

build/litehtml/%.o: litehtml/src/%.c | build
	@mkdir -p $(dir $@)
	$(CC) $(CXXFLAGS) $(INCLUDES) -I litehtml/src -c $< -o $@

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
	$(CC) $(CXXFLAGS) -I build/libtexprintf -I $(TEXPRINTF_DIR)/src -c $< -o $@

build:
	mkdir -p build

# Standalone test driver: ./build/litepdf_test file.html [file.css] out.pdf
test: $(LIB) build/litepdf_test.o
	$(CXX) $(CXXFLAGS) $(INCLUDES) build/litepdf_test.o $(LIB) -L/usr/lib -lhpdf -o build/litepdf_test

build/litepdf_test.o: litepdf_test.cpp | build
	$(CXX) $(CXXFLAGS) $(INCLUDES) -c $< -o $@

clean:
	rm -rf build

# Header dependency tracking
-include $(SHIM_OBJ:.o=.d) $(LITEHTML_OBJS:.o=.d) $(GUMBO_OBJS:.o=.d) $(MATH_OBJ:.o=.d)
