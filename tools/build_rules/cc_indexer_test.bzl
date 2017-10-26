#
# Copyright 2017 Google Inc. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

load(
    "//tools:build_rules/verifier_test.bzl",
    "extract",
    "verifier_test",
    "KytheEntries",
    "KytheVerifierSources",
)

CxxCompilationUnits = provider(
    doc = "A bundle of pre-extracted Kythe CompilationUnits for C++.",
    fields = {
        "files": "Depset of .kindex files.",
    },
)

_VERIFIER_FLAGS = {
    "convert_marked_source": False,
    "ignore_dups": False,
    "check_for_singletons": False,
    "goal_prefix": "//-",
}

_INDEXER_FLAGS = {
    "fail_on_unimplemented_builtin": True,
    "ignore_unimplemented": False,
    "index_template_instantiations": True,
    "experimental_alias_template_instantiations": False,
    "experimental_drop_instantiation_independent_data": False,
}

def _flag(name, typename, value):
  if type(value) != typename:
    fail("Invalid value for %s: %s; expected %s, found %s" % (
        name, value, typename, type(value)))
  if typename == "bool":
    value = str(value).lower()
  return "--%s=%s" % (name, value)

def _split_flags(kwargs):
  flags = struct(
      indexer = [_flag(name, type(default), kwargs.pop(name, default))
                 for name, default in _INDEXER_FLAGS.items()],
      verifier = [_flag(name, type(default), kwargs.pop(name, default))
                  for name, default in _VERIFIER_FLAGS.items()],
  )
  if kwargs:
    fail("Unrecognized verifier flags: %s" % (kwargs.keys(),))
  return flags

def _transitive_entries(deps):
  files, compressed = depset(), depset()
  for dep in deps:
    if KytheEntries in dep:
      files += dep[KytheEntries].files
      compressed += dep[KytheEntries].compressed
  return KytheEntries(files=files, compressed=compressed)

def _cc_extract_kindex_impl(ctx):
  outputs = depset([
    extract(
        ctx = ctx,
        kindex = getattr(ctx.outputs, src.basename),
        extractor = ctx.executable._extractor,
        vnames_config = ctx.file.vnames_config,
        srcs = [src],
        opts = ctx.attr.opts,
        deps = ctx.files.deps + ctx.files.srcs,
    )
    for src in ctx.files.srcs])
  for dep in ctx.attr.deps:
    if CxxCompilationUnits in dep:
      outputs += dep[CxxCompilationUnits].files
  return [
      CxxCompilationUnits(files=outputs),
      KytheVerifierSources(files=depset(ctx.files.srcs)),
      _transitive_entries(ctx.attr.deps),
  ]

def _cc_extract_kindex_outs(name, srcs):
  return dict([(src.name, "{}/{}.kindex".format(name, src.name)) for src in srcs])

cc_extract_kindex = rule(
    attrs = {
        "srcs": attr.label_list(
            doc = "A list of C++ source files to extract.",
            mandatory = True,
            allow_empty = False,
            allow_files = [
                ".cc",
                ".c",
                ".h",
            ],
        ),
        "deps": attr.label_list(
            doc = """Files which are required by the extracted sources.

            Additionally, targets providing KytheEntries or CxxCompilationUnits
            may be used for dependencies which are required for an eventual
            Kythe index, but should not be extracted here.
            """,
            allow_files = [
                ".cc",
                ".c",
                ".h",
                ".meta",  # Cross language metadata files.
            ],
            providers = [
                [KytheEntries],
                [CxxCompilationUnits],
            ],
        ),
        "vnames_config": attr.label(
            doc = "vnames_config file to be used by the extractor.",
            default = Label("//kythe/data:vnames_config"),
            allow_single_file = [".json"],
        ),
        "opts": attr.string_list(
            doc = "Options which will be passed to the extractor as arguments.",
        ),
        "copts": attr.string_list(
            doc = """Options which are required to compile/index the sources.

            These will be included in the resulting .kindex CompilationUnits.
            """,
        ),
        "_extractor": attr.label(
            default = Label("//kythe/cxx/extractor:cxx_extractor"),
            executable = True,
            cfg = "host",
        ),
    },
    doc = """cc_extract_kindex extracts srcs into CompilationUnits.

    Each file in srcs will be extracted into a separate .kindex file, based on the name
    of the source.
    """,
    outputs = _cc_extract_kindex_outs,
    implementation = _cc_extract_kindex_impl,
)

