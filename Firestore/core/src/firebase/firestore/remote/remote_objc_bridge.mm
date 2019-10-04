/*
 * Copyright 2018 Google
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "Firestore/core/src/firebase/firestore/remote/remote_objc_bridge.h"

#include <iomanip>
#include <map>
#include <sstream>
#include <utility>
#include <vector>

#import "Firestore/Source/API/FIRFirestore+Internal.h"

#include "Firestore/core/src/firebase/firestore/model/snapshot_version.h"
#include "Firestore/core/src/firebase/firestore/nanopb/byte_string.h"
#include "Firestore/core/src/firebase/firestore/nanopb/nanopb_util.h"
#include "Firestore/core/src/firebase/firestore/nanopb/writer.h"
#include "Firestore/core/src/firebase/firestore/remote/grpc_util.h"
#include "Firestore/core/src/firebase/firestore/util/error_apple.h"
#include "Firestore/core/src/firebase/firestore/util/hard_assert.h"
#include "Firestore/core/src/firebase/firestore/util/status.h"
#include "Firestore/core/src/firebase/firestore/util/statusor.h"
#include "Firestore/core/src/firebase/firestore/util/string_apple.h"
#include "grpcpp/support/status.h"

namespace firebase {
namespace firestore {
namespace remote {
namespace bridge {

using core::DatabaseInfo;
using local::QueryData;
using model::DocumentKey;
using model::MaybeDocument;
using model::Mutation;
using model::MutationResult;
using model::TargetId;
using model::SnapshotVersion;
using nanopb::ByteString;
using nanopb::ByteStringWriter;
using nanopb::MakeByteString;
using nanopb::MakeNSData;
using remote::Serializer;
using util::MakeString;
using util::MakeNSError;
using util::Status;
using util::StatusOr;
using util::StringFormat;

namespace {

std::string ToHexString(const grpc::ByteBuffer& buffer) {
  std::vector<grpc::Slice> slices;
  grpc::Status status = buffer.Dump(&slices);

  std::stringstream output;
  // The output will look like "0x00 0x0a"
  output << std::hex << std::setfill('0') << std::setw(2);
  for (const auto& slice : slices) {
    for (uint8_t c : slice) {
      output << "0x" << static_cast<int>(c) << " ";
    }
  }

  return output.str();
}

NSData* ConvertToNsData(const grpc::ByteBuffer& buffer, NSError** out_error) {
  std::vector<grpc::Slice> slices;
  grpc::Status status = buffer.Dump(&slices);
  if (!status.ok()) {
    *out_error = MakeNSError(Status{
        Error::Internal, "Trying to convert an invalid grpc::ByteBuffer"});
    return nil;
  }

  if (slices.size() == 1) {
    return [NSData dataWithBytes:slices.front().begin()
                          length:slices.front().size()];
  } else {
    NSMutableData* data = [NSMutableData dataWithCapacity:buffer.Length()];
    for (const auto& slice : slices) {
      [data appendBytes:slice.begin() length:slice.size()];
    }
    return data;
  }
}

grpc::ByteBuffer ConvertToByteBuffer(NSData* data) {
  grpc::Slice slice{[data bytes], [data length]};
  return grpc::ByteBuffer{&slice, 1};
}

template <typename T>
grpc::ByteBuffer ConvertToByteBuffer(const pb_field_t* fields,
                                     const T& request) {
  ByteStringWriter writer;
  writer.WriteNanopbMessage(fields, &request);
  ByteString bytes = writer.Release();

  grpc::Slice slice{bytes.data(), bytes.size()};
  return grpc::ByteBuffer{&slice, 1};
}

template <typename T>
grpc::ByteBuffer ConvertToByteBuffer(const pb_field_t* fields, T&& request) {
  ByteStringWriter writer;

  writer.WriteNanopbMessage(fields, &request);
  Serializer::FreeNanopbMessage(fields, &request);
  ByteString bytes = writer.Release();

  grpc::Slice slice{bytes.data(), bytes.size()};
  return grpc::ByteBuffer{&slice, 1};
}

// Note: `StatusOr` cannot be used with ARC-managed objects.
template <typename Proto>
Proto* ToProto(const grpc::ByteBuffer& message, Status* out_status) {
  NSError* error = nil;
  NSData* data = ConvertToNsData(message, &error);
  if (!error) {
    Proto* proto = [Proto parseFromData:data error:&error];
    if (!error) {
      *out_status = Status::OK();
      return proto;
    }
  }

  std::string error_description =
      StringFormat("Unable to parse response from the server.\n"
                   "Underlying error: %s\n"
                   "Expected class: %s\n"
                   "Received value: %s\n",
                   error, [Proto class], ToHexString(message));

  *out_status = {Error::Internal, error_description};
  return nil;
}

template <typename T, typename U>
std::string DescribeRequest(const pb_field_t* fields, const U& request) {
  // FIXME inefficient implementation.
  auto bytes = ConvertToByteBuffer(fields, request);
  auto ns_data = ConvertToNsData(bytes, nil);
  T* objc_request = [T parseFromData:ns_data error:nil];
  return util::MakeString([objc_request description]);
}

}  // namespace

namespace internal {

StatusOr<ByteString> ToByteString(const grpc::ByteBuffer& buffer) {
  std::vector<grpc::Slice> slices;
  grpc::Status status = buffer.Dump(&slices);
  if (!status.ok()) {
    Status error{Error::Internal,
                 "Trying to convert an invalid grpc::ByteBuffer"};
    error.CausedBy(ConvertStatus(status));
    return error;
  }

  if (slices.size() == 1) {
    return ByteString{slices.front().begin(), slices.front().size()};

  } else {
    std::vector<uint8_t> data;
    data.reserve(buffer.Length());
    for (const auto& slice : slices) {
      data.insert(data.end(), slice.begin(), slice.begin() + slice.size());
    }

    return ByteString{data.data(), data.size()};
  }
}

}

bool IsLoggingEnabled() {
  return [FIRFirestore isLoggingEnabled];
}

// WatchStreamSerializer

WatchStreamSerializer::WatchStreamSerializer(FSTSerializerBeta* serializer)
    : cc_serializer_{serializer.databaseID} {
}

google_firestore_v1_ListenRequest WatchStreamSerializer::CreateWatchRequest(
    const QueryData& query) const {
  google_firestore_v1_ListenRequest request{};

  request.database = cc_serializer_.EncodeDatabaseId();
  request.which_target_change =
      google_firestore_v1_ListenRequest_add_target_tag;
  request.add_target = cc_serializer_.EncodeTarget(query);

  auto labels = cc_serializer_.EncodeListenRequestLabels(query);
  if (!labels.empty()) {
    request.labels_count = nanopb::CheckedSize(labels.size());
    request.labels = MakeArray<google_firestore_v1_ListenRequest_LabelsEntry>(
        request.labels_count);

    pb_size_t i = 0;
    for (const auto& e : labels) {
      request.labels[i].key = Serializer::EncodeString(e.first);
      request.labels[i].value = Serializer::EncodeString(e.second);
      ++i;
    }
  }

  return request;
}

google_firestore_v1_ListenRequest WatchStreamSerializer::CreateUnwatchRequest(
    TargetId target_id) const {
  google_firestore_v1_ListenRequest request{};

  request.database = cc_serializer_.EncodeDatabaseId();
  request.which_target_change =
      google_firestore_v1_ListenRequest_remove_target_tag;
  request.remove_target = target_id;

  return request;
}

grpc::ByteBuffer WatchStreamSerializer::ToByteBuffer(
    google_firestore_v1_ListenRequest&& request) {
  return ConvertToByteBuffer(google_firestore_v1_ListenRequest_fields,
                             std::move(request));
}

StatusOr<NanopbProto<google_firestore_v1_ListenResponse>>
WatchStreamSerializer::ParseResponse(const grpc::ByteBuffer& message) const {
  return NanopbProto<google_firestore_v1_ListenResponse>::Parse(
      google_firestore_v1_ListenResponse_fields, message);
}

std::unique_ptr<WatchChange> WatchStreamSerializer::ToWatchChange(
    const google_firestore_v1_ListenResponse& response) const {
  nanopb::Reader reader{nullptr, 0};  // FIXME
  return cc_serializer_.DecodeWatchChange(&reader, response);
}

SnapshotVersion WatchStreamSerializer::ToSnapshotVersion(
    const google_firestore_v1_ListenResponse& response) const {
  nanopb::Reader reader{nullptr, 0};  // FIXME
  return cc_serializer_.DecodeVersion(&reader, response);
}

std::string WatchStreamSerializer::Describe(
    const google_firestore_v1_ListenRequest& request) {
  return DescribeRequest<GCFSListenRequest>(
      google_firestore_v1_ListenRequest_fields, request);
}

std::string WatchStreamSerializer::Describe(
    const google_firestore_v1_ListenResponse& response) {
  return DescribeRequest<GCFSListenResponse>(
      google_firestore_v1_ListenResponse_fields, response);
}

// WriteStreamSerializer

WriteStreamSerializer::WriteStreamSerializer(FSTSerializerBeta* serializer)
    : cc_serializer_{serializer.databaseID} {
}

void WriteStreamSerializer::UpdateLastStreamToken(
    const google_firestore_v1_WriteResponse& proto) {
  last_stream_token_ = ByteString{proto.stream_token};
}

google_firestore_v1_WriteRequest WriteStreamSerializer::CreateHandshake()
    const {
  // The initial request cannot contain mutations, but must contain a project
  // ID.
  google_firestore_v1_WriteRequest request{};
  request.database = cc_serializer_.EncodeDatabaseId();
  return request;
}

google_firestore_v1_WriteRequest
WriteStreamSerializer::CreateWriteMutationsRequest(
    const std::vector<Mutation>& mutations) const {
  google_firestore_v1_WriteRequest request{};

  if (!mutations.empty()) {
    request.writes_count = nanopb::CheckedSize(mutations.size());
    request.writes = MakeArray<google_firestore_v1_Write>(request.writes_count);

    for (pb_size_t i = 0; i != request.writes_count; ++i) {
      request.writes[i] = cc_serializer_.EncodeMutation(mutations[i]);
    }
  }

  request.stream_token = nanopb::CopyBytesArray(last_stream_token_.get());

  return request;
}

grpc::ByteBuffer WriteStreamSerializer::ToByteBuffer(
    google_firestore_v1_WriteRequest&& request) {
  return ConvertToByteBuffer(google_firestore_v1_WriteRequest_fields,
                             std::move(request));
}

StatusOr<NanopbProto<google_firestore_v1_WriteResponse>>
WriteStreamSerializer::ParseResponse(const grpc::ByteBuffer& message) const {
  return NanopbProto<google_firestore_v1_WriteResponse>::Parse(
      google_firestore_v1_WriteResponse_fields, message);
}

model::SnapshotVersion WriteStreamSerializer::ToCommitVersion(
    const google_firestore_v1_WriteResponse& proto) const {
  nanopb::Reader reader{nullptr, 0};  // FIXME
  auto result =
      cc_serializer_.DecodeSnapshotVersion(&reader, proto.commit_time);
  // FIXME check error
  return result;
}

std::vector<MutationResult> WriteStreamSerializer::ToMutationResults(
    const google_firestore_v1_WriteResponse& proto) const {
  const SnapshotVersion commit_version = ToCommitVersion(proto);

  const google_firestore_v1_WriteResult* writes = proto.write_results;
  pb_size_t count = proto.write_results_count;
  std::vector<MutationResult> results;
  results.reserve(count);

  nanopb::Reader reader{nullptr, 0};
  for (pb_size_t i = 0; i != count; ++i) {
    results.push_back(cc_serializer_.DecodeMutationResult(&reader, writes[i],
                                                          commit_version));
  };

  // FIXME check error
  return results;
}

std::string WriteStreamSerializer::Describe(
    const google_firestore_v1_WriteRequest& request) {
  return DescribeRequest<GCFSWriteRequest>(
      google_firestore_v1_WriteRequest_fields, request);
}

std::string WriteStreamSerializer::Describe(
    const google_firestore_v1_WriteResponse& response) {
  return DescribeRequest<GCFSWriteResponse>(
      google_firestore_v1_WriteResponse_fields, response);
}

// DatastoreSerializer

DatastoreSerializer::DatastoreSerializer(const DatabaseInfo& database_info)
    : serializer_{[[FSTSerializerBeta alloc]
          initWithDatabaseID:database_info.database_id()]},
      cc_serializer_{database_info.database_id()} {
}

google_firestore_v1_CommitRequest DatastoreSerializer::CreateCommitRequest(
    const std::vector<Mutation>& mutations) const {
  google_firestore_v1_CommitRequest request{};

  request.database = cc_serializer_.EncodeDatabaseId();

  if (!mutations.empty()) {
    request.writes_count = nanopb::CheckedSize(mutations.size());
    request.writes = MakeArray<google_firestore_v1_Write>(request.writes_count);
    pb_size_t i = 0;
    for (const Mutation& mutation : mutations) {
      request.writes[i] = cc_serializer_.EncodeMutation(mutation);
      ++i;
    }
  }

  return request;
}

grpc::ByteBuffer DatastoreSerializer::ToByteBuffer(
    google_firestore_v1_CommitRequest&& request) {
  return ConvertToByteBuffer(google_firestore_v1_CommitRequest_fields,
                             std::move(request));
}

GCFSBatchGetDocumentsRequest* DatastoreSerializer::CreateLookupRequest(
    const std::vector<DocumentKey>& keys) const {
  GCFSBatchGetDocumentsRequest* request =
      [GCFSBatchGetDocumentsRequest message];

  request.database = [serializer_ encodedDatabaseID];
  for (const DocumentKey& key : keys) {
    [request.documentsArray addObject:[serializer_ encodedDocumentKey:key]];
  }

  return request;
}

grpc::ByteBuffer DatastoreSerializer::ToByteBuffer(
    GCFSBatchGetDocumentsRequest* request) {
  return ConvertToByteBuffer([request data]);
}

std::vector<MaybeDocument> DatastoreSerializer::MergeLookupResponses(
    const std::vector<grpc::ByteBuffer>& responses, Status* out_status) const {
  // Sort by key.
  std::map<DocumentKey, MaybeDocument> results;

  for (const auto& response : responses) {
    auto* proto = ToProto<GCFSBatchGetDocumentsResponse>(response, out_status);
    if (!out_status->ok()) {
      return {};
    }
    MaybeDocument doc = [serializer_ decodedMaybeDocumentFromBatch:proto];
    results[doc.key()] = std::move(doc);
  }

  std::vector<MaybeDocument> docs;
  docs.reserve(results.size());
  for (const auto& kv : results) {
    docs.push_back(kv.second);
  }
  return docs;
}

MaybeDocument DatastoreSerializer::ToMaybeDocument(
    GCFSBatchGetDocumentsResponse* response) const {
  return [serializer_ decodedMaybeDocumentFromBatch:response];
}

}  // namespace bridge
}  // namespace remote
}  // namespace firestore
}  // namespace firebase
