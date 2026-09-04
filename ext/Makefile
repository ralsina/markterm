# Builds the litepdf static library: the C++ shim plus the vendored
# litehtml (including its bundled gumbo HTML parser). The result,
# build/liblitepdf.a, is linked into the markpdf Crystal binary.

CXX ?= g++
AR ?= ar

CXXFLAGS ?= -std=c++17 -O2 -fPIC -MMD -MP
INCLUDES = -I litehtml/include -I litehtml/include/litehtml -I litehtml/src -I litehtml/src/gumbo/include -I litehtml/src/gumbo/include/gumbo -I litehtml/src/gumbo

LITEHTML_SRC := $(filter-out litehtml/src/main.cpp,$(wildcard litehtml/src/*.cpp))
GUMBO_SRC := $(wildcard litehtml/src/gumbo/*.cpp) $(wildcard litehtml/src/gumbo/*.c)

SHIM_OBJ := build/litepdf.o
LITEHTML_OBJS := $(patsubst litehtml/src/%.cpp,build/litehtml/%.o,$(LITEHTML_SRC))
GUMBO_OBJS := $(patsubst litehtml/src/%.c,build/litehtml/%.o,$(filter %.c,$(GUMBO_SRC))) \
              $(patsubst litehtml/src/%.cpp,build/litehtml/%.o,$(filter %.cpp,$(GUMBO_SRC)))

LIB := build/liblitepdf.a

.PHONY: all clean test

all: $(LIB)

$(LIB): $(SHIM_OBJ) $(LITEHTML_OBJS) $(GUMBO_OBJS)
	$(AR) rcs $@ $^

build/litepdf.o: litepdf.cpp | build
	$(CXX) $(CXXFLAGS) $(INCLUDES) -c $< -o $@

build/litehtml/%.o: litehtml/src/%.cpp | build
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) $(INCLUDES) -I litehtml/src -c $< -o $@

build/litehtml/%.o: litehtml/src/%.c | build
	@mkdir -p $(dir $@)
	$(CC) $(CXXFLAGS) $(INCLUDES) -I litehtml/src -c $< -o $@

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
-include $(SHIM_OBJ:.o=.d) $(LITEHTML_OBJS:.o=.d) $(GUMBO_OBJS:.o=.d)
