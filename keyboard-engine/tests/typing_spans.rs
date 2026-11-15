// Exercise the same public C entry points as the keyboard.
use std::ffi::CString;
use std::os::raw::c_char;
use monkeyboard_engine as _;

extern "C" {
    fn mb_pipeline22_v1(input: *const c_char, output: *mut c_char, capacity: usize) -> i32;
    fn mb_supported_opening_v1(span: *const c_char, guess: *const c_char) -> i32;
}
fn opening(input: &str, guess: &str) -> bool {
    let (span, proposed) = (CString::new(input).unwrap(), CString::new(guess).unwrap());
    unsafe { mb_supported_opening_v1(span.as_ptr(), proposed.as_ptr()) == 1 }
}
#[test]
fn opening_needs_context_and_does_not_shorten_initials() {
    assert!(opening("Diid I leave my phone", "Did"));
    assert!(!opening("Diid", "Did"));
    assert!(!opening("DIY projects take time", "Di"));
    assert!(!opening("II for the second group", "I"));
}
#[test]
fn trained_join_never_collapses_two_intentional_words() {
    let sentence = CString::new("We paid a lot for dinner").unwrap();
    let mut out = [0 as c_char; 384];
    let ret = unsafe { mb_pipeline22_v1(sentence.as_ptr(), out.as_mut_ptr(), out.len()) };
    assert!(ret >= 0);
    if ret == 1 {
        let text = unsafe { std::ffi::CStr::from_ptr(out.as_ptr()) }.to_str().unwrap();
        assert!(text.contains("a lot"));
    }
}
