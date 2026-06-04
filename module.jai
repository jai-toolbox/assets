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

assets: Assets;
assets_initialized := false;

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

    ok := Simple_Package.init_from_memory(*assets.package, xx data, package_path);
    if !ok {
        free(data);
        return false;
    }

    assets.package.data = xx data;

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
load_asset :: (path: string) -> bool, string {
    assert(assets_initialized);

    asset_path := normalize_asset_path(path);

    if assets.mode == {
        case .LOOSE_FILES;
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

package_directory :: (source_dir: string, output_package: string) -> bool {
    Package_Context :: struct {
        source_dir: string;
        package: Simple_Package.Create_Package;
        file_buffers: [..] string;
        success: bool = true;
    }

    ctx: Package_Context;
    ctx.source_dir = source_dir;

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

        data, ok := read_entire_file(info.full_name);
        if !ok {
            log_error("Could not read asset file '%'.\n", info.full_name);
            ctx.success = false;
            return;
        }

        array_add(*ctx.file_buffers, data);

        relative_path := advance(info.full_name, ctx.source_dir.count);

        if relative_path && (relative_path[0] == #char "/" || relative_path[0] == #char "\\") {
            advance(*relative_path, 1);
        }

        normalize_slashes(relative_path);

        Simple_Package.add(*ctx.package, relative_path, xx data);
    }

    ok := visit_files(source_dir, recursive = true, *ctx, visitor);
    if !ok return false;
    if !ctx.success return false;

    return Simple_Package.write(*ctx.package, output_package);
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
#import "File";
#import "File_Utilities";
#import "Hash_Table";
#import "Pool";
#import "String";