def _extract_bundle_impl(ctx):
  bundle = ctx.actions.declare_directory(ctx.label.name + "_unbundled")
  ctx.actions.run(
      inputs = [ctx.executable._unbundle, ctx.file.src],
      outputs = [bundle],
      mnemonic = "Unbundle",
      executable = ctx.executable._unbundle,
      arguments = [ctx.file.src.path, bundle.path]
  )
  ctx.actions.run_shell(
      inputs = [
          ctx.executable._extractor,
          ctx.file._vnames_config,
          bundle,
      ],
      outputs = [ctx.outputs.kindex],
      mnemonic = "ExtractBundle",
      env = {
        "KYTHE_ROOT_DIRECTORY": ".",
        "KYTHE_OUTPUT_FILE": ctx.outputs.kindex.path,
        "KYTHE_VNAMES": ctx.file._vnames_config.path,
      },
      arguments = [
          ctx.executable._extractor.path,
          bundle.path,
      ] + ctx.attr.opts,
      command = "\"$1\" -c \"${@:2}\" $(cat \"${2}/cflags\") \"${2}/test_bundle/test.cc\"",
  )
  # TODO(shahms): Allow directly specifying the unbundled sources as verifier sources,
  #   rather than relying on --use_file_nodes.
  #   Possibly, just use the bundled source directly as the verifier doesn't actually
  #   care about the expanded source.
  #   Bazel makes it hard to use a glob here.
  return [CxxCompilationUnits(files=depset([ctx.outputs.kindex]))]

cc_extract_bundle = rule(
    attrs = {
        "src": attr.label(
            doc = "Label of the bundled test to extract.",
            mandatory = True,
            allow_single_file = True,
        ),
        "_vnames_config": attr.label(
            default = Label("//kythe/cxx/indexer/cxx/testdata:test_vnames.json"),
            allow_single_file = True,
        ),
        "_unbundle": attr.label(
            default = Label("//tools:unbundle"),
            executable = True,
            cfg = "host",
        ),
        "_extractor": attr.label(
            default = Label("//kythe/cxx/extractor:cxx_extractor"),
            executable = True,
            cfg = "host",
        ),
        "opts": attr.string_list(
            doc = "Additional arguments to pass to the extractor.",
        ),
    },
    doc = "Extracts a bundled C++ indexer test into a .kindex file.",
    outputs = {
        "kindex": "%{name}.kindex",
    },
    implementation = _extract_bundle_impl,
)

def _bazel_extract_kindex_impl(ctx):
  # TODO(shahms): This is a hack as we get both executable
  #   and .sh from files.scripts but only want the "executable" one.
  #   Unlike `attr.label`, `attr.label_list` lacks an `executable` argument.
  #   Excluding "is_source" files may be overly aggressive, but effective.
  scripts = [s for s in ctx.files.scripts if not s.is_source]
  ctx.action(
      inputs = [
          ctx.executable.extractor,
          ctx.file.vnames_config,
          ctx.file.data
      ] + scripts + ctx.files.srcs,
      outputs = [ctx.outputs.kindex],
      mnemonic = "BazelExtractKindex",
      executable = ctx.executable.extractor,
      arguments = [
          ctx.file.data.path,
          ctx.outputs.kindex.path,
          ctx.file.vnames_config.path
      ] + [script.path for script in scripts]
  )
  return [
      KytheVerifierSources(files=ctx.files.srcs),
      CxxCompilationUnits(files=depset([ctx.outputs.kindex])),
  ]

