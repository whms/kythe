/*
 * Copyright 2016 The Kythe Authors. All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#include <string>
#include <vector>

#include <fcntl.h>
#include <stdio.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include "glog/logging.h"
#include "google/protobuf/io/coded_stream.h"
#include "google/protobuf/io/zero_copy_stream.h"
#include "google/protobuf/io/zero_copy_stream_impl.h"
#include "google/protobuf/stubs/common.h"
#include "rapidjson/stringbuffer.h"
#include "rapidjson/writer.h"
#include "third_party/bazel/src/main/protobuf/extra_actions_base.pb.h"

namespace {
using ::google::protobuf::io::CodedInputStream;
using ::google::protobuf::io::FileInputStream;

bool ReadExtraAction(const std::string& path, blaze::ExtraActionInfo* info,
                     blaze::CppCompileInfo* cpp_info) {
  int fd = ::open(path.c_str(), O_RDONLY, S_IREAD | S_IWRITE);
  if (fd < 0) {
    perror("Failed to open input: ");
    return false;
  }
  FileInputStream file_input(fd);
  file_input.SetCloseOnDelete(true);

  CodedInputStream input(&file_input);
  if (!info->ParseFromCodedStream(&input)) return false;
  if (!info->HasExtension(blaze::CppCompileInfo::cpp_compile_info))
    return false;
  *cpp_info = info->GetExtension(blaze::CppCompileInfo::cpp_compile_info);
  return true;
}

std::string JoinCommand(const std::vector<std::string>& command) {
  std::string output;
  if (command.empty()) return output;

  // TODO(shahms): Deal with embedded spaces and quotes.
  auto iter = command.begin();
  output = *iter++;
  for (; iter != command.end(); ++iter) {
    output += " " + *iter;
  }
  return output;
}

std::string GetBuildDirectory() {
  std::string build_dir;
  {
    char cwd[MAXPATHLEN];
    build_dir = getcwd(cwd, MAXPATHLEN);
  }
  auto sandbox_start = build_dir.find("/bazel-sandbox/");
  if (sandbox_start == std::string::npos) return build_dir;
  auto sandbox_end =
      build_dir.find("/", sandbox_start + strlen("/bazel-sandbox/"));

  return build_dir.erase(sandbox_start, sandbox_end - sandbox_start);
}

std::string FormatCompilationCommand(const std::string& source_file,
                                     const std::vector<std::string>& command) {
  rapidjson::StringBuffer buffer;
  rapidjson::Writer<rapidjson::StringBuffer> writer(buffer);
  writer.StartObject();
  writer.Key("file");
  writer.String(source_file.c_str());
  writer.Key("directory");
  writer.String(GetBuildDirectory().c_str());
  writer.Key("command");
  writer.String(JoinCommand(command).c_str());
  writer.EndObject();
  return buffer.GetString();
}
}  // namespace

int main(int argc, char** argv) {
  GOOGLE_PROTOBUF_VERIFY_VERSION;
  google::InitGoogleLogging(argv[0]);
  if (argc != 3) {
    fprintf(stderr, "usage: %s extra-action-file output-file\n", argv[0]);
    return 1;
  }
  std::string extra_action_file = argv[1];
  std::string output_file = argv[2];
  blaze::ExtraActionInfo info;
  blaze::CppCompileInfo cpp_info;
  if (!ReadExtraAction(extra_action_file, &info, &cpp_info)) return 1;

  std::vector<std::string> args;
  args.push_back(cpp_info.tool());
  args.insert(args.end(), cpp_info.compiler_option().begin(),
              cpp_info.compiler_option().end());
  if (std::find(args.begin(), args.end(), "-c") == args.end()) {
    args.push_back("-c");
    args.push_back(cpp_info.source_file());
  }
  if (std::find(args.begin(), args.end(), "-o") == args.end()) {
    args.push_back("-o");
    args.push_back(cpp_info.output_file());
  }

  FILE* output = ::fopen(output_file.c_str(), "w");
  if (output == nullptr) {
    perror("Unable to open file for writing: ");
    return 1;
  }
  ::fputs(FormatCompilationCommand(cpp_info.source_file(), args).c_str(),
          output);
  ::fclose(output);

  google::protobuf::ShutdownProtobufLibrary();
  return 0;
}
