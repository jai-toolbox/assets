/*
-----
Usage

init_from_loose_files("data");

ok, shader := load_asset("shaders/default.glsl");
if ok {
    // use shader
}

package_directory("data", "data.package");

deinit_assets();

-----
Memory Model

load_asset returns memory that's owned by the Assets struct.

If the mode is loose files, then that memory comes from the loose cache.
If the mode is simple package, then it comes from the package data table.

If you want to modify the data, use load_asset_copy.

init_from_package_memory takes ownership of the supplied data when it
succeeds. The caller retains ownership when it fails.
*/

Simple_Package :: #import "Simple_Package";

Asset_Mode :: enum {
    LOOSE_FILES;
    SIMPLE_PACKAGE;
}

Assets :: struct {
    mode: Asset_Mode;
    base_path: string;

    package: Simple_Package.Load_Package;

    loose_cache: Table(string, string);
}

deinit :: (using p : *Simple_Package.Load_Package) {
    array_free(entries);
    deinit(*lookup);
}

assets: Assets;
assets_initialized := false;

#if OS != .WASM {
    init_from_loose_files :: (base_path: string) {
        assets.mode = .LOOSE_FILES;
        assets.base_path = base_path;
        assets_initialized = true;
    }

    init_from_package :: (package_path: string) -> bool {
        data, file_ok := read_entire_file(package_path);
        if !file_ok {
            log_error("Could not read asset package '%'.\n", package_path);
            return false;
        }

        ok := init_from_package_memory(data, package_path);
        if !ok {
            free(data);
            return false;
        }

        return true;
    }
}

// Initializes the asset system from a complete package already resident in
// memory. On success, Assets owns data and releases it in deinit_assets. On
// failure, ownership remains with the caller.
init_from_package_memory :: (data: string, name_for_debugging := "memory package") -> bool {
    ok := Simple_Package.init_from_memory(*assets.package, xx data, name_for_debugging);
    if !ok return false;

    assets.mode = .SIMPLE_PACKAGE;
    assets.base_path = "";
    assets_initialized = true;

    return true;
}

normalize_asset_path :: (path: string) -> string {
    normalized_path := copy_temporary_string(path);
    normalize_slashes(normalized_path);

    if begins_with(normalized_path, "data/") {
        advance(*normalized_path, 5);
    }

    return normalized_path;
}

// Returned data is borrowed. Do not free it.
// assets are raw binary data, eg an array of u8, eg a string
// you can then interpret that how you please.
// maybe we should call this read_asset or somthing idk.
load_asset :: (path: string) -> bool, string {
    assert(assets_initialized);

    asset_path := normalize_asset_path(path);

    if assets.mode == {
        case .LOOSE_FILES;
#if OS == .WASM {
            log_error("Loose-file assets are unavailable on the WebAssembly target.\n");
            return false, "";
} else {
            found, cached := table_find(*assets.loose_cache, asset_path);
            if found return true, cached;

            full_path := tprint("%/%", assets.base_path, asset_path);
            if is_absolute_path(asset_path) {
                full_path = asset_path;
            }
            data, ok := read_entire_file(full_path);
            if !ok return false, "";

            path_copy := copy_string(asset_path);
            table_add(*assets.loose_cache, path_copy, data);

            return true, data;
}

        case .SIMPLE_PACKAGE;
            found, entry := table_find(*assets.package.lookup, asset_path);
            if !found return false, "";

            data := string.{ entry.data.count, entry.data.data };
            return true, data;
    }

    return false, "";
}

load_asset_copy :: (path: string) -> bool, string {
    ok, data := load_asset(path);
    if !ok return false, "";

    copy := alloc_string(data.count);
    memcpy(copy.data, data.data, data.count);

    return true, copy;
}

asset_exists :: (path: string) -> bool {
    ok, _ := load_asset(path);
    return ok;
}

#if OS != .WASM {
    
// This is an acceptance filter
Package_File_Filter :: #type (relative_path: string) -> bool;

relative_path_from_directory :: (full_path: string, directory: string) -> string {
    assert(begins_with(full_path, directory));

    relative_path := copy_temporary_string(advance(full_path, directory.count));
    if relative_path && (relative_path[0] == #char "/" || relative_path[0] == #char "\\") {
        advance(*relative_path, 1);
    }
    normalize_slashes(relative_path);
    return relative_path;
}