# TODO(shahms): Clean up the bazel extraction rules.
_bazel_extract_kindex = rule(
    attrs = {
        "srcs": attr.label_list(
            doc = "Source files to provide via KytheVerifierSources.",
            allow_files = True,
        ),
        "data": attr.label(
            doc = "The .xa extra action to extract.",
            # TODO(shahms): This should be the "src" which is extracted.
            mandatory = True,
            allow_single_file = [".xa"],
        ),
        "scripts": attr.label_list(
            cfg = "host",
            allow_files = True,
        ),
        "vnames_config": attr.label(
            default = Label("//kythe/data:vnames_config"),
            allow_single_file = True,
        ),
        "extractor": attr.label(
            default = Label("//kythe/cxx/extractor:cxx_extractor_bazel"),
            executable = True,
            cfg = "host",
        ),
    },
    doc = "Extracts a Bazel extra action binary proto file into a .kindex.",
    outputs = {
        "kindex": "%{name}.kindex",
    },
    implementation = _bazel_extract_kindex_impl,
)

def _cc_index_source(ctx, src):
  entries = ctx.actions.declare_file(ctx.label.name + src.basename + ".entries")
  ctx.actions.run(
      mnemonic = "CcIndexSource",
      outputs = [entries],
      inputs = [ctx.executable._indexer] + ctx.files.srcs + ctx.files.deps,
      executable = ctx.executable._indexer,
      arguments = [ctx.expand_location(o) for o in ctx.attr.opts] + [
          "-i", src.path,
          "-o", entries.path,
          "--",
          "-c",
      ] + [ctx.expand_location(o) for o in ctx.attr.copts],
  )
  return entries

def _cc_index_compilation(ctx, kindex):
  if ctx.attr.copts:
    print("Ignoring compiler options:", ctx.attr.copts)
  entries = ctx.actions.declare_file(
      ctx.label.name + kindex.basename + ".entries")
  ctx.actions.run(
      mnemonic = "CcIndexCompilation",
      outputs = [entries],
      inputs = [ctx.executable._indexer, kindex],
      executable = ctx.executable._indexer,
      arguments = [ctx.expand_location(o) for o in ctx.attr.opts] + [
          "-o", entries.path, kindex.path,
      ]
  )
  return entries

def _cc_index_single_file(ctx, input):
  if input.extension == "kindex":
    return _cc_index_compilation(ctx, input)
  elif input.extension in ("c", "cc", "m"):
    return _cc_index_source(ctx, input)
  fail("Cannot index input file: %s" % (input,))

def _cc_index_impl(ctx):
  intermediates = [
      _cc_index_single_file(ctx, src)
      for src in ctx.files.srcs
      if src.extension in ("m", "c", "cc", "kindex")
  ]
  intermediates += [
      _cc_index_compilation(ctx, kindex)
      for dep in ctx.attr.deps
      if CxxCompilationUnits in dep
      for kindex in dep[CxxCompilationUnits].files
      if kindex not in ctx.files.deps
  ]

  entries = depset(intermediates)
  for dep in ctx.attr.deps:
    if KytheEntries in dep:
      entries += dep[KytheEntries].files

  ctx.actions.run_shell(
      outputs = [ctx.outputs.entries],
      inputs = entries,
      command = '("${@:1:${#@}-1}" || rm -f "${@:${#@}}") | gzip -c > "${@:${#@}}"',
      mnemonic = "CompressEntries",
      arguments = ["cat"] + [i.path for i in entries] + [ctx.outputs.entries.path],
  )

  sources = depset([src for src in ctx.files.srcs if src.extension != "kindex"])
  for dep in ctx.attr.srcs:
    if KytheVerifierSources in dep:
      sources += dep[KytheVerifierSources].files
  return [
      KytheVerifierSources(files=sources),
      KytheEntries(files=entries, compressed=depset([ctx.outputs.entries])),
  ]

