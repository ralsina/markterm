// Shared C API between the MicroTeX math shim (litepdf_microtex.cpp)
// and the litepdf shim (litepdf.cpp). Both are C++, but the API is
// kept C-compatible so the Crystal binding could use it too.
#ifndef LITEPDF_MATH_API_H
#define LITEPDF_MATH_API_H

#ifdef __cplusplus
extern "C" {
#endif

// Non-zero when the MicroTeX bridge was compiled in (WITH_MICROTEX).
int litepdf_math_available(void);

// Parse a LaTeX expression and cache the render. Returns a formula
// id (>= 0) usable in math:<id> image URLs, or -1 when math support
// is unavailable or the expression failed to parse. Display formulas
// use TeX display style (stacked operator limits); inline ones use
// text style (side-set limits, more compact). Sizes come back in
// points: total width, total height, and the depth below the
// baseline. Identical expressions parse only once.
int litepdf_math_register(const char* latex, float text_size, float wrap_width, int display,
                          float* out_width, float* out_height, float* out_depth);

// Dimensions of a registered formula (points). Zero on success,
// -1 for an unknown id.
int litepdf_math_size(int id, float* out_width, float* out_height);

// Draw a registered formula on a libharu page. (x, top) is the
// top-left corner in page coordinates, width the box width in
// points; the formula is uniformly scaled to the width and its
// depth hangs below the box top accordingly.
void litepdf_math_draw(void* page, int id, float x, float top, float width);

#ifdef __cplusplus
}
#endif

#endif  // LITEPDF_MATH_API_H
