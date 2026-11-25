// The JSON benchmark of simdjson and yyjson: bench_c LIB MODE FILE.json
// LIB is simdjson-dom, simdjson-ondemand, or yyjson. MODE is validate,
// parse, query, read3, or walk. Prints the best time of one run, in
// seconds, or "skip". The paths are the same as in paths.json.
// SPDX-License-Identifier: BSD-2-Clause
#include "simdjson.h"
#include "yyjson.h"
#include <chrono>
#include <cstdio>
#include <cstring>
#include <string>
#include <functional>

using namespace simdjson;
static size_t sink;

struct Path { const char *k[8]; int n; };
// The paths of paths.json. A key that is a decimal number is an index.
static Path query_of(const std::string &f) {
    if (f == "twitter") return {{"statuses", "50", "user", "screen_name"}, 4};
    if (f == "canada") return {{"features", "0", "geometry", "coordinates", "400", "0", "1"}, 7};
    return {{"performances", "200", "venueCode"}, 3};
}
static void reads_of(const std::string &f, Path out[3]) {
    if (f == "twitter") { out[0] = {{"search_metadata", "count"}, 2}; out[1] = {{"statuses", "0", "id"}, 3}; out[2] = {{"statuses", "99", "text"}, 3}; }
    else if (f == "canada") { out[0] = {{"type"}, 1}; out[1] = {{"features", "0", "type"}, 2 + 0 + 1}; out[2] = {{"features", "0", "properties", "name"}, 4}; }
    else { out[0] = {{"areaNames", "205705993"}, 2}; out[1] = {{"performances", "0", "id"}, 3}; out[2] = {{"venueNames", "PLEYEL_PLEYEL"}, 2}; }
}
static bool is_index(const char *k) { return *k >= '0' && *k <= '9' && strchr(k, ' ') == nullptr && strspn(k, "0123456789") == strlen(k) && strlen(k) < 6; }

static size_t walk_dom(dom::element e) {
    size_t n = 1;
    if (e.is_array()) for (auto x : dom::array(e)) n += walk_dom(x);
    else if (e.is_object()) for (auto kv : dom::object(e)) n += walk_dom(kv.value);
    return n;
}
static size_t walk_od(ondemand::value v) {
    size_t n = 1;
    switch (v.type()) {
    case ondemand::json_type::array: for (auto x : v.get_array()) n += walk_od(x.value()); break;
    case ondemand::json_type::object: for (auto f : v.get_object()) n += walk_od(f.value()); break;
    case ondemand::json_type::number: sink += (size_t)v.get_double(); break;
    case ondemand::json_type::string: sink += v.get_string().value().size(); break;
    case ondemand::json_type::boolean: sink += v.get_bool().value(); break;
    default: sink += v.is_null().value(); break;
    }
    return n;
}
static size_t walk_yy(yyjson_val *v) {
    size_t n = 1;
    if (yyjson_is_arr(v)) { size_t i, m; yyjson_val *x; yyjson_arr_foreach(v, i, m, x) n += walk_yy(x); }
    else if (yyjson_is_obj(v)) { size_t i, m; yyjson_val *k, *x; yyjson_obj_foreach(v, i, m, k, x) n += walk_yy(x); }
    return n;
}
static dom::element get_dom(dom::element e, const Path &p) {
    for (int i = 0; i < p.n; i++) e = is_index(p.k[i]) ? e.at(atoi(p.k[i])).value() : e[p.k[i]].value();
    return e;
}
static std::string pointer(const Path &p) {
    std::string s;
    for (int i = 0; i < p.n; i++) { s += "/"; s += p.k[i]; }
    return s;
}
static yyjson_val *get_yy(yyjson_val *v, const Path &p) {
    for (int i = 0; i < p.n; i++) v = is_index(p.k[i]) ? yyjson_arr_get(v, atoi(p.k[i])) : yyjson_obj_get(v, p.k[i]);
    return v;
}

int main(int argc, char **argv) {
    if (argc != 4) return 2;
    std::string lib = argv[1], mode = argv[2], file = argv[3];
    padded_string text = padded_string::load(file).value();
    std::string base = file.substr(file.find_last_of('/') + 1);
    base = base.substr(0, base.size() - 5);
    Path q = query_of(base), r[3];
    reads_of(base, r);
    dom::parser dp;
    ondemand::parser op;
    std::function<void()> fn;
    if (lib == "simdjson-dom") {
        if (mode == "validate" || mode == "parse") fn = [&] { sink += dp.parse(text).value().is_object(); };
        else if (mode == "query") fn = [&] { sink += get_dom(dp.parse(text).value(), q).type() == dom::element_type::NULL_VALUE; };
        else if (mode == "read3") fn = [&] { dom::element d = dp.parse(text).value(); for (auto &p : r) sink += (size_t)get_dom(d, p).type(); };
        else if (mode == "walk") fn = [&] { sink += walk_dom(dp.parse(text).value()); };
    } else if (lib == "simdjson-ondemand") {
        if (mode == "validate") fn = [&] { auto d = op.iterate(text); sink += walk_od(d.get_value().value()); };
        else if (mode == "query") fn = [&] { auto d = op.iterate(text); sink += (size_t)d.at_pointer(pointer(q)).type().value(); };
        else if (mode == "read3") fn = [&] { for (auto &p : r) { auto d = op.iterate(text); sink += (size_t)d.at_pointer(pointer(p)).type().value(); } };
        else if (mode == "walk") fn = [&] { auto d = op.iterate(text); sink += walk_od(d.get_value().value()); };
    } else if (lib == "yyjson") {
        auto rd = [&] { return yyjson_read(text.data(), text.size(), 0); };
        if (mode == "validate" || mode == "parse") fn = [&] { yyjson_doc *d = rd(); sink += d != nullptr; yyjson_doc_free(d); };
        else if (mode == "query") fn = [&] { yyjson_doc *d = rd(); sink += get_yy(yyjson_doc_get_root(d), q) != nullptr; yyjson_doc_free(d); };
        else if (mode == "read3") fn = [&] { yyjson_doc *d = rd(); for (auto &p : r) sink += get_yy(yyjson_doc_get_root(d), p) != nullptr; yyjson_doc_free(d); };
        else if (mode == "walk") fn = [&] { yyjson_doc *d = rd(); sink += walk_yy(yyjson_doc_get_root(d)); yyjson_doc_free(d); };
    }
    if (!fn) { puts("skip"); return 0; }
    double best = 1e9, total = 0;
    for (int n = 0; n < 3 || total < 0.5; n++) {
        auto t = std::chrono::steady_clock::now();
        fn();
        double s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t).count();
        if (s < best) best = s;
        total += s;
    }
    printf("%.6g\n", best);
    return sink == (size_t)-1;
}