# TODO(shahms): Support cc_library srcs and deps, along with cc toolchain support.
# TODO(shahms): Split objc_index into a separate rule.
cc_index = rule(
    attrs = {
        # .cc/.h files, added to KytheVerifierSources provider, but not transitively.
        # CxxCompilationUnits, which may also include sources.
        "srcs": attr.label_list(
            doc = "C++/ObjC source files or extracted .kindex files to index.",
            allow_files = [
                ".cc",
                ".c",
                ".h",
                ".m",  # Objective-C is supported by the indexer as well.
                ".kindex",
            ],
            providers = [CxxCompilationUnits],
        ),
        "deps": attr.label_list(
            doc = "Files required to index srcs or entries to include in the index.",
            # .meta files, .h files, .entries{,.gz}, KytheEntries
            allow_files = [
                ".h",
                ".entries",
                ".entries.gz",
                ".meta",  # Cross language metadata files.
            ],
            providers = [KytheEntries],
        ),
        "opts": attr.string_list(
            doc = "Options to pass to the indexer.",
        ),
        "copts": attr.string_list(
            doc = "Options to pass to the compiler while indexing.",
        ),
        "_indexer": attr.label(
            default = Label("//kythe/cxx/indexer/cxx:indexer"),
            executable = True,
            cfg = "host",
        ),
    },
    doc = """Produces a Kythe index from the C++ source files.

    Files in `srcs` and `deps` will be indexed, files in `srcs` will
    additionally be included in the provided KytheVerifierSources.
    KytheEntries dependencies will be transitively included in the index.
    """,
    outputs = {
        "entries": "%{name}.entries.gz",
    },
    implementation = _cc_index_impl,
)

def _indexer_test(name, srcs, copts, deps=[], tags=[], size="small",
                  restricted_to=["//buildenv:all"],
                  bundled=False, expect_fail_verify=False, **kwargs):
  flags = _split_flags(kwargs)
  if bundled:
    if len(srcs) != 1:
      fail("Bundled indexer tests require exactly one src!")
    cc_extract_bundle(
        name = name + "_kindex",
        src = srcs[0],
        testonly = True,
        tags = tags,
        opts = copts,
        restricted_to = restricted_to,
    )
    srcs = [":" + name + "_kindex"]
  cc_index(
      name = name + "_entries",
      srcs = srcs,
      deps = deps,
      tags = tags,
      testonly = True,
      copts = copts if not bundled else [],
      restricted_to = restricted_to,
      opts = (["-claim_unknown=false"] if bundled else []) + flags.indexer,
  )
  verifier_test(
      name = name,
      # TODO(shahms): Use sources directly?
      srcs = [":" + name + "_entries"],
      tags = tags,
      size = size,
      expect_success = not expect_fail_verify,
      restricted_to = restricted_to,
      opts = flags.verifier,
  )

# If a test is expected to pass on darwin but not on linux, you can set
# restricted_to=["//buildenv:darwin"]. This causes the test to be skipped on linux and it
# causes the actual test to execute on darwin.
def cc_indexer_test(name, srcs, deps=[], tags=[], size="small",
                    restricted_to=["//buildenv:all"], std="c++11",
                    bundled=False, expect_fail_verify=False, **kwargs):
  """C++ indexer test rule.

  Args:
    name: The name of the test rule.
    srcs: Source files to index and run the verifier.
    deps: Sources, compilation units or entries which should be present
      in the index or are required to index the sources.
    std: The C++ standard to use for the test.
    bundled: True if this test is a "bundled" C++ test and must be extracted.
    expect_fail_verify: True if this test is expected to fail.
    convert_marked_source: Whether the verifier should convert marked source.
    ignore_dups: Whether the verifier should ignore duplicate nodes.
    check_for_singletons: Whether the verifier should check for singleton facts.
    goal_prefix: The comment prefix the verifier should use for goals.
    fail_on_unimplemented_builtin: Whether the indexer should fail on
      unimplemented builtins.
    ignore_unimplemented: Whether the indexer should continue after encountering
      an unimplemented construct.
    index_template_instantiations: Whether the indexer should index template
      instantiations.
    experimental_alias_template_instantiations: Whether the indexer should alias
      template instantiations.
    experimental_drop_instantiation_independent_data: Whether the indexer should
      drop extraneous instantiation independent data.
  """
  _indexer_test(
      name = name,
      srcs = srcs,
      deps = deps,
      tags = tags,
      size = size,
      copts = ["-std=" + std],
      restricted_to = restricted_to,
      bundled = bundled,
      expect_fail_verify = expect_fail_verify,
      **kwargs
  )

