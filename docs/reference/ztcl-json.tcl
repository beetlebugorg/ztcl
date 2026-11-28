# Converted by tools/refdoc.tcl convert from ztcl.txt.

command ztcl::json {
    area ztcl
    since TODO
    synopsis {ztcl::json subcommand ?arg ...?}
    summary {JSON: parse to Tcl values, read one value with no full parse, check, and write with a schema.}
    description {JSON: parse to Tcl values, read one value with no full parse, check, and write with a schema. An object is a dict, and an array is a list. Load it with `package require ztcl::json`.}
    page {modules/json.md}
    names {ztcl::json::parse ztcl::json::valid ztcl::json::get ztcl::json::exists ztcl::json::encode ztcl::json::object ztcl::json::array ztcl::json::string ztcl::json::number ztcl::json::bool ztcl::json::null ztcl::json::raw ztcl::json::pretty}
    example {package require ztcl::json; ztcl::json parse {{"a": [1, 2]}}} {a {1 2}}
    example {ztcl::json encode -schema {object {n int}} {n 5}} {{"n":5}}
}
