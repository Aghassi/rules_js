"creates tar layers from js_binary targets"

load("@aspect_bazel_lib//lib:paths.bzl", "to_manifest_path")
load("@bazel_skylib//lib:paths.bzl", "paths")

_doc = """Create container image layers from js_binary targets.

```starlark
load("@aspect_rules_js//js:defs.bzl", "js_binary", "js_image_layer")
load("@io_bazel_rules_docker//container:container.bzl", "container_image")

js_binary(
    name = "main",
    data = [
        "//:node_modules/args-parser",
    ],
    entry_point = "main.js",
)


js_image_layer(
    name = "layers",
    binary = ":main",
    root = "/app",
    visibility = ["//visibility:__pkg__"],
)

filegroup(
    name = "app_tar", 
    srcs = [":layers"], 
    output_group = "app"
)
container_layer(
    name = "app_layer",
    tars = [":app_tar"],
)

filegroup(
    name = "node_modules_tar", 
    srcs = [":layers"], 
    output_group = "node_modules"
)
container_layer(
    name = "node_modules_layer",
    tars = [":node_modules_tar"],
)

container_image(
    name = "image",
    cmd = ["/app/main.sh"],
    entrypoint = ["bash"],
    layers = [
        ":app_layer",
        ":node_modules_layer",
    ],
)
```
"""

# BAZEL_BINDIR has to be set to '.' so that js_binary preserves the PWD when running inside container.
# See https://github.com/aspect-build/rules_js/tree/dbb5af0d2a9a2bb50e4cf4a96dbc582b27567155#running-nodejs-programs
# for why this is needed.
_LAUNCHER_TMPL = """
export BAZEL_BINDIR=.
source {executable_path}
"""

def _write_laucher(ctx, executable_path):
    "Creates a call-through shell entrypoint which sets BAZEL_BINDIR to '.' then immediately invokes the original entrypoint."
    launcher = ctx.actions.declare_file("%s_launcher.sh" % ctx.label.package)
    ctx.actions.write(
        output = launcher,
        content = _LAUNCHER_TMPL.format(executable_path = executable_path),
        is_executable = True,
    )
    return launcher

def _runfile_path(ctx, file, runfiles_dir):
    return paths.join(runfiles_dir, to_manifest_path(ctx, file))

def _runfiles_dir(root, default):
    manifest = default.files_to_run.runfiles_manifest
    return paths.join(root, manifest.short_path.replace(manifest.basename, "")[:-1])

def _js_image_layer_impl(ctx):
    default = ctx.attr.binary[DefaultInfo]

    executable = default.files_to_run.executable
    executable_path = paths.join(ctx.attr.root, executable.short_path)
    original_executable_path = executable_path.replace(".sh", "_.sh")
    launcher = _write_laucher(ctx, original_executable_path)

    files = {}

    files[original_executable_path] = {"dest": executable.path, "root": executable.root.path}
    files[executable_path] = {"dest": launcher.path, "root": launcher.root.path}

    runfiles_dir = _runfiles_dir(ctx.attr.root, default)

    for file in default.files.to_list() + default.default_runfiles.files.to_list():
        destination = _runfile_path(ctx, file, runfiles_dir)
        files[destination] = {"dest": file.path, "root": file.root.path, "is_source": file.is_source, "is_directory": file.is_directory}

    entries = ctx.actions.declare_file("{}_entries.json".format(ctx.label.name))
    ctx.actions.write(entries, content = json.encode(files))

    app = ctx.actions.declare_file("{}_app.tar.gz".format(ctx.label.name))
    node_modules = ctx.actions.declare_file("{}_node_modules.tar.gz".format(ctx.label.name))

    args = ctx.actions.args()
    args.add("--node_options=--no-warnings")
    args.add(entries)
    args.add(app)
    args.add(node_modules)

    ctx.actions.run(
        inputs = depset([executable, launcher, entries], transitive = [default.files, default.default_runfiles.files]),
        outputs = [app, node_modules],
        arguments = [args],
        executable = ctx.executable._builder,
        progress_message = "JsImageLayer %{label}",
        env = {
            "BAZEL_BINDIR": ".",
        },
    )

    return [
        DefaultInfo(files = depset([app, node_modules])),
        OutputGroupInfo(app = depset([app]), node_modules = depset([node_modules])),
    ]

js_image_layer = rule(
    implementation = _js_image_layer_impl,
    doc = _doc,
    attrs = {
        "binary": attr.label(mandatory = True, doc = "Label to an js_binary target"),
        "root": attr.string(doc = "Path where the files from js_binary will reside in. eg: /apps/app1 or /app"),
        "_builder": attr.label(default = "//js/private:js_image_layer_builder", executable = True, cfg = "exec"),
    },
)