def objc_indexer_test(name, srcs, deps=[], tags=[], size="small",
                      restricted_to=["//buildenv:all"], bundled=False,
                      expect_fail_verify=False, **kwargs):
  """Objective C indexer test rule.

  Args:
    name: The name of the test rule.
    srcs: Source files to index and run the verifier.
    deps: Sources, compilation units or entries which should be present
      in the index or are required to index the sources.
    bundled: True if this test is a "bundled" C++ test and must be extracted.
    expect_fail_verify: True if this test is expected to fail.
    convert_marked_source: Whether the verifier should convert marked source.
    ignore_dups: Whether the verifier should ignore duplicate nodes.
    check_for_singletons: Whether the verifier should check for singleton facts.
    goal_prefix: The comment prefix the verifier should use for goals.
    fail_on_unimplemented_builtin: Whether the indexer should fail on
      unimplemented builtins.
    ignore_unimplemented: Whether the indexer should continue after encountering
      an unimplemented construct.
    index_template_instantiations: Whether the indexer should index template
      instantiations.
    experimental_alias_template_instantiations: Whether the indexer should alias
      template instantiations.
    experimental_drop_instantiation_independent_data: Whether the indexer should
      drop extraneous instantiation independent data.
  """
  _indexer_test(
      name = name,
      srcs = srcs,
      deps = deps,
      tags = tags,
      size = size,
      copts = ["-fblocks"],
      restricted_to = restricted_to,
      bundled = bundled,
      expect_fail_verify = expect_fail_verify,
      **kwargs
  )

def objc_bazel_extractor_test(name, src, data, size="small", tags=[], restricted_to=["//buildenv:all"]):
  """Objective C Bazel extractor test.

  Args:
    src: The source file to use with the verifier.
    data: The extracted .xa protocol buffer to index.
  """
  _bazel_extract_kindex(
      name = name + "_kindex",
      srcs = [src],
      data = data,
      extractor = "//kythe/cxx/extractor:objc_extractor_bazel",
      scripts = [
          "//third_party/bazel:get_devdir",
          "//third_party/bazel:get_sdkroot",
      ],
      tags = tags,
      restricted_to = restricted_to,
      testonly = True,
  )
  cc_index(
      name = name + "_entries",
      srcs = [":" + name + "_kindex"],
      tags = tags,
      restricted_to = restricted_to,
      testonly = True,
  )
  return verifier_test(
      name = name,
      srcs = [":" + name + "_entries"],
      size = size,
      restricted_to = restricted_to,
      opts = ["--ignore_dups"],
      tags = tags,
  )

def cc_bazel_extractor_test(name, src, data, size="small", tags=[]):
  """C++ Bazel extractor test.

  Args:
    src: The source file to use with the verifier.
    data: The extracted .xa protocol buffer to index.
  """
  _bazel_extract_kindex(
      name = name + "_kindex",
      srcs = [src],
      data = data,
      tags = tags,
      testonly = True,
  )
  cc_index(
      name = name + "_entries",
      srcs = [":" + name + "_kindex"],
      tags = tags,
      testonly = True,
  )
  return verifier_test(
      name = name,
      size = size,
      tags = tags,
      opts = ["--ignore_dups"],
      srcs = [":" + name + "_entries"],
  )

def cc_extractor_test(name, srcs, deps=[], data=[], size="small", std="c++11", tags=[],
                      restricted_to=["//buildenv:all"]):
  """C++ verifier test on an extracted source file."""
  args = ["-std=" + std, "-c"]
  cc_extract_kindex(
      name = name + "_kindex",
      srcs = srcs,
      deps = data,
      tags = tags,
      restricted_to = restricted_to,
      testonly = True,
      opts = select({
          "//conditions:default": args,
          "//:darwin": args + [
              # TODO(zarko): This needs to be autodetected (or does doing so even make sense?)
              "-I/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/include/c++/v1",
              # TODO(salguarnieri): This could be made more generic with:
              # $(xcrun --show-sdk-path)/usr/include
              "-I/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX10.11.sdk/usr/include",
          ],
      }),
  )
  cc_index(
      name = name + "_entries",
      srcs = [":" + name + "_kindex"],
      deps = data,
      opts = ["--ignore_unimplemented"],
      tags = tags,
      restricted_to = restricted_to,
      testonly = True,
  )
  return verifier_test(
      name = name,
      size = size,
      srcs = [":" + name + "_entries"],
      deps = deps,
      opts = ["--ignore_dups"],
      restricted_to = restricted_to,
      tags = tags,
  )