package_directory_is_current :: (data_path_abs: string, package_path_abs: string, filter: Package_File_Filter = null) -> bool {
    package_data, package_read := read_entire_file(package_path_abs, log_errors = false);
    if !package_read return false;

    package: Simple_Package.Load_Package;
    defer {
        free(package_data);
        deinit(*package);
    }

    if !Simple_Package.init_from_memory(*package, xx package_data, package_path_abs) {
        return false;
    }

    // the struct that gets passed to it
    Comparison_Context :: struct {
        source_dir: string;
        filter: Package_File_Filter;
        package: *Simple_Package.Load_Package;
        included_file_count: int;
        matches := true;
    }

    comparison: Comparison_Context;
    comparison.source_dir = data_path_abs;
    comparison.filter = filter;
    comparison.package = *package;

    visitor :: (info: *File_Visit_Info, comparison: *Comparison_Context) {
        if !comparison.matches || info.is_directory return;
            
        if info.short_name.count > 0 && info.short_name[0] == #char "." return;

        relative_path := relative_path_from_directory(info.full_name, comparison.source_dir);

        if comparison.filter != null && !comparison.filter(relative_path) return;
        comparison.included_file_count += 1;

        found, entry := table_find(*comparison.package.lookup, relative_path);
        if !found { comparison.matches = false; return; }

        source_data, source_read := read_entire_file(info.full_name);
        if !source_read {
            comparison.matches = false;
            return;
        }
        defer free(source_data.data);

        packaged_data := string.{entry.data.count, entry.data.data};
        if source_data != packaged_data comparison.matches = false;
    }

    visit_ok := visit_files(data_path_abs, recursive = true, *comparison, visitor);
        
    have_same_num_files := comparison.included_file_count == package.entries.count;
        
    return visit_ok && comparison.matches && have_same_num_files;
}

package_directory_if_needed :: (data_path_abs: string, package_path_abs: string, filter: Package_File_Filter = null) -> bool {
    if package_directory_is_current(data_path_abs, package_path_abs, filter) {
        print("Asset package is up to date: %\n", package_path_abs);
        return true;
    }

    print("Building asset package: %\n", package_path_abs);
    return package_directory(data_path_abs, package_path_abs, filter);
}

package_directory :: (source_dir: string, output_package: string, filter: Package_File_Filter = null) -> bool {
    Package_Context :: struct {
        source_dir: string;
        filter: Package_File_Filter;
        package: Simple_Package.Create_Package;
        file_buffers: [..] string;
        success: bool = true;
    }

    ctx: Package_Context;
    ctx.source_dir = source_dir;
    ctx.filter = filter;

    defer {
        for ctx.file_buffers {
            free(it.data);
        }

        array_free(ctx.file_buffers);
        free_buffers(*ctx.package.data);
        array_free(ctx.package.entries);
        release(*ctx.package.pool);
    }

    Simple_Package.init(*ctx.package);

    visitor :: (info: *File_Visit_Info, ctx: *Package_Context) {
        if !ctx.success return;
        if info.is_directory return;
        if info.short_name.count > 0 && info.short_name[0] == #char "." return;

        relative_path := relative_path_from_directory(info.full_name, ctx.source_dir);

        if ctx.filter != null && !ctx.filter(relative_path) return;

        data, ok := read_entire_file(info.full_name);
        if !ok {
            log_error("Could not read asset file '%'.\n", info.full_name);
            ctx.success = false;
            return;
        }

        array_add(*ctx.file_buffers, data);

        Simple_Package.add(*ctx.package, relative_path, xx data);
    }

    ok := visit_files(source_dir, recursive = true, *ctx, visitor);
    if !ok return false;
    if !ctx.success return false;

    return Simple_Package.write(*ctx.package, output_package);
}
}

normalize_slashes :: (path: string) {
    for i: 0..path.count-1 {
        if path[i] == #char "\\" path[i] = #char "/";
    }
}

deinit :: (assets: *Assets) {
    for assets.loose_cache {
        free(it_index.data);
        free(it.data);
    }

    deinit(*assets.loose_cache);

    free(assets.package.data.data);
    array_free(assets.package.entries);
    deinit(*assets.package.lookup);

    assets.* = .{};
}

deinit_assets :: () {
    if !assets_initialized return;
    deinit(*assets);
    assets_initialized = false;
}

#import "Basic";
#import "Hash_Table";
#import "String";

#if OS != .WASM {
    #import "File";
    #import "File_Utilities";
    #import "Pool";
}
