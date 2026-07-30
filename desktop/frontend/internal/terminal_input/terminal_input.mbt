///|
/// Encode xterm's `onBinary` string without interpreting its code units as
/// Unicode text. xterm guarantees every code unit is one byte; truncating to
/// `Byte` preserves that value before the bridge's base64 transport.
pub fn encode_binary(data : String) -> String {
  let bytes = Buffer()
  for i in 0..<data.length() {
    bytes.write_byte(data[i].to_byte())
  }
  @base64.encode(bytes.to_bytes())
}
