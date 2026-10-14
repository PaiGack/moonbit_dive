///|
test "hex_value accepts both cases" {
  assert_eq(@oci_spec.hex_value('0'), Some(0))
  assert_eq(@oci_spec.hex_value('9'), Some(9))
  assert_eq(@oci_spec.hex_value('a'), Some(10))
  assert_eq(@oci_spec.hex_value('f'), Some(15))
  assert_eq(@oci_spec.hex_value('A'), Some(10))
  assert_eq(@oci_spec.hex_value('F'), Some(15))
  assert_eq(@oci_spec.hex_value('g'), None)
  assert_eq(@oci_spec.hex_value('/'), None)
}

///|
test "is_hex checks the character set and optional lowercase" {
  assert_true(@oci_spec.is_hex("0123456789abcdef"))
  assert_true(@oci_spec.is_hex("ABCDEF"))
  assert_false(@oci_spec.is_hex("ABCDEF", lowercase_only=true))
  assert_false(@oci_spec.is_hex(""))
  assert_false(@oci_spec.is_hex("deadbeefz"))
}
