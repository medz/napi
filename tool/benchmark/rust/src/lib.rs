use napi::bindgen_prelude::*;
use napi_derive::napi;

#[napi]
pub fn add(left: i32, right: i32) -> i32 {
  left + right
}

#[napi]
pub struct Counter {
  pub value: i32,
}

#[napi]
impl Counter {
  #[napi(constructor)]
  pub fn new(value: Option<i32>) -> Self {
    Self { value: value.unwrap_or(0) }
  }

  #[napi]
  pub fn increment(&mut self, amount: Option<i32>) -> i32 {
    self.value += amount.unwrap_or(1);
    self.value
  }
}

#[napi]
pub fn copy_bytes(bytes: Uint8Array) -> Uint8Array {
  let mut copy = bytes.to_vec();
  if !copy.is_empty() {
    copy[0] ^= 1;
  }
  Uint8Array::new(copy)
}

#[napi]
pub fn shared_bytes(mut bytes: Uint8Array) -> Uint8Array {
  if !bytes.is_empty() {
    // The benchmark uses fixed, non-shared storage and makes no JS callbacks.
    unsafe { bytes.as_mut()[0] ^= 1; }
  }
  bytes
}

#[napi]
pub fn allocate(size: u32) -> Uint8Array {
  Uint8Array::new(vec![0; size as usize])
}
