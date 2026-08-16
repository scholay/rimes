#include "broker_protocol.hpp"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <iostream>
#include <string>
#include <vector>

namespace rimes::windows::core::tests {
namespace {

int g_failures = 0;

void Expect(bool condition, const char* expression, int line) {
  if (!condition) {
    std::cerr << "broker_protocol_tests.cpp:" << line
              << ": expectation failed: " << expression << '\n';
    ++g_failures;
  }
}

#define EXPECT(condition) Expect((condition), #condition, __LINE__)

Frame MakePing(std::uint32_t request_id) {
  Frame frame;
  frame.header.message_type = MessageType::kPing;
  frame.header.request_id = request_id;
  return frame;
}

void WriteU16(std::vector<std::byte>* bytes,
              std::size_t offset,
              std::uint16_t value) {
  (*bytes)[offset] = static_cast<std::byte>(value & 0xffU);
  (*bytes)[offset + 1] = static_cast<std::byte>((value >> 8U) & 0xffU);
}

void WriteU32(std::vector<std::byte>* bytes,
              std::size_t offset,
              std::uint32_t value) {
  for (unsigned int index = 0; index < 4; ++index) {
    (*bytes)[offset + index] =
        static_cast<std::byte>((value >> (index * 8U)) & 0xffU);
  }
}

void TestFrameRoundTripAndFragmentation() {
  Frame input = MakePing(42);
  input.payload = {std::byte{0x10}, std::byte{0x20}, std::byte{0x30}};

  std::vector<std::byte> encoded;
  std::string error;
  EXPECT(EncodeFrame(input, &encoded, &error));
  EXPECT(encoded.size() == kFrameHeaderSize + input.payload.size());

  for (std::size_t length = 0; length < encoded.size(); ++length) {
    const FrameDecodeResult partial =
        DecodeFrame(std::span<const std::byte>(encoded).first(length));
    EXPECT(partial.status == DecodeStatus::kNeedMoreData);
    EXPECT(partial.bytes_consumed == 0);
  }

  const FrameDecodeResult result = DecodeFrame(encoded);
  EXPECT(result.status == DecodeStatus::kComplete);
  EXPECT(result.bytes_consumed == encoded.size());
  EXPECT(result.frame.header.protocol_major == kProtocolMajor);
  EXPECT(result.frame.header.protocol_minor == kProtocolMinor);
  EXPECT(result.frame.header.message_type == MessageType::kPing);
  EXPECT(result.frame.header.request_id == 42);
  EXPECT(result.frame.header.payload_size == input.payload.size());
  EXPECT(result.frame.payload == input.payload);
}

void TestDecoderConsumesOneFrame() {
  std::vector<std::byte> first;
  std::vector<std::byte> second;
  EXPECT(EncodeFrame(MakePing(1), &first));
  EXPECT(EncodeFrame(MakePing(2), &second));

  std::vector<std::byte> joined = first;
  joined.insert(joined.end(), second.begin(), second.end());
  const FrameDecodeResult result = DecodeFrame(joined);
  EXPECT(result.status == DecodeStatus::kComplete);
  EXPECT(result.bytes_consumed == first.size());
  EXPECT(result.frame.header.request_id == 1);
}

void TestRejectsMalformedHeadersBeforeAllocation() {
  std::vector<std::byte> valid;
  EXPECT(EncodeFrame(MakePing(7), &valid));

  auto bad_magic = valid;
  bad_magic[0] ^= std::byte{0xff};
  EXPECT(DecodeFrameHeader(bad_magic).status == DecodeStatus::kInvalidFrame);

  auto bad_header_size = valid;
  WriteU16(&bad_header_size, 4, kFrameHeaderSize + 1);
  EXPECT(DecodeFrameHeader(bad_header_size).status ==
         DecodeStatus::kInvalidFrame);

  auto bad_major = valid;
  WriteU16(&bad_major, 6, kProtocolMajor + 1);
  EXPECT(DecodeFrameHeader(bad_major).status == DecodeStatus::kInvalidFrame);

  auto bad_minor = valid;
  WriteU16(&bad_minor, 8, kProtocolMinor + 1);
  EXPECT(DecodeFrameHeader(bad_minor).status == DecodeStatus::kInvalidFrame);

  auto bad_type = valid;
  WriteU16(&bad_type, 10, 0xffff);
  EXPECT(DecodeFrameHeader(bad_type).status == DecodeStatus::kInvalidFrame);

  auto bad_flags = valid;
  WriteU32(&bad_flags, 12, 0x80000000U);
  EXPECT(DecodeFrameHeader(bad_flags).status == DecodeStatus::kInvalidFrame);

  auto inconsistent_flags = valid;
  WriteU32(&inconsistent_flags, 12,
           static_cast<std::uint32_t>(FrameFlags::kError));
  EXPECT(DecodeFrameHeader(inconsistent_flags).status ==
         DecodeStatus::kInvalidFrame);

  auto oversized = valid;
  WriteU32(&oversized, 20, kMaxPayloadSize + 1);
  EXPECT(DecodeFrameHeader(oversized).status == DecodeStatus::kInvalidFrame);
}

void TestEncoderLimits() {
  Frame oversized = MakePing(8);
  oversized.payload.resize(static_cast<std::size_t>(kMaxPayloadSize) + 1);
  std::vector<std::byte> encoded;
  EXPECT(!EncodeFrame(oversized, &encoded));

  Frame mismatched = MakePing(9);
  mismatched.header.payload_size = 2;
  mismatched.payload.push_back(std::byte{0x01});
  EXPECT(!EncodeFrame(mismatched, &encoded));

  Frame unknown = MakePing(10);
  unknown.header.flags = 0x40000000U;
  EXPECT(!EncodeFrame(unknown, &encoded));
}

void TestClientHelloRoundTrip() {
  ClientHello input;
  input.process_id = 1234;
  input.session_id = 9;
  input.capabilities = 0x0102030405060708ULL;
  input.client_name = "RIMES TSF";

  std::vector<std::byte> encoded;
  EXPECT(EncodeClientHello(input, &encoded));

  ClientHello decoded;
  EXPECT(DecodeClientHello(encoded, &decoded));
  EXPECT(decoded.process_id == input.process_id);
  EXPECT(decoded.session_id == input.session_id);
  EXPECT(decoded.capabilities == input.capabilities);
  EXPECT(decoded.client_name == input.client_name);

  encoded.push_back(std::byte{0});
  EXPECT(!DecodeClientHello(encoded, &decoded));
}

void TestBrokerHelloRoundTrip() {
  BrokerHello input;
  input.process_id = 4567;
  input.session_id = 3;
  input.capabilities = 0x99;
  input.broker_version = "0.1.0-dev";

  std::vector<std::byte> encoded;
  EXPECT(EncodeBrokerHello(input, &encoded));

  BrokerHello decoded;
  EXPECT(DecodeBrokerHello(encoded, &decoded));
  EXPECT(decoded.process_id == input.process_id);
  EXPECT(decoded.session_id == input.session_id);
  EXPECT(decoded.capabilities == input.capabilities);
  EXPECT(decoded.broker_version == input.broker_version);
}

void TestErrorRoundTripAndLimits() {
  ErrorResponse input;
  input.code = BrokerErrorCode::kUnsupportedMessage;
  input.message = "not implemented in the broker skeleton";

  std::vector<std::byte> encoded;
  EXPECT(EncodeErrorResponse(input, &encoded));

  ErrorResponse decoded;
  EXPECT(DecodeErrorResponse(encoded, &decoded));
  EXPECT(decoded.code == input.code);
  EXPECT(decoded.message == input.message);

  input.message.assign(kMaxErrorMessageBytes + 1, 'x');
  EXPECT(!EncodeErrorResponse(input, &encoded));

  ClientHello bad_text;
  bad_text.process_id = 1;
  bad_text.session_id = 1;
  bad_text.client_name = std::string("before\0after", 12);
  EXPECT(!EncodeClientHello(bad_text, &encoded));

  bad_text.client_name = "client";
  bad_text.process_id = 0;
  EXPECT(!EncodeClientHello(bad_text, &encoded));
}

void TestInputSessionDtos() {
  OpenInputSession open_input;
  open_input.context_id = 0x123456789ULL;
  open_input.schema_id = "rime_ice";
  std::vector<std::byte> encoded;
  EXPECT(EncodeOpenInputSession(open_input, &encoded));

  OpenInputSession decoded_open;
  EXPECT(DecodeOpenInputSession(encoded, &decoded_open));
  EXPECT(decoded_open.context_id == open_input.context_id);
  EXPECT(decoded_open.schema_id == open_input.schema_id);

  InputSessionOpened opened;
  opened.session_id = 99;
  opened.active_schema_id = "rime_ice";
  EXPECT(EncodeInputSessionOpened(opened, &encoded));
  InputSessionOpened decoded_opened;
  EXPECT(DecodeInputSessionOpened(encoded, &decoded_opened));
  EXPECT(decoded_opened.session_id == opened.session_id);
  EXPECT(decoded_opened.active_schema_id == opened.active_schema_id);

  CloseInputSession close_input{99};
  EXPECT(EncodeCloseInputSession(close_input, &encoded));
  CloseInputSession decoded_close;
  EXPECT(DecodeCloseInputSession(encoded, &decoded_close));
  EXPECT(decoded_close.session_id == close_input.session_id);

  InputSessionClosed closed{99};
  EXPECT(EncodeInputSessionClosed(closed, &encoded));
  InputSessionClosed decoded_closed;
  EXPECT(DecodeInputSessionClosed(encoded, &decoded_closed));
  EXPECT(decoded_closed.session_id == closed.session_id);

  open_input.context_id = 0;
  EXPECT(!EncodeOpenInputSession(open_input, &encoded));
  close_input.session_id = 0;
  EXPECT(!EncodeCloseInputSession(close_input, &encoded));
}

void TestKeyEventRoundTripAndValidation() {
  KeyEvent input;
  input.session_id = 88;
  input.sequence_id = 7;
  input.timestamp_millis = 123456789;
  input.virtual_key = 0x41;
  input.scan_code = 0x1e;
  input.repeat_count = 2;
  input.modifiers = static_cast<std::uint32_t>(KeyModifiers::kShift);
  input.event_flags =
      static_cast<std::uint32_t>(KeyEventFlags::kKeyDown) |
      static_cast<std::uint32_t>(KeyEventFlags::kRepeat);

  std::vector<std::byte> encoded;
  EXPECT(EncodeKeyEvent(input, &encoded));
  KeyEvent decoded;
  EXPECT(DecodeKeyEvent(encoded, &decoded));
  EXPECT(decoded.session_id == input.session_id);
  EXPECT(decoded.sequence_id == input.sequence_id);
  EXPECT(decoded.timestamp_millis == input.timestamp_millis);
  EXPECT(decoded.virtual_key == input.virtual_key);
  EXPECT(decoded.scan_code == input.scan_code);
  EXPECT(decoded.repeat_count == input.repeat_count);
  EXPECT(decoded.modifiers == input.modifiers);
  EXPECT(decoded.event_flags == input.event_flags);

  input.event_flags = static_cast<std::uint32_t>(KeyEventFlags::kRepeat);
  EXPECT(!EncodeKeyEvent(input, &encoded));
  input.event_flags = 0;
  input.repeat_count = 1;
  input.virtual_key = 0x100;
  EXPECT(!EncodeKeyEvent(input, &encoded));
  input.virtual_key = 0x41;
  input.modifiers = 0x80000000U;
  EXPECT(!EncodeKeyEvent(input, &encoded));
}

InputState MakeInputState() {
  InputState state;
  state.session_id = 88;
  state.sequence_id = 7;
  state.revision = 12;
  state.state_flags =
      static_cast<std::uint32_t>(InputStateFlags::kHandled) |
      static_cast<std::uint32_t>(InputStateFlags::kComposing) |
      static_cast<std::uint32_t>(InputStateFlags::kCandidatesVisible);
  state.composition = "nihao";
  state.caret_utf16 = 5;
  state.highlighted_candidate = 0;
  state.page_start = 0;
  state.page_size = 2;
  state.commit_text = "你好";
  state.candidates = {
      Candidate{1, "你好", "nǐ hǎo", "1"},
      Candidate{2, "拟好", "nǐ hǎo", "2"},
  };
  return state;
}

void TestInputStateRoundTripAndValidation() {
  const InputState input = MakeInputState();
  std::vector<std::byte> encoded;
  EXPECT(EncodeInputState(input, &encoded));

  InputState decoded;
  EXPECT(DecodeInputState(encoded, &decoded));
  EXPECT(decoded.session_id == input.session_id);
  EXPECT(decoded.sequence_id == input.sequence_id);
  EXPECT(decoded.revision == input.revision);
  EXPECT(decoded.state_flags == input.state_flags);
  EXPECT(decoded.composition == input.composition);
  EXPECT(decoded.commit_text == input.commit_text);
  EXPECT(decoded.candidates.size() == 2);
  EXPECT(decoded.candidates[0].text == "你好");
  EXPECT(decoded.candidates[1].id == 2);

  InputState bad = input;
  bad.caret_utf16 = 6;
  EXPECT(!EncodeInputState(bad, &encoded));

  bad = input;
  bad.state_flags &=
      ~static_cast<std::uint32_t>(InputStateFlags::kCandidatesVisible);
  EXPECT(!EncodeInputState(bad, &encoded));

  bad = input;
  bad.highlighted_candidate = 3;
  EXPECT(!EncodeInputState(bad, &encoded));

  bad = input;
  bad.state_flags &= ~static_cast<std::uint32_t>(InputStateFlags::kHandled);
  EXPECT(!EncodeInputState(bad, &encoded));

  bad = input;
  bad.candidates.resize(kMaxCandidateCount + 1);
  EXPECT(!EncodeInputState(bad, &encoded));

  bad = input;
  bad.candidates[0].text = std::string("\xc0\x80", 2);  // overlong NUL
  EXPECT(!EncodeInputState(bad, &encoded));
}

}  // namespace

int RunBrokerProtocolTests() {
  g_failures = 0;
  TestFrameRoundTripAndFragmentation();
  TestDecoderConsumesOneFrame();
  TestRejectsMalformedHeadersBeforeAllocation();
  TestEncoderLimits();
  TestClientHelloRoundTrip();
  TestBrokerHelloRoundTrip();
  TestErrorRoundTripAndLimits();
  TestInputSessionDtos();
  TestKeyEventRoundTripAndValidation();
  TestInputStateRoundTripAndValidation();
  return g_failures;
}

}  // namespace rimes::windows::core::tests

#ifdef RIMES_BROKER_PROTOCOL_TEST_MAIN
int main() {
  const int failures =
      rimes::windows::core::tests::RunBrokerProtocolTests();
  if (failures == 0) {
    std::cout << "broker protocol tests passed\n";
  }
  return failures == 0 ? 0 : 1;
}
#endif
